# ============================================================================
# Created and developed by PIA - members: Pogi, LT, Rona
#
# Do not edit the code without informing PIA.
# PIA site: https://eagleviewcloud.sharepoint.com/sites/QualityTeam/SitePages/PIA.aspx
# ============================================================================
import sys
import os
import json
import re
from datetime import datetime, timedelta
import scipy.io as sio
import numpy as np

# Start a new session if the gap between two consecutive events of the
# same user exceeds this.
SESSION_GAP = timedelta(hours=12)


def first_elem(arr):
    """Return the first struct element regardless of shape ((1,1),(1,),(N,) etc.)."""
    return np.asarray(arr).reshape(-1)[0]


def flat(arr):
    """Flatten any array shape ([1], [0], [N,1], [6,1], etc.) into a 1-D array."""
    return np.asarray(arr).reshape(-1)


def get_qc(comments):
    """Safely extract the QC value from Comments -> Workflow -> Last -> QC."""
    try:
        c = first_elem(comments)
        wf = first_elem(c["Workflow"])
        last = first_elem(wf["Last"])
        qc = flat(last["QC"])
        if qc.size == 0:
            return None
        return str(qc[0])
    except (KeyError, IndexError, ValueError):
        return None


def note_text(x):
    """Text of one Notes entry (a cell holding a char array, a string, or nothing)."""
    try:
        return "".join(str(t) for t in flat(x)).strip()
    except Exception:
        return str(x).strip("[]' ")


def join_char_runs(lines, min_run=3):
    """Full Notes as readable lines.

    Some files store their first note (e.g. 'Order 73853477 created by CACHER on ...') one character per entry
    (an empty entry = a space). A run of min_run+ one-character / empty entries is joined back into one line;
    every other entry stays on its own line. Empty lines are dropped.
    """
    out = []
    i = 0
    while i < len(lines):
        j = i
        while j < len(lines) and len(lines[j]) <= 1:
            j += 1
        if j - i >= min_run:
            out.append("".join(t if t else " " for t in lines[i:j]).strip())
            i = j
        else:
            if lines[i]:
                out.append(lines[i])
            i += 1
    return out


def parse_user_times(filelog):
    """
    Parse the file log and compute total time per user.
    Log lines look like:
        'Opened by 1955ATTCT44 on 23.12.2022_07.25.55'
        'Saved by 4187JPTCT24 on 23.12.2022_09.11.08'
        'Checkpoint 5.0 from TW by 7657LGTCT99 on 15.09.2026_15.35.25'
    A user may appear in multiple sessions (e.g. reworks). We group
    consecutive actions by the same user into sessions, and a session
    is closed (ended) as soon as a Checkpoint line for that user is
    processed. Checkpoints do NOT split a session: a session runs from the
    user's first event to their last as long as the same user continues. A session is
    closed whenever the user changes, and when more than 12 hours pass between two
    consecutive events of the same user. We sum the durations (last timestamp -
    first timestamp) of each session.
    """
    # Match "by <USER> on <DD.MM.YYYY_HH.MM.SS>"
    pattern = re.compile(
        r"by\s+([A-Za-z0-9]+)\s+on\s+(\d{2}\.\d{2}\.\d{4}_\d{2}[.:]\d{2}[.:]\d{2})"
    )

    events = []  # list of (user, datetime, is_checkpoint)
    for line in filelog.splitlines():
        m = pattern.search(line)
        if not m:
            continue
        user = m.group(1)
        raw_ts = m.group(2).replace(":", ".")  # normalize separators
        try:
            ts = datetime.strptime(raw_ts, "%d.%m.%Y_%H.%M.%S")
        except ValueError:
            continue
        is_checkpoint = "checkpoint" in line.lower()
        events.append((user, ts, is_checkpoint))

    if not events:
        return {}

    # Group into consecutive sessions per user (in log order)
    user_totals = {}       # user -> total seconds
    user_sessions = {}     # user -> list of (start, end, seconds)

    current_user = None
    session_start = None
    session_end = None

    def close_session():
        if current_user is None:
            return
        secs = int((session_end - session_start).total_seconds())
        user_totals[current_user] = user_totals.get(current_user, 0) + secs
        user_sessions.setdefault(current_user, []).append(
            (session_start, session_end, secs)
        )

    for user, ts, is_checkpoint in events:
        if user != current_user:
            # a different user started -> close previous session
            close_session()
            current_user = user
            session_start = ts
            session_end = ts
        elif ts - session_end > SESSION_GAP:
            # same user, but more than 12h since their last event -> new session
            close_session()
            session_start = ts
            session_end = ts
        else:
            # same user continues -> extend session end
            session_end = ts

    close_session()  # close the final open session (no-op if already closed)

    # Build a clean result structure
    def fmt(secs):
        h, rem = divmod(secs, 3600)
        m, s = divmod(rem, 60)
        return f"{h}h {m:02d}m {s:02d}s"

    result = {}
    for user, total in user_totals.items():
        sessions = [
            {
                "start": st.strftime("%d.%m.%Y %H:%M:%S"),
                "end": en.strftime("%d.%m.%Y %H:%M:%S"),
                "duration_seconds": sec,
                "duration_minutes": round(sec / 60, 2),
                "duration": fmt(sec),
            }
            for st, en, sec in user_sessions[user]
        ]
        result[user] = {
            "total_seconds": total,
            "total_minutes": round(total / 60, 2),
            "total_time": fmt(total),
            "session_count": len(sessions),
            "sessions": sessions,
        }
    return result


