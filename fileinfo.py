import sys
import os
import json
import shutil
import re
from datetime import datetime
import scipy.io as sio
import numpy as np


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


def parse_user_times(filelog):
    """
    Parse the file log and compute total time per user.
    Log lines look like:
        'Opened by 1955ATTCT44 on 23.12.2022_07.25.55'
        'Saved by 4187JPTCT24 on 23.12.2022_09.11.08'
    A user may appear in multiple sessions (e.g. reworks). We group
    consecutive actions by the same user into sessions and sum the
    durations (last timestamp - first timestamp) of each session.
    """
    # Match "by <USER> on <DD.MM.YYYY_HH.MM.SS>"
    pattern = re.compile(
        r"by\s+([A-Za-z0-9]+)\s+on\s+(\d{2}\.\d{2}\.\d{4}_\d{2}[.:]\d{2}[.:]\d{2})"
    )

    events = []  # list of (user, datetime)
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
        events.append((user, ts))

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

    for user, ts in events:
        if user != current_user:
            # a different user started -> close previous session
            close_session()
            current_user = user
            session_start = ts
            session_end = ts
        else:
            # same user continues -> extend session end
            session_end = ts
    close_session()  # close the final open session

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

# Temporarily rename .evm to .mat using a SAFE temp name (no brackets)
mat_path = os.path.join(script_dir, "temp_load.mat")

try:
    shutil.copy2(evm_path, mat_path)
    my_struct = sio.loadmat(mat_path)

    data = my_struct["ThisStructure"]
    comments = my_struct["Comments"]

    c = first_elem(comments)
    d = first_elem(data)

    # --- Build the full file log string (Notes may be 1-D, N-D, or empty) ---
    logs = flat(c["Notes"])
    filelog = ""
    for x in logs:
        filelog += str(x).strip("[]' ") + "\n"

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
    Roof        = roof + pens + iapens
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
        "qc": QC,
        "user_times": user_times,
    }
    print(json.dumps(result))

except Exception as e:
    print(json.dumps({"status": "ERROR", "message": str(e)}))

finally:
    # Always delete the temp .mat file
    if os.path.exists(mat_path):
        os.remove(mat_path)