# Get file path from argument passed by PAD
evm_path = " ".join(sys.argv[1:]).strip('"').strip("'")
script_dir = os.path.dirname(evm_path)

try:
    # .evm files are renamed .mat files: open them as a file object so the extension doesn't matter.
    # (Was: copy to a fixed "temp_load.mat" next to the .evm, load it, delete it - an extra full copy of the
    # file per run, and a fixed name that made concurrent runs collide.)  Read only the two variables we use.
    with open(evm_path, "rb") as fh:
        my_struct = sio.loadmat(fh, variable_names=["ThisStructure", "Comments"])

    data = my_struct["ThisStructure"]
    comments = my_struct["Comments"]

    c = first_elem(comments)
    d = first_elem(data)

    # --- Build the full file log string (Notes may be 1-D, N-D, or empty) ---
    logs = flat(c["Notes"])
    filelog = ""
    for x in logs:
        filelog += str(x).strip("[]' ") + "\n"

    # --- Full Notes: every entry of Comments.Notes (order created, Opened/Saved/Checkpoint lines, typed notes) ---
    full_notes = "\n".join(join_char_runs([note_text(x) for x in logs]))

    # --- Compute per-user total times ---
    user_times = parse_user_times(filelog)

    # --- Notes / QC History (TechQCNotes may be empty) ---
    notes = flat(c["TechQCNotes"])
    history = "\n".join(str(x).strip("[]' ") for x in notes)

    # --- QC value ---
    lastqc = get_qc(comments)

    # --- Facet types (Facets is [N,1] but flatten to be safe) ---
    facets = flat(d["Facets"])
    ftypelist = [int(flat(f["Type"])[0]) for f in facets]

    # --- Raw counts ---
    roof      = ftypelist.count(512)
    pens      = ftypelist.count(672)
    iapens    = ftypelist.count(8864)
    wall      = ftypelist.count(1024)
    footprint = ftypelist.count(2048)
    soffits   = ftypelist.count(9344)
    stamps    = ftypelist.count(1184)
    som       = ftypelist.count(17408)

    # --- Computed variables ---
    Roof        = roof
    Penetration = pens + iapens
    Wall        = wall + footprint + soffits + stamps + som
    Notes       = history
    QC          = lastqc

    # --- Result ---
    result = {
        "status": "SUCCESS",
        "roof": Roof,
        "penetration": Penetration,
        "wall": Wall,
        "notes": Notes,
        "full_notes": full_notes,
        "qc": QC,
        "user_times": user_times,
    }
    print(json.dumps(result))

except Exception as e:
    print(json.dumps({"status": "ERROR", "message": str(e)}))
