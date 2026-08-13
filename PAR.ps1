#requires -Version 5.1
<#
============================================================================
PAR — Prod Active Reports (standalone desktop GUI)
Created and developed by PIA — members: Pogi, LT, Rona

Do not edit the code without informing PIA
============================================================================
#>

# ============================================================
#  SHORTCUT SELF-DEPLOY
# ============================================================
$Desktop = [Environment]::GetFolderPath("Desktop")
Copy-Item -Path "\\mnl-pure01.mnl.eagleview.com\PublicFolder\1_Coordinators\PIA\PAR\PAR.lnk" `
          -Destination "$Desktop\PAR.lnk" `
          -Force -ErrorAction SilentlyContinue

[CmdletBinding()]
param(
    # Keep the browser's normal CORS enforcement instead of relaxing it.
    [switch]$EnforceWebSecurity,
    # Force re-download of the WebView2 SDK assemblies even if cached.
    [switch]$ForceWebView2Refresh
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
# ============================================================================
# EMBEDDED ASSETS  (verbatim PAR.html / src/PAR.css / src/PAR.js)
# ============================================================================
$ParHtml = @'
<!DOCTYPE html>
<html lang="en">
<!--
PAR
Prod Active Reports
Created and developed by PIA
PIA members: Pogi, LT, Rona
-->
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>PAR</title>
  <link rel="stylesheet" href="src/PAR.css">
</head>
<body>
  <div id="dupAlertContainer" class="dup-alert-container"></div>
  <div class="par-tab-bar">
    <div class="tab-logo-block">
      <div class="par-logo-dot"></div>
      <span class="tab-logo-text">PAR</span>
    </div>
    <button class="tab-btn tab-active" id="tab-measure-btn" onclick="switchTab('measure')">Measure</button>
    <button class="tab-btn" id="tab-qc-btn" onclick="switchTab('qc')">QC</button>
    <!-- ── TRIPLE CLOCK ── -->
    <div class="dual-clock">
      <div class="clock-item" id="clock-ph">
        <span class="clock-icon" id="clock-icon-ph">🌙</span>
        <div class="clock-info">
          <span class="clock-label">PH</span>
          <span class="clock-time" id="clock-time-ph">--:--:--</span>
        </div>
      </div>
      <div class="clock-divider"></div>
      <div class="clock-item" id="clock-pst">
        <span class="clock-icon" id="clock-icon-pst">🌙</span>
        <div class="clock-info">
          <span class="clock-label" id="clock-label-pst">US</span>
          <span class="clock-time" id="clock-time-pst">--:--:--</span>
        </div>
      </div>
      <div class="clock-divider"></div>
      <div class="clock-item" id="clock-bog">
        <span class="clock-icon" id="clock-icon-bog">🌙</span>
        <div class="clock-info">
          <span class="clock-label">BOG</span>
          <span class="clock-time" id="clock-time-bog">--:--:--</span>
        </div>
      </div>
    </div>
    <!-- ── END TRIPLE CLOCK ── -->
    <div class="tab-spacer"></div>
    <button id="themeToggle" title="Switch theme">
      <span id="themeIcon">☀️</span>
      <span id="themeLabel">Light</span>
    </button>
  </div>
  <div class="tab-panel panel-active" id="panel-measure">
    <header class="par-header">
      <div class="par-header-left">
        <div class="par-title">Prod Active Reports — Measure</div>
        <div class="par-subtitle">RTM &amp; Being Measured</div>
      </div>
      <div class="par-header-center">
        <div class="queue-btn-wrap">
          <button class="queue-toggle-btn" data-queue="toggle" title="Queue Count">
            <span class="queue-btn-icon">⊞</span>
            <span class="queue-btn-label">Queue</span>
            <span class="queue-btn-badge" data-queue="badge">—</span>
          </button>
          <div class="queue-popover" data-queue="popover" aria-hidden="true">
            <div class="queue-popover-header">
              <span class="queue-popover-title">📋 Queue Count</span>
              <button class="queue-copy-btn" data-queue="copy" title="Copy to clipboard">
                <span class="queue-copy-icon">⧉</span>
                <span class="queue-copy-text">Copy</span>
              </button>
            </div>
            <div class="queue-popover-timestamp" data-queue="timestamp">Last updated: —</div>
            <div class="queue-popover-body" data-queue="body">
              <div class="queue-loading">
                <span class="queue-loading-dot"></span>
                <span class="queue-loading-dot"></span>
                <span class="queue-loading-dot"></span>
              </div>
            </div>
            <div class="queue-popover-footer">
              <button class="queue-refresh-btn" data-queue="refresh">↻ Refresh</button>
            </div>
          </div>
        </div>
      </div>
      <div class="par-stats">
        <span class="stat-pill live" id="m-statLive">Live: —</span>
        <span class="stat-pill late" id="m-statLate">Due: —</span>
      </div>
    </header>
    <div class="controls-bar">
      <input class="tab-search" id="m-myInput" type="text" placeholder="Search…" autocomplete="off">
      <div class="ctrl-divider"></div>
      <span class="ctrl-label">Show</span>
      <div class="type-controls">
        <button class="toggle-btn" id="m-chkLive"     data-key="m-chkLiveState"     data-active="active-live">Live</button>
        <button class="toggle-btn" id="m-chkTraining" data-key="m-chkTrainingState" data-active="active-training">Training</button>
      </div>
      <div class="ctrl-divider"></div>
      <span class="ctrl-label">Location</span>
      <div class="type-controls">
        <button class="toggle-btn loc-btn" id="m-locManila"   data-key="m-locManilaState"   data-active="active-loc" data-location="manila">Manila</button>
        <button class="toggle-btn loc-btn" id="m-locCebu"     data-key="m-locCebuState"     data-active="active-loc" data-location="cebu">Cebu</button>
        <button class="toggle-btn loc-btn" id="m-locBogota"   data-key="m-locBogotaState"   data-active="active-loc" data-location="bogota">Bogota</button>
      </div>
      <div class="ctrl-divider"></div>
      <span class="ctrl-label">Columns</span>
      <div class="col-controls" id="m-columnControls"></div>
    </div>
    <div class="table-round">
      <table class="par-table sortable" id="measure-table">
        <thead><tr>
          <th>Order Type</th>
          <th id="m-fileCount">Reports</th>
          <th>Username</th>
          <th>State</th>
          <th>History</th>
          <th>Rework Details</th>
          <th>Tech ID</th>
          <th>Team</th>
          <th>Location</th>
          <th>Measurement Item</th>
          <th>Elapsed Time</th>
          <th>Due In</th>
        </tr></thead>
        <tbody id="m-data"></tbody>
      </table>
    </div>
  </div>
  <div class="tab-panel" id="panel-qc">
    <header class="par-header">
      <div class="par-header-left">
        <div class="par-title">Prod Active Reports — QC</div>
        <div class="par-subtitle">RFQC &amp; Being QCed</div>
      </div>
      <div class="par-header-center">
        <div class="queue-btn-wrap">
          <button class="queue-toggle-btn" data-queue="toggle" title="Queue Count">
            <span class="queue-btn-icon">⊞</span>
            <span class="queue-btn-label">Queue</span>
            <span class="queue-btn-badge" data-queue="badge">—</span>
          </button>
          <div class="queue-popover" data-queue="popover" aria-hidden="true">
            <div class="queue-popover-header">
              <span class="queue-popover-title">📋 Queue Count</span>
              <button class="queue-copy-btn" data-queue="copy" title="Copy to clipboard">
                <span class="queue-copy-icon">⧉</span>
                <span class="queue-copy-text">Copy</span>
              </button>
            </div>
            <div class="queue-popover-timestamp" data-queue="timestamp">Last updated: —</div>
            <div class="queue-popover-body" data-queue="body">
              <div class="queue-loading">
                <span class="queue-loading-dot"></span>
                <span class="queue-loading-dot"></span>
                <span class="queue-loading-dot"></span>
              </div>
            </div>
            <div class="queue-popover-footer">
              <button class="queue-refresh-btn" data-queue="refresh">↻ Refresh</button>
            </div>
          </div>
        </div>
      </div>
      <div class="par-stats">
        <span class="stat-pill live" id="q-statLive">Live: —</span>
        <span class="stat-pill late" id="q-statLate">Due: —</span>
      </div>
    </header>
    <div class="controls-bar">
      <input class="tab-search" id="q-myInput" type="text" placeholder="Search…" autocomplete="off">
      <div class="ctrl-divider"></div>
      <span class="ctrl-label">Show</span>
      <div class="type-controls">
        <button class="toggle-btn" id="q-chkLive"     data-key="q-chkLiveState"     data-active="active-live">Live</button>
        <button class="toggle-btn" id="q-chkTraining" data-key="q-chkTrainingState" data-active="active-training">Training</button>
      </div>
      <div class="ctrl-divider"></div>
      <span class="ctrl-label">Location</span>
      <div class="type-controls">
        <button class="toggle-btn loc-btn" id="q-locManila"   data-key="q-locManilaState"   data-active="active-loc" data-location="manila">Manila</button>
        <button class="toggle-btn loc-btn" id="q-locCebu"     data-key="q-locCebuState"     data-active="active-loc" data-location="cebu">Cebu</button>
        <button class="toggle-btn loc-btn" id="q-locBogota"   data-key="q-locBogotaState"   data-active="active-loc" data-location="bogota">Bogota</button>
      </div>
      <div class="ctrl-divider"></div>
      <span class="ctrl-label">Columns</span>
      <div class="col-controls" id="q-columnControls"></div>
    </div>
    <div class="table-round">
      <table class="par-table sortable" id="qc-table">
        <thead><tr>
          <th>Order Type</th>
          <th id="q-fileCount">Reports</th>
          <th>State</th>
          <th>Tech</th>
          <th>QC</th>
          <th>QC ID</th>
          <th>Team</th>
          <th>Location</th>
          <th>Measurement Item</th>
          <th>Elapsed Time</th>
          <th>Due In</th>
        </tr></thead>
        <tbody id="q-data"></tbody>
      </table>
    </div>
  </div>
  <div id="reloadTimerContainer">
    <div class="footer-left">
      <span class="footer-star">★</span>
      <span class="footer-brand">PIA</span>
    </div>
    <div class="footer-center">
      <label style="display:flex;align-items:center;gap:5px;cursor:pointer;">
        <input type="checkbox" id="enableAutoReload" checked>
        <span style="color:var(--text-muted)">Auto-reload</span>
      </label>
      <span style="color:var(--border-light)">|</span>
      <div id="reloadTimer">Loading…</div>
    </div>
    <div class="footer-right">
      <span class="footer-version">version 3.8.13</span>
    </div>
  </div>
  <script src="src/PAR.js"></script>
</body>
</html>
'@
$ParCss = @'
/* ============================================================================
   PAR.css — Combined stylesheet
   Created and developed by PIA — members: Pogi, LT, Rona
   ============================================================================ */
:root {
  --bg-base:        #0e1117;
  --bg-surface:     #151923;
  --bg-card:        #1b2030;
  --bg-hover:       #212840;
  --border:         #2a3347;
  --border-light:   #344060;
  --text-primary:   #e8ecf4;
  --text-secondary: #8a96b0;
  --text-muted:     #515e7a;
  --green:          #04AA6D;
  --green-dim:      #037a4f;
  --green-glow:     rgba(4, 170, 109, 0.15);
  --red:            #ff4d6a;
  --orange:         #ff8c42;
  --amber:          #f5c842;
  --mono:           'IBM Plex Mono', monospace;
  --sans:           'IBM Plex Sans', sans-serif;
  --radius-sm:      4px;
  --radius-md:      8px;
  --radius-lg:      12px;
}
body.light {
  --bg-base:        #f0f2f7;
  --bg-surface:     #ffffff;
  --bg-card:        #f7f8fc;
  --bg-hover:       #eaecf5;
  --border:         #d0d5e3;
  --border-light:   #b8bfd4;
  --text-primary:   #1a1f2e;
  --text-secondary: #4a5270;
  --text-muted:     #8a93ae;
  --green:          #029659;
  --green-dim:      #027040;
  --green-glow:     rgba(2, 150, 89, 0.12);
  --red:            #d93050;
  --orange:         #d96b1a;
  --amber:          #c49a00;
}
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: var(--sans);
  background: transparent;
  color: var(--text-primary);
  height: 100vh;
  min-height: 100vh;
  font-size: 14px;
  line-height: 1.5;
  position: relative;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}
body::before {
  content: '';
  position: fixed;
  inset: 0;
  background: var(--bg-base);
  z-index: -1;
  pointer-events: none;
}
/* ── LOCATION TOGGLE (blue) ── */
.toggle-btn.active-loc {
  background:   rgba(99, 179, 237, 0.12);
  border-color: #63b3ed;
  color:        #63b3ed;
}
.toggle-btn:hover:not(.active-live):not(.active-training):not(.active-loc) {
  border-color: var(--border-light);
  color:        var(--text-primary);
}
/* ── TAB BAR ── */
.par-tab-bar {
  background: var(--bg-surface);
  border-bottom: 2px solid var(--border);
  padding: 0 20px;
  display: flex;
  align-items: stretch;
  flex: 0 0 auto;
  position: sticky;
  top: 0;
  z-index: 200;
  box-shadow: 0 2px 12px rgba(0,0,0,0.3) !important;
}
.tab-logo-block {
  display: flex;
  align-items: center;
  gap: 9px;
  padding-right: 20px;
  border-right: 1px solid var(--border);
  margin-right: 8px;
}
.par-logo-dot {
  width: 9px; height: 9px;
  background: var(--green);
  border-radius: 50%;
  box-shadow: 0 0 7px var(--green);
  animation: pulse-dot-enhanced 2.4s ease-in-out infinite !important;
  flex-shrink: 0;
}
@keyframes pulse-dot-enhanced {
  0%,100% {
    opacity: 1;
    box-shadow: 0 0 6px var(--green),
                0 0 0px rgba(4,170,109,0);
  }
  50% {
    opacity: 0.7;
    box-shadow: 0 0 14px var(--green),
                0 0 22px rgba(4,170,109,0.35);
  }
}
.tab-logo-text {
  font-size: 13px; font-weight: 600;
  color: var(--text-primary);
  letter-spacing: 0.1em; text-transform: uppercase;
}
.tab-btn {
  font-family: var(--sans); font-size: 12px; font-weight: 500;
  letter-spacing: 0.04em; padding: 0 20px; height: 42px;
  background: transparent; color: var(--text-muted);
  border: none; border-bottom: 3px solid transparent;
  cursor: pointer; transition: all 0.15s;
  display: flex; align-items: center; gap: 8px;
  white-space: nowrap; position: relative; bottom: -2px;
}
.tab-btn:hover { color: var(--text-secondary); background: rgba(255,255,255,0.03) !important; }
.tab-btn.tab-active {
  color: var(--green);
  border-bottom: 3px solid var(--green);
  text-shadow: 0 0 12px rgba(4,170,109,0.5) !important;
}
body.light .par-tab-bar .tab-btn.tab-active { text-shadow: 0 0 12px rgba(2,150,89,0.35) !important; }
body.light .par-tab-bar .tab-btn:hover { background: rgba(0,0,0,0.025) !important; }
body.light .par-tab-bar { box-shadow: 0 2px 12px rgba(0,0,0,0.09) !important; }
.tab-spacer { flex: 1; }
/* ── HEADER 3-ZONE LAYOUT ── */
.par-header-left   { flex: 1 1 0; display: flex; flex-direction: column; min-width: 0; }
.par-header-center { flex: 0 0 auto; display: flex; align-items: center; justify-content: center; }
.par-header .par-stats { flex: 1 1 0; justify-content: flex-end; }
.par-header .queue-popover {
  top: calc(100% + 14px);
  right: 50%;
  transform: translateX(50%) translateY(-6px);
}
.par-header .queue-popover.queue-popover-open {
  transform: translateX(50%) translateY(0);
}
.par-header .queue-popover::before {
  right: 50%;
  margin-right: -4px;
}
/* ── HEADER ── */
.par-header {
  background: var(--bg-surface);
  border-bottom: 1px solid var(--border);
  padding: 12px 20px;
  display: flex; align-items: center; justify-content: space-between;
  gap: 16px; flex-wrap: wrap;
  flex: 0 0 auto;
  position: sticky; top: 42px; z-index: 100;
  box-shadow: 0 2px 8px rgba(0,0,0,0.25) !important;
}
body.light .par-header { box-shadow: 0 2px 8px rgba(0,0,0,0.07) !important; }
.par-title { font-size: 13px; font-weight: 600; color: var(--text-primary); letter-spacing: 0.08em; text-transform: uppercase; }
.par-subtitle { font-size: 10px; color: var(--text-muted); letter-spacing: 0.07em; text-transform: uppercase; margin-top: 1px; }
.par-stats { display: flex; gap: 6px; flex-wrap: wrap; align-items: center; }
/* ── STAT PILLS ── */
.stat-pill {
  font-family: var(--mono); font-size: 10px;
  padding: 3px 10px; border-radius: 20px;
  border: 1px solid var(--border); color: var(--text-secondary);
  background: var(--bg-card); white-space: nowrap;
  box-shadow: 0 1px 3px rgba(0,0,0,0.25) !important;
  transition: box-shadow 0.2s, transform 0.2s !important;
}
.stat-pill.live {
  border-color: var(--green-dim); color: var(--green);
  box-shadow: 0 0 10px rgba(4,170,109,0.3), 0 1px 3px rgba(0,0,0,0.2) !important;
}
.stat-pill.late {
  border-color: #7a2233; color: var(--red);
  box-shadow: 0 0 10px rgba(255,77,106,0.3), 0 1px 3px rgba(0,0,0,0.2) !important;
}
body.light .stat-pill { box-shadow: 0 1px 3px rgba(0,0,0,0.1) !important; }
body.light .stat-pill.live { box-shadow: 0 0 10px rgba(2,150,89,0.2), 0 1px 3px rgba(0,0,0,0.08) !important; }
body.light .stat-pill.late { box-shadow: 0 0 10px rgba(217,48,80,0.2), 0 1px 3px rgba(0,0,0,0.08) !important; }
/* ── CONTROLS BAR ── */
.controls-bar {
  background: var(--bg-surface);
  border-bottom: 1px solid var(--border);
  padding: 8px 20px;
  display: flex; align-items: center; gap: 14px; flex-wrap: wrap;
  flex: 0 0 auto;
}
.tab-search {
  font-family: var(--sans); font-size: 12px;
  background: var(--bg-card); color: var(--text-primary);
  border: 1px solid var(--border); border-radius: var(--radius-sm);
  padding: 5px 11px; width: 200px; outline: none;
  box-shadow: inset 0 1px 3px rgba(0,0,0,0.25) !important;
  transition: border-color 0.2s, box-shadow 0.2s !important;
}
.tab-search::placeholder { color: var(--text-muted); }
.tab-search:focus {
  border-color: var(--green);
  box-shadow: 0 0 0 3px rgba(4,170,109,0.15), inset 0 1px 3px rgba(0,0,0,0.2) !important;
}
body.light .tab-search { box-shadow: inset 0 1px 3px rgba(0,0,0,0.1) !important; }
body.light .tab-search:focus { box-shadow: 0 0 0 3px rgba(2,150,89,0.12), inset 0 1px 3px rgba(0,0,0,0.07) !important; }
.ctrl-divider { width:1px; height:18px; background: var(--border); flex-shrink:0; }
.ctrl-label { font-size:10px; letter-spacing:0.07em; text-transform:uppercase; color:var(--text-muted); white-space:nowrap; }
.type-controls { display:flex; align-items:center; gap:5px; }
/* ── TOGGLE BUTTONS ── */
.toggle-btn {
  font-family: var(--sans); font-size: 11px; font-weight: 500;
  padding: 3px 11px; border-radius: 20px;
  border: 1px solid var(--border); background: transparent;
  color: var(--text-secondary); cursor: pointer;
  user-select: none; letter-spacing: 0.02em;
  box-shadow: inset 0 1px 0 rgba(255,255,255,0.04), 0 1px 2px rgba(0,0,0,0.3) !important;
  transition: all 0.15s !important;
}
.toggle-btn.active-live {
  background: var(--green-glow); border-color: var(--green); color: var(--green);
  box-shadow: 0 0 8px rgba(4,170,109,0.35), inset 0 1px 0 rgba(4,170,109,0.2) !important;
}
.toggle-btn.active-training {
  background: rgba(245,200,66,0.1); border-color: var(--amber); color: var(--amber);
  box-shadow: 0 0 8px rgba(245,200,66,0.3), inset 0 1px 0 rgba(245,200,66,0.15) !important;
}
.toggle-btn.active-loc {
  box-shadow: 0 0 8px rgba(99,179,237,0.3), inset 0 1px 0 rgba(99,179,237,0.15) !important;
}
.toggle-btn:hover:not(.active-live):not(.active-training) { border-color: var(--border-light); color: var(--text-primary); }
.toggle-btn:hover {
  transform: translateY(-1px) !important;
  box-shadow: 0 3px 8px rgba(0,0,0,0.3), inset 0 1px 0 rgba(255,255,255,0.06) !important;
}
.toggle-btn:active {
  transform: translateY(0px) !important;
  box-shadow: inset 0 2px 4px rgba(0,0,0,0.35) !important;
}
body.light .toggle-btn { box-shadow: inset 0 1px 0 rgba(255,255,255,0.9), 0 1px 2px rgba(0,0,0,0.12) !important; }
body.light .toggle-btn:hover { box-shadow: 0 3px 8px rgba(0,0,0,0.12), inset 0 1px 0 rgba(255,255,255,0.95) !important; }
body.light .toggle-btn.active-live { box-shadow: 0 0 8px rgba(2,150,89,0.25), inset 0 1px 0 rgba(2,150,89,0.15) !important; }
body.light .toggle-btn.active-training { box-shadow: 0 0 8px rgba(196,154,0,0.2), inset 0 1px 0 rgba(196,154,0,0.12) !important; }
body.light .toggle-btn.active-loc {
  background:   rgba(43, 123, 200, 0.12);
  border-color: #2b7bc8;
  color:        #2b7bc8;
  box-shadow: 0 0 8px rgba(43,123,200,0.2), inset 0 1px 0 rgba(43,123,200,0.12) !important;
}
/* ── COLUMN CHIPS ── */
.col-controls { display:flex; align-items:center; gap:4px; flex-wrap:wrap; }
.col-chip {
  font-size:10px; padding:2px 8px; border-radius:20px;
  border:1px solid var(--border); background:transparent;
  color:var(--text-muted); cursor:pointer;
  white-space:nowrap; user-select:none;
  box-shadow: inset 0 1px 0 rgba(255,255,255,0.04) !important;
  transition: all 0.15s !important;
}
.col-chip.col-on {
  border-color:var(--border-light); color:var(--text-secondary); background:var(--bg-card);
  box-shadow: inset 0 1px 3px rgba(0,0,0,0.2), 0 1px 2px rgba(0,0,0,0.25) !important;
}
.col-chip:hover {
  border-color:var(--border-light); color:var(--text-primary);
  transform: translateY(-1px) !important;
  box-shadow: 0 2px 6px rgba(0,0,0,0.25) !important;
}
.col-chip:active {
  transform: translateY(0px) !important;
  box-shadow: inset 0 2px 4px rgba(0,0,0,0.25) !important;
}
body.light .col-chip { box-shadow: inset 0 1px 0 rgba(255,255,255,0.9) !important; }
body.light .col-chip.col-on { box-shadow: inset 0 1px 3px rgba(0,0,0,0.08), 0 1px 2px rgba(0,0,0,0.1) !important; }
body.light .col-chip:hover { box-shadow: 0 2px 6px rgba(0,0,0,0.12) !important; }
/* ── TABLE WRAPPER ── */
.table-round {
  margin: 14px 16px;
  border: 1px solid var(--border); border-radius: var(--radius-lg);
  overflow: hidden; overflow-x: auto;
  flex: 1 1 auto; min-height: 0; overflow-y: auto;
  background: transparent;
  box-shadow: 0 4px 24px rgba(0,0,0,0.35), 0 1px 4px rgba(0,0,0,0.25) !important;
}
body.light .table-round { box-shadow: 0 4px 24px rgba(0,0,0,0.1), 0 1px 4px rgba(0,0,0,0.07) !important; }
.table-round::-webkit-scrollbar       { width:5px; height:5px; }
.table-round::-webkit-scrollbar-track { background: var(--bg-base); }
.table-round::-webkit-scrollbar-thumb { background: var(--border-light); border-radius:3px; }
/* ── TABLE ── */
.par-table {
  font-family: var(--sans); font-size:13px;
  border-collapse: collapse; width:100%; min-width:860px;
  background-color: transparent;
}
.par-table thead th {
  background: var(--bg-card); color: var(--text-muted);
  font-size:10px; font-weight:500; letter-spacing:0.08em; text-transform:uppercase;
  padding:9px 12px; border-bottom:1px solid var(--border);
  white-space:nowrap; text-align:center;
  position:sticky; top:0; z-index:10;
  cursor:pointer; transition:color 0.15s; user-select:none;
}
.par-table thead th:hover { color: var(--text-primary); }
.par-table thead th[aria-sort="ascending"]::after  { content:' ↑'; color: var(--green); }
.par-table thead th[aria-sort="descending"]::after { content:' ↓'; color: var(--green); }
.par-table tbody tr {
  border-bottom:1px solid var(--border);
  animation:rowIn 0.2s ease both;
  background-color: transparent;
  border-left: 2px solid transparent !important;
  transition: background 0.1s, border-left-color 0.15s !important;
}
.par-table tbody tr:last-child { border-bottom:none; }
.par-table tbody tr:hover      { background: var(--bg-hover); border-left-color: var(--green) !important; }
.par-table tbody tr[data-type="training"]       { opacity:0.65; }
.par-table tbody tr[data-type="training"]:hover { opacity:1; border-left-color: var(--amber) !important; }
@keyframes rowIn { from{opacity:0;transform:translateY(3px)} to{opacity:1;transform:translateY(0)} }
.par-table td {
  padding:7px 12px; color:var(--text-primary);
  text-align:center; vertical-align:middle; border:none;
  font-family:var(--mono); font-size:11px;
  background-color: transparent;
}
/* ── MEASURE column alignment ── */
#measure-table td:nth-child(3),#measure-table td:nth-child(4),#measure-table td:nth-child(5),
#measure-table td:nth-child(6),#measure-table td:nth-child(8),#measure-table td:nth-child(9),#measure-table td:nth-child(10)
  { text-align:left; font-family:var(--sans); font-size:13px; }
#measure-table thead th:nth-child(3),#measure-table thead th:nth-child(4),#measure-table thead th:nth-child(5),
#measure-table thead th:nth-child(6),#measure-table thead th:nth-child(8),#measure-table thead th:nth-child(9),#measure-table thead th:nth-child(10)
  { text-align:left; }
#measure-table thead th:nth-child(7),#measure-table td:nth-child(7) { text-align:center; }
#measure-table td:nth-child(2) { font-size:13px; }
#measure-table td:nth-child(5),#measure-table td:nth-child(6),#measure-table td:nth-child(7),
#measure-table td:nth-child(8),#measure-table td:nth-child(9),#measure-table td:nth-child(10) { color:var(--text-secondary); }
/* ── QC column alignment ── */
#qc-table td:nth-child(3),#qc-table td:nth-child(4),#qc-table td:nth-child(5),
#qc-table td:nth-child(7),#qc-table td:nth-child(8),#qc-table td:nth-child(9)
  { text-align:left; font-family:var(--sans); font-size:13px; }
#qc-table thead th:nth-child(3),#qc-table thead th:nth-child(4),#qc-table thead th:nth-child(5),
#qc-table thead th:nth-child(7),#qc-table thead th:nth-child(8),#qc-table thead th:nth-child(9)
  { text-align:left; }
#qc-table td:nth-child(2) { font-size:13px; }
#qc-table td:nth-child(1),#qc-table td:nth-child(6),#qc-table td:nth-child(7),
#qc-table td:nth-child(8),#qc-table td:nth-child(9) { color:var(--text-secondary); }
/* ── BADGES ── */
.badge-live {
  display:inline-block; font-family:var(--sans); font-size:11px; font-weight:500;
  letter-spacing:0.02em; text-transform:none;
  color:var(--green); background:var(--green-glow); padding:3px 11px; border-radius:20px; border:1px solid var(--green);
  box-shadow: 0 0 8px rgba(4,170,109,0.35), inset 0 1px 0 rgba(4,170,109,0.2) !important;
}
.badge-training {
  display:inline-block; font-family:var(--sans); font-size:11px; font-weight:500;
  letter-spacing:0.02em; text-transform:none;
  color:var(--amber); background:rgba(245,200,66,0.1); padding:3px 11px; border-radius:20px; border:1px solid var(--amber);
  box-shadow: 0 0 8px rgba(245,200,66,0.25), inset 0 1px 0 rgba(245,200,66,0.15) !important;
}
body.light .badge-live { box-shadow: 0 0 8px rgba(2,150,89,0.25), inset 0 1px 0 rgba(2,150,89,0.15) !important; }
body.light .badge-training { box-shadow: 0 0 8px rgba(196,154,0,0.2), inset 0 1px 0 rgba(196,154,0,0.12) !important; }
/* ── THEME TOGGLE ── */
#themeToggle {
  font-family:var(--sans); font-size:11px; font-weight:500;
  padding:3px 11px; border-radius:20px;
  border:1px solid var(--border); background:transparent; color:var(--text-secondary);
  cursor:pointer; user-select:none; letter-spacing:0.02em;
  display:flex; align-items:center; gap:5px; align-self:center; margin-left:8px;
  box-shadow: inset 0 1px 0 rgba(255,255,255,0.04), 0 1px 2px rgba(0,0,0,0.3) !important;
  transition: all 0.15s !important;
}
#themeToggle:hover {
  border-color:var(--border-light); color:var(--text-primary);
  transform: translateY(-1px) !important;
  box-shadow: 0 3px 8px rgba(0,0,0,0.3), inset 0 1px 0 rgba(255,255,255,0.06) !important;
}
#themeToggle:active {
  transform: translateY(0px) !important;
  box-shadow: inset 0 2px 4px rgba(0,0,0,0.35) !important;
}
body.light #themeToggle { box-shadow: inset 0 1px 0 rgba(255,255,255,0.9), 0 1px 2px rgba(0,0,0,0.12) !important; }
body.light #themeToggle:hover { box-shadow: 0 3px 8px rgba(0,0,0,0.12), inset 0 1px 0 rgba(255,255,255,0.95) !important; }
/* ── MISC / STATE HELPERS ── */
.hidden-column { display:none !important; }
/* ── RELOAD TIMER FOOTER ── */
#reloadTimerContainer {
  flex: 0 0 auto;
  background:var(--bg-surface); border-top:1px solid var(--border);
  padding:5px 18px; display:flex; align-items:center; justify-content:space-between;
  gap:8px; font-family:var(--mono); font-size:10px; color:var(--text-muted);
  z-index: 999 !important;
}
#reloadTimerContainer .footer-left,
#reloadTimerContainer .footer-right {
  flex: 1 1 0;
  display: flex;
  align-items: center;
}
#reloadTimerContainer .footer-left  { justify-content: flex-start; gap: 5px; }
#reloadTimerContainer .footer-right { justify-content: flex-end; }
#reloadTimerContainer .footer-center {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 8px;
}
.footer-star {
  color: var(--amber);
  font-size: 11px;
  line-height: 1;
  text-shadow: 0 0 6px rgba(245,200,66,0.5);
}
.footer-brand {
  font-family: var(--sans);
  font-weight: 600;
  letter-spacing: 0.12em;
  text-transform: uppercase;
  color: var(--text-secondary);
  font-size: 10px;
}
.footer-version {
  font-family: var(--mono);
  font-size: 10px;
  color: var(--text-muted);
  letter-spacing: 0.04em;
}
body.light .footer-star { text-shadow: 0 0 6px rgba(196,154,0,0.4); }
/* ── TAB PANELS ── */
.tab-panel { display:none; background: transparent; }
.tab-panel.panel-active {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0; /* allow the panel to shrink so .table-round can scroll internally */
  background: transparent;
}
.tab-panel.panel-enter { animation: tab-fade-in 0.18s ease forwards; }
.tab-panel.panel-exit  { animation: tab-fade-out 0.18s ease forwards; }
@keyframes tab-fade-in {
  from { opacity: 0; transform: translateX(6px); }
  to   { opacity: 1; transform: translateX(0); }
}
@keyframes tab-fade-out {
  from { opacity: 1; transform: translateX(0); }
  to   { opacity: 0; transform: translateX(-6px); }
}
/* ============================================================================
   DUAL CLOCK — PH & Bogotá
   ============================================================================ */
.dual-clock {
  position: absolute;
  left: 50%;
  top: 50%;
  transform: translate(-50%, -50%);
  display: flex;
  align-items: center;
  gap: 0;
  margin-right: 0;
  background: var(--bg-card);
  border: 1px solid var(--border);
  border-radius: var(--radius-md);
  overflow: hidden;
  box-shadow: inset 0 1px 0 rgba(255,255,255,0.04), 0 1px 3px rgba(0,0,0,0.3);
}
.clock-item {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 5px 12px;
  transition: background 0.15s;
}
.clock-item:hover { background: var(--bg-hover); }
.clock-icon {
  font-size: 13px;
  line-height: 1;
  filter: drop-shadow(0 0 3px rgba(255,200,0,0.3));
  transition: filter 0.3s;
  flex-shrink: 0;
}
.clock-icon.is-night { filter: drop-shadow(0 0 3px rgba(100,140,255,0.35)); }
.clock-info {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0px;
  line-height: 1;
}
.clock-label {
  font-family: var(--sans);
  font-size: 8px;
  font-weight: 600;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--text-muted);
  line-height: 1;
}
.clock-time {
  font-family: var(--mono);
  font-size: 12px;
  font-weight: 500;
  color: var(--text-primary);
  letter-spacing: 0.05em;
  line-height: 1.4;
  transition: color 0.3s;
}
.clock-item.is-night .clock-time { color: var(--text-secondary); }
.clock-item.is-day .clock-time { color: var(--text-primary); }
.clock-divider {
  width: 1px;
  height: 28px;
  background: var(--border);
  flex-shrink: 0;
}
body.light .dual-clock {
  background: var(--bg-card);
  border-color: var(--border);
  box-shadow: inset 0 1px 0 rgba(255,255,255,0.8), 0 1px 3px rgba(0,0,0,0.1);
}
body.light .clock-item:hover { background: var(--bg-hover); }
body.light .clock-time { color: var(--text-primary); }
body.light .clock-item.is-night .clock-time { color: var(--text-secondary); }
@media (max-width: 768px) {
  .dual-clock { display: none; }
}
/* ============================================================================
   QUEUE POPOVER
   ============================================================================ */
.queue-btn-wrap {
  position: relative;
  display: flex;
  align-items: center;
  margin-right: 8px;
  z-index: 99999;
}
.queue-toggle-btn {
  font-family: var(--sans);
  font-size: 11px;
  font-weight: 500;
  padding: 3px 11px;
  border-radius: 20px;
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-secondary);
  cursor: pointer;
  transition: all 0.15s;
  user-select: none;
  letter-spacing: 0.02em;
  display: flex;
  align-items: center;
  gap: 5px;
  align-self: center;
  box-shadow: inset 0 1px 0 rgba(255,255,255,0.04), 0 1px 2px rgba(0,0,0,0.3);
}
.queue-toggle-btn:hover {
  border-color: var(--border-light);
  color: var(--text-primary);
  transform: translateY(-1px);
  box-shadow: 0 3px 8px rgba(0,0,0,0.25), inset 0 1px 0 rgba(255,255,255,0.06);
}
.queue-toggle-btn:active {
  transform: translateY(0px);
  box-shadow: inset 0 2px 4px rgba(0,0,0,0.3);
}
.queue-toggle-btn.queue-open {
  border-color: var(--green);
  color: var(--green);
  box-shadow: 0 0 8px rgba(4,170,109,0.25), inset 0 1px 0 rgba(4,170,109,0.15);
}
.queue-btn-icon { font-size: 12px; line-height: 1; }
.queue-btn-label { font-size: 11px; }
.queue-btn-badge {
  font-family: var(--mono);
  font-size: 9px;
  padding: 1px 6px;
  border-radius: 20px;
  border: 1px solid var(--green);
  color: var(--green);
  background: var(--green-glow);
  opacity: 1;
  min-width: 20px;
  text-align: center;
}
body.light .queue-toggle-btn { box-shadow: inset 0 1px 0 rgba(255,255,255,0.9), 0 1px 2px rgba(0,0,0,0.1); }
body.light .queue-toggle-btn:hover { box-shadow: 0 3px 8px rgba(0,0,0,0.1), inset 0 1px 0 rgba(255,255,255,0.95); }
body.light .queue-toggle-btn.queue-open { box-shadow: 0 0 8px rgba(2,150,89,0.2), inset 0 1px 0 rgba(2,150,89,0.1); }
.queue-popover {
  position: absolute;
  top: calc(100% + 10px);
  right: 0;
  width: 240px;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius-md);
  box-shadow: 0 8px 32px rgba(0,0,0,0.4), 0 2px 8px rgba(0,0,0,0.3);
  z-index: 99999;
  overflow: hidden;
  opacity: 0;
  transform: translateY(-6px);
  pointer-events: none;
  transition: opacity 0.18s ease, transform 0.18s ease;
}
.queue-popover.queue-popover-open {
  opacity: 1;
  transform: translateY(0);
  pointer-events: all;
}
.queue-popover::before {
  content: '';
  position: absolute;
  top: -5px;
  right: 20px;
  width: 9px;
  height: 9px;
  background: var(--bg-surface);
  border-left: 1px solid var(--border);
  border-top: 1px solid var(--border);
  transform: rotate(45deg);
  z-index: 1;
}
body.light .queue-popover { box-shadow: 0 8px 32px rgba(0,0,0,0.12), 0 2px 8px rgba(0,0,0,0.08); }
.queue-popover-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 10px 14px 8px;
  border-bottom: 1px solid var(--border);
  background: var(--bg-card);
}
.queue-popover-title {
  font-family: var(--sans);
  font-size: 11px;
  font-weight: 600;
  color: var(--text-primary);
  letter-spacing: 0.06em;
  text-transform: uppercase;
}
.queue-copy-btn {
  display: flex;
  align-items: center;
  gap: 4px;
  font-family: var(--sans);
  font-size: 10px;
  font-weight: 500;
  background: rgba(245, 200, 66, 0.08);
  border: 1px solid rgba(245, 200, 66, 0.4);
  border-radius: var(--radius-sm);
  color: var(--amber);
  cursor: pointer;
  padding: 3px 8px;
  transition: all 0.15s;
  line-height: 1.4;
  letter-spacing: 0.03em;
  box-shadow: 0 0 6px rgba(245,200,66,0.1), inset 0 1px 0 rgba(245,200,66,0.08);
}
.queue-copy-btn:hover {
  background: rgba(245, 200, 66, 0.15);
  border-color: var(--amber);
  color: var(--amber);
  box-shadow: 0 0 10px rgba(245,200,66,0.2), inset 0 1px 0 rgba(245,200,66,0.1);
  transform: translateY(-1px);
}
.queue-copy-btn:active {
  transform: translateY(0px);
  box-shadow: inset 0 2px 4px rgba(0,0,0,0.2);
}
.queue-copy-icon { font-size: 13px; line-height: 1; color: var(--amber); }
.queue-copy-text { font-size: 10px; font-weight: 500; color: var(--amber); letter-spacing: 0.04em; text-transform: uppercase; }
.queue-copy-btn.copy-success {
  border-color: var(--green);
  background: var(--green-glow);
  box-shadow: 0 0 8px rgba(4,170,109,0.2);
}
.queue-copy-btn.copy-success .queue-copy-icon,
.queue-copy-btn.copy-success .queue-copy-text { color: var(--green); }
.queue-copy-btn.copy-error {
  border-color: var(--red);
  background: rgba(255,77,106,0.1);
  box-shadow: 0 0 8px rgba(255,77,106,0.2);
}
.queue-copy-btn.copy-error .queue-copy-icon,
.queue-copy-btn.copy-error .queue-copy-text { color: var(--red); }
body.light .queue-copy-btn {
  background: rgba(196,154,0,0.08);
  border-color: rgba(196,154,0,0.4);
  color: var(--amber);
  box-shadow: 0 0 6px rgba(196,154,0,0.1);
}
body.light .queue-copy-btn:hover {
  background: var(--bg-hover);
  border-color: var(--amber);
  box-shadow: 0 0 10px rgba(196,154,0,0.15);
}
body.light .queue-copy-btn .queue-copy-icon,
body.light .queue-copy-btn .queue-copy-text { color: var(--amber); }
body.light .queue-copy-btn.copy-success { border-color: var(--green); background: var(--green-glow); }
body.light .queue-copy-btn.copy-success .queue-copy-icon,
body.light .queue-copy-btn.copy-success .queue-copy-text { color: var(--green); }
body.light .queue-copy-btn.copy-error { border-color: var(--red); background: rgba(217,48,80,0.08); }
body.light .queue-copy-btn.copy-error .queue-copy-icon,
body.light .queue-copy-btn.copy-error .queue-copy-text { color: var(--red); }
.queue-popover-timestamp {
  font-family: var(--mono);
  font-size: 9px;
  color: var(--text-muted);
  padding: 5px 14px;
  background: var(--bg-card);
  border-bottom: 1px solid var(--border);
  letter-spacing: 0.04em;
}
.queue-popover-body { padding: 8px 0; }
.queue-section { padding: 4px 0; }
.queue-section-title {
  font-family: var(--sans);
  font-size: 9px;
  font-weight: 600;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--text-muted);
  padding: 4px 14px 3px;
}
.queue-section-divider { height: 1px; background: var(--border); margin: 6px 14px; }
.queue-item-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 4px 14px;
  transition: background 0.1s;
}
.queue-item-row:hover { background: var(--bg-hover); }
.queue-item-label { font-family: var(--sans); font-size: 12px; color: var(--text-secondary); }
.queue-item-count {
  font-family: var(--mono);
  font-size: 12px;
  font-weight: 500;
  color: var(--text-primary);
  min-width: 28px;
  text-align: right;
}
.queue-item-count.is-error   { color: var(--red); font-size: 10px; }
.queue-item-count.is-zero    { color: var(--text-muted); }
.queue-item-count.has-value  { color: var(--text-primary); }
.queue-loading {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 5px;
  padding: 16px;
}
.queue-loading-dot {
  width: 5px;
  height: 5px;
  border-radius: 50%;
  background: var(--text-muted);
  animation: queue-dot-pulse 1.2s ease-in-out infinite;
}
.queue-loading-dot:nth-child(2) { animation-delay: 0.2s; }
.queue-loading-dot:nth-child(3) { animation-delay: 0.4s; }
@keyframes queue-dot-pulse {
  0%,100% { opacity: 0.3; transform: scale(0.8); }
  50%     { opacity: 1;   transform: scale(1.2); }
}
.queue-popover-footer {
  padding: 8px 14px;
  border-top: 1px solid var(--border);
  background: var(--bg-card);
  display: flex;
  justify-content: flex-end;
}
.queue-refresh-btn {
  font-family: var(--sans);
  font-size: 10px;
  font-weight: 500;
  padding: 3px 10px;
  border-radius: 20px;
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-muted);
  cursor: pointer;
  transition: all 0.15s;
  letter-spacing: 0.04em;
}
.queue-refresh-btn:hover {
  border-color: var(--green);
  color: var(--green);
  background: var(--green-glow);
}
.queue-refresh-btn:active { transform: scale(0.97); }
.queue-refresh-btn.is-refreshing {
  color: var(--text-muted);
  border-color: var(--border);
  pointer-events: none;
  animation: queue-spin 0.8s linear infinite;
}
@keyframes queue-spin {
  from { transform: rotate(0deg); }
  to   { transform: rotate(360deg); }
}
body.light .queue-item-row:hover { background: var(--bg-hover); }
@media (max-width: 768px) {
  .queue-popover  { right: -60px; width: 220px; }
  .queue-btn-label { display: none; }
}
/* ============================================================================
   SKELETON LOADING ROWS
   ============================================================================ */
.skeleton-row td {
  padding: 7px 12px !important;
  border-bottom: 1px solid var(--border) !important;
}
.skeleton-cell {
  height: 14px;
  border-radius: var(--radius-sm);
  background: linear-gradient(
    90deg,
    var(--bg-card)    0%,
    var(--bg-hover)   40%,
    var(--bg-card)    80%
  );
  background-size: 200% 100%;
  animation: skeleton-shimmer 1.6s ease-in-out infinite;
}
.skeleton-cell.sk-sm  { width: 40%;  }
.skeleton-cell.sk-md  { width: 65%;  }
.skeleton-cell.sk-lg  { width: 85%;  }
.skeleton-cell.sk-xl  { width: 100%; }
.skeleton-cell.sk-xs  { width: 25%;  }
@keyframes skeleton-shimmer {
  0%   { background-position: 200% 0; }
  100% { background-position: -200% 0; }
}
.skeleton-row:nth-child(1) td .skeleton-cell { animation-delay: 0.0s; }
.skeleton-row:nth-child(2) td .skeleton-cell { animation-delay: 0.1s; }
.skeleton-row:nth-child(3) td .skeleton-cell { animation-delay: 0.2s; }
.skeleton-row:nth-child(4) td .skeleton-cell { animation-delay: 0.3s; }
.skeleton-row:nth-child(5) td .skeleton-cell { animation-delay: 0.4s; }
/* ============================================================================
   DUE TIME PULSE ALERTS
   ============================================================================ */
td.due {
  position: relative !important;
  overflow: hidden !important;
}
td.due.due-warning-pulse  { animation: due-warning-flash  1.5s ease forwards !important; }
td.due.due-critical-pulse { animation: due-critical-flash 1.5s ease forwards !important; }
@keyframes due-warning-flash {
  0%   { background-color: transparent; box-shadow: none; }
  20%  { background-color: rgba(255, 77, 106, 0.15); box-shadow: inset 0 0 12px rgba(255, 77, 106, 0.2); }
  50%  { background-color: rgba(255, 77, 106, 0.25); box-shadow: inset 0 0 16px rgba(255, 77, 106, 0.3); }
  80%  { background-color: rgba(255, 77, 106, 0.15); box-shadow: inset 0 0 12px rgba(255, 77, 106, 0.2); }
  100% { background-color: transparent; box-shadow: none; }
}
@keyframes due-critical-flash {
  0%   { background-color: transparent; box-shadow: none; }
  15%  { background-color: rgba(255, 77, 106, 0.3);  box-shadow: inset 0 0 16px rgba(255, 77, 106, 0.4); }
  40%  { background-color: rgba(255, 77, 106, 0.45); box-shadow: inset 0 0 20px rgba(255, 77, 106, 0.5); }
  60%  { background-color: rgba(255, 77, 106, 0.45); box-shadow: inset 0 0 20px rgba(255, 77, 106, 0.5); }
  85%  { background-color: rgba(255, 77, 106, 0.3);  box-shadow: inset 0 0 16px rgba(255, 77, 106, 0.4); }
  100% { background-color: transparent; box-shadow: none; }
}
body.light td.due.due-warning-pulse  { animation: due-warning-flash-light  1.5s ease forwards !important; }
body.light td.due.due-critical-pulse { animation: due-critical-flash-light 1.5s ease forwards !important; }
@keyframes due-warning-flash-light {
  0%   { background-color: transparent;            box-shadow: none; }
  20%  { background-color: rgba(217, 48, 80, 0.1); box-shadow: inset 0 0 12px rgba(217,48,80,0.15); }
  50%  { background-color: rgba(217, 48, 80, 0.18);box-shadow: inset 0 0 16px rgba(217,48,80,0.22); }
  80%  { background-color: rgba(217, 48, 80, 0.1); box-shadow: inset 0 0 12px rgba(217,48,80,0.15); }
  100% { background-color: transparent;            box-shadow: none; }
}
@keyframes due-critical-flash-light {
  0%   { background-color: transparent;            box-shadow: none; }
  15%  { background-color: rgba(217, 48, 80, 0.2); box-shadow: inset 0 0 16px rgba(217,48,80,0.25); }
  40%  { background-color: rgba(217, 48, 80, 0.32);box-shadow: inset 0 0 20px rgba(217,48,80,0.35); }
  60%  { background-color: rgba(217, 48, 80, 0.32);box-shadow: inset 0 0 20px rgba(217,48,80,0.35); }
  85%  { background-color: rgba(217, 48, 80, 0.2); box-shadow: inset 0 0 16px rgba(217,48,80,0.25); }
  100% { background-color: transparent;            box-shadow: none; }
}
tr[data-type="training"] td.due.due-warning-pulse,
tr[data-type="training"] td.due.due-critical-pulse {
  animation: none !important;
  background-color: transparent !important;
  box-shadow: none !important;
}
/* ============================================================================
   BOG SITE TAG — Username column marker
   ============================================================================ */
.bog-tag {
  display: inline-block;
  font-family: var(--mono);
  font-size: 9px;
  font-weight: 600;
  letter-spacing: 0.08em;
  padding: 1px 5px;
  border-radius: 3px;
  border: 1px solid;
  margin-left: 5px;
  vertical-align: middle;
  line-height: 1.4;
  white-space: nowrap;
  user-select: none;
}
.bog-tag-bog {
  color:        #c0392b;
  border-color: #8b1a2a;
  background:   rgba(139,26,42,0.12);
}
.bog-tag-mnl {
  color:        #63b3ed;
  border-color: #2b7bc8;
  background:   rgba(99,179,237,0.1);
}
.bog-tag-cbu {
  color:        #38b2ac;
  border-color: #2c7a7b;
  background:   rgba(56,178,172,0.1);
}
.bog-tag-bel {
  color:        var(--text-secondary);
  border-color: var(--border-light);
  background:   var(--bg-card);
}
.bog-tag-unknown {
  color:        var(--text-muted);
  border-color: var(--border);
  background:   transparent;
}
body.light .bog-tag-bog {
  color:        #a82030;
  border-color: #7b1520;
  background:   rgba(168,32,48,0.08);
}
body.light .bog-tag-mnl {
  color:        #2b7bc8;
  border-color: #1a5fa0;
  background:   rgba(43,123,200,0.08);
}
body.light .bog-tag-cbu {
  color:        #2c7a7b;
  border-color: #1a5a5b;
  background:   rgba(44,122,123,0.08);
}
/* ============================================================================
   DUPLICATE USERNAME ALERT
   ============================================================================ */
.dup-alert-container {
  position: fixed;
  top: 54px;
  right: 16px;
  z-index: 500;
  display: flex;
  flex-direction: column;
  gap: 6px;
  max-width: 300px;
  pointer-events: none;
}
.dup-alert {
  background: var(--bg-surface);
  border: 1px solid var(--red);
  border-left: 3px solid var(--red);
  border-radius: var(--radius-sm);
  padding: 8px 10px 8px 12px;
  font-family: var(--sans);
  font-size: 11px;
  color: var(--text-primary);
  box-shadow: 0 4px 16px rgba(0,0,0,0.3);
  animation: dup-alert-in 0.25s ease;
  display: flex;
  align-items: flex-start;
  gap: 8px;
  pointer-events: all;
}
.dup-alert-icon {
  color: var(--red);
  font-size: 13px;
  line-height: 1.4;
  flex-shrink: 0;
}
.dup-alert-text {
  flex: 1;
  line-height: 1.4;
}
.dup-alert-text strong { color: var(--red); }
.dup-alert-close {
  background: none;
  border: none;
  color: var(--text-muted);
  cursor: pointer;
  font-size: 13px;
  line-height: 1;
  padding: 0 2px;
  flex-shrink: 0;
}
.dup-alert-close:hover { color: var(--text-primary); }
@keyframes dup-alert-in {
  from { opacity: 0; transform: translateX(20px); }
  to   { opacity: 1; transform: translateX(0); }
}
body.light .dup-alert { box-shadow: 0 4px 16px rgba(0,0,0,0.12); }
@media (max-width: 768px) {
  .dup-alert-container { right: 8px; left: 8px; max-width: none; }
}
'@
$ParJs = @'
/* ============================================================================
   Created and developed by PIA — members: Pogi, LT, Rona
   ============================================================================ */
/* ── SERVER TIMEZONE ── */
const SERVER_TZ = 'America/Los_Angeles';
function getLAOffsetMs(dateForContext) {
  const formatter = new Intl.DateTimeFormat('en-US', {
    timeZone: SERVER_TZ,
    year:'numeric',month:'2-digit',day:'2-digit',
    hour:'2-digit',minute:'2-digit',second:'2-digit',
    hour12:false
  });
  const parts   = formatter.formatToParts(dateForContext);
  const get     = type => Number(parts.find(p=>p.type===type)?.value??0);
  const laLocal = Date.UTC(get('year'),get('month')-1,get('day'),get('hour'),get('minute'),get('second'));
  return dateForContext.getTime() - laLocal;
}
function parseServerUtc(ts) {
  if (!ts) return new Date(NaN);
  const s = String(ts).trim();
  if (/[zZ]$/.test(s) || /[+\-]\d{2}:?\d{2}$/.test(s)) return new Date(s);
  const asIfUtc  = new Date(s + 'Z');
  const offsetMs = getLAOffsetMs(asIfUtc);
  return new Date(asIfUtc.getTime() + offsetMs);
}
/* ── TAB SWITCHING ── */
function switchTab(tab) {
  document.querySelectorAll('.tab-btn').forEach(b=>b.classList.remove('tab-active'));
  document.querySelectorAll('.tab-panel').forEach(p=>p.classList.remove('panel-active'));
  document.getElementById('tab-'+tab+'-btn').classList.add('tab-active');
  document.getElementById('panel-'+tab).classList.add('panel-active');
  localStorage.setItem('parActiveTab',tab);
}
/* ── SHARED GLOBALS ── */
let autoReloadEnabled   = true;
let reloadTimerInterval = null;
let reloadTimerStarted  = false;
let loadingDotsInterval = null;
let m_fetchTrainingOnDemand = null;
let q_fetchTrainingOnDemand = null;
let m_trainingFetched = false;
let q_trainingFetched = false;
/* ── DOMContentLoaded ── */
document.addEventListener('DOMContentLoaded', () => {
  const savedTab = localStorage.getItem('parActiveTab');
  if (savedTab && savedTab !== 'measure') switchTab(savedTab);
  const themeBtn   = document.getElementById('themeToggle');
  const themeIcon  = document.getElementById('themeIcon');
  const themeLabel = document.getElementById('themeLabel');
  function applyTheme(isLight) {
    document.body.classList.toggle('light', isLight);
    if (themeIcon)  themeIcon.textContent  = isLight ? '🌙' : '☀️';
    if (themeLabel) themeLabel.textContent = isLight ? 'Dark' : 'Light';
    localStorage.setItem('parTheme', isLight ? 'light' : 'dark');
  }
  applyTheme(localStorage.getItem('parTheme') !== 'dark');
  if (themeBtn) themeBtn.addEventListener('click', () => applyTheme(!document.body.classList.contains('light')));
  initAutoReloadCheckbox();
  startLoadingDots();
  /* ── Type toggle states ── */
  [
    { id: 'm-chkLive',     defaultOn: true  },
    { id: 'm-chkTraining', defaultOn: false },
    { id: 'q-chkLive',     defaultOn: true  },
    { id: 'q-chkTraining', defaultOn: false }
  ].forEach(({ id, defaultOn }) => {
    const btn = document.getElementById(id);
    if (!btn) return;
    const isLiveBtn      = id.endsWith('chkLive');
    const saved          = localStorage.getItem(btn.dataset.key);
    const manualKey      = `${btn.dataset.key}_manual`;
    const wasManuallySet = localStorage.getItem(manualKey) === 'true';
    const isStaleLiveOff = isLiveBtn && saved === 'false' && !wasManuallySet;
    const isOn           = (saved === null || isStaleLiveOff) ? defaultOn : saved === 'true';
    btn.classList.toggle(btn.dataset.active, isOn);
    if (saved === null || isStaleLiveOff) localStorage.setItem(btn.dataset.key, String(isOn));
  });
  /* ── Location button states ── */
  [
    { id: 'm-locManila', defaultOn: true },
    { id: 'm-locCebu',   defaultOn: true },
    { id: 'm-locBogota', defaultOn: true },
    { id: 'q-locManila', defaultOn: true },
    { id: 'q-locCebu',   defaultOn: true },
    { id: 'q-locBogota', defaultOn: true }
  ].forEach(({ id, defaultOn }) => {
    const btn = document.getElementById(id);
    if (!btn) return;
    const saved = localStorage.getItem(btn.dataset.key);
    const isOn  = saved === null ? defaultOn : saved === 'true';
    btn.classList.toggle(btn.dataset.active, isOn);
    localStorage.setItem(btn.dataset.key, String(isOn));
  });
  /* FIX: restore search BEFORE applyAllFilters */
  ['m','q'].forEach(p => {
    const key   = 'myInputState_' + p;
    const saved = localStorage.getItem(key);
    if (saved !== null) document.getElementById(p + '-myInput').value = saved;
  });
  applyAllFilters('m');
  applyAllFilters('q');
  /* Search keyup */
  document.getElementById('m-myInput').addEventListener('keyup', function() {
    localStorage.setItem('myInputState_m', this.value);
    applyAllFilters('m');
  });
  document.getElementById('q-myInput').addEventListener('keyup', function() {
    localStorage.setItem('myInputState_q', this.value);
    applyAllFilters('q');
  });
  /* Type toggle buttons */
  document.querySelectorAll('#panel-measure .toggle-btn:not(.loc-btn)').forEach(btn => {
    btn.addEventListener('click', function() {
      const isOn = this.classList.toggle(this.dataset.active);
      localStorage.setItem(this.dataset.key, isOn);
      if (this.id === 'm-chkLive') localStorage.setItem(`${this.dataset.key}_manual`, 'true');
      if (this.id === 'm-chkTraining' && isOn && typeof m_fetchTrainingOnDemand === 'function') m_fetchTrainingOnDemand();
      applyAllFilters('m');
    });
  });
  document.querySelectorAll('#panel-qc .toggle-btn:not(.loc-btn)').forEach(btn => {
    btn.addEventListener('click', function() {
      const isOn = this.classList.toggle(this.dataset.active);
      localStorage.setItem(this.dataset.key, isOn);
      if (this.id === 'q-chkLive') localStorage.setItem(`${this.dataset.key}_manual`, 'true');
      if (this.id === 'q-chkTraining' && isOn && typeof q_fetchTrainingOnDemand === 'function') q_fetchTrainingOnDemand();
      applyAllFilters('q');
    });
  });
  /* Location buttons */
  document.querySelectorAll('#panel-measure .loc-btn').forEach(btn => {
    btn.addEventListener('click', function() {
      const isOn = this.classList.toggle(this.dataset.active);
      localStorage.setItem(this.dataset.key, String(isOn));
      applyAllFilters('m');
    });
  });
  document.querySelectorAll('#panel-qc .loc-btn').forEach(btn => {
    btn.addEventListener('click', function() {
      const isOn = this.classList.toggle(this.dataset.active);
      localStorage.setItem(this.dataset.key, String(isOn));
      applyAllFilters('q');
    });
  });
  initColumnVisibility('measure-table', 'hiddenCols_measure', 'm-columnControls');
  initColumnVisibility('qc-table',      'hiddenCols_qc',      'q-columnControls');
});
/* ── RELOAD TIMER ── */
function stopReloadTimer() {
  if (reloadTimerInterval) { clearInterval(reloadTimerInterval); reloadTimerInterval = null; }
  reloadTimerStarted = false;
}
function startReloadTimer() {
  if (loadingDotsInterval) { clearInterval(loadingDotsInterval); loadingDotsInterval = null; }
  if (!autoReloadEnabled) {
    const t = document.getElementById('reloadTimer');
    if (t) t.textContent = 'Auto Reload: DISABLED';
    return;
  }
  stopReloadTimer();
  reloadTimerStarted = true;
  let reloadSeconds = 300;
  reloadTimerInterval = setInterval(() => {
    if (!autoReloadEnabled) return;
    reloadSeconds--;
    const m = String(Math.floor(reloadSeconds/60)).padStart(2,'0');
    const s = String(reloadSeconds%60).padStart(2,'0');
    const t = document.getElementById('reloadTimer');
    if (t) t.textContent = `Auto Reload in: ${m}:${s}`;
    if (reloadSeconds <= 0) window.location.reload();
  }, 1000);
}
function initAutoReloadCheckbox() {
  const cb = document.getElementById('enableAutoReload');
  if (!cb) return;
  const saved = localStorage.getItem('autoReloadEnabled');
  if (saved !== null) { autoReloadEnabled = saved === 'true'; cb.checked = autoReloadEnabled; }
  cb.addEventListener('change', e => {
    autoReloadEnabled = e.target.checked;
    localStorage.setItem('autoReloadEnabled', autoReloadEnabled);
    if (autoReloadEnabled) startReloadTimer();
    else { stopReloadTimer(); const t=document.getElementById('reloadTimer'); if(t) t.textContent='Auto Reload: DISABLED'; }
  });
}
function startLoadingDots() {
  const el = document.getElementById('reloadTimer');
  if (!el) return;
  let count = 0; el.textContent = 'Loading';
  loadingDotsInterval = setInterval(() => {
    if (!document.body.contains(el)||!el.textContent.startsWith('Loading')) { clearInterval(loadingDotsInterval); loadingDotsInterval=null; return; }
    count=(count+1)%4; el.textContent='Loading'+'.'.repeat(count);
  }, 500);
}
/* ── UTILITIES ── */
function findElementRecursive(el, tag) {
  tag=tag.toUpperCase(); while(el){if(el.nodeName===tag)return el;el=el.parentNode;} return null;
}
function fetchWithRetry(url,options={},retries=10,delay=1000) {
  return fetch(url,options).then(r=>{if(!r.ok)throw new Error('Network error');return r.json();})
    .catch(err=>{ if(retries>0) return new Promise(res=>setTimeout(res,delay)).then(()=>fetchWithRetry(url,options,retries-1,delay)); throw err; });
}
function fetchJsonRetryNoHealthyUpstream(url,options={},retries=3,delay=700){
  return fetch(url,options)
    .then(async r=>{
      const text=await r.text();
      const hasNoHealthyUpstream=/no healthy upstream/i.test(text||'');
      if((!r.ok||hasNoHealthyUpstream)&&retries>0){
        return new Promise(res=>setTimeout(res,delay)).then(()=>fetchJsonRetryNoHealthyUpstream(url,options,retries-1,delay));
      }
      if(!r.ok) throw new Error('Network error');
      try { return JSON.parse(text); }
      catch(err){
        if(hasNoHealthyUpstream&&retries>0){
          return new Promise(res=>setTimeout(res,delay)).then(()=>fetchJsonRetryNoHealthyUpstream(url,options,retries-1,delay));
        }
        throw err;
      }
    });
}
function escapeHtml(value=''){
  return String(value)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}
function fetchMeasureReworkDetails(reportId,locationName){
  if(!/bogota/i.test(locationName||'')) return Promise.resolve('');
  const jobUrl = `https://api.cmh.platform-prod.evinternal.net/inform-measures/hipster/v3/job?requester_id=${encodeURIComponent(reportId)}&source=gov`;
  return fetchJsonRetryNoHealthyUpstream(jobUrl,{},3,700)
    .then(jobData=>{
      const jobId=jobData?.ID;
      if(!jobId) return '';
      const notesUrl = `https://api.cmh.platform-prod.evinternal.net/inform-measures/hipster/v3/note?job_id=${encodeURIComponent(jobId)}`;
      return fetchWithRetry(notesUrl,{},2,500)
        .then(noteData=>{
          const notes=Array.isArray(noteData?.Notes)?noteData.Notes:[];
          const match=notes.find(n=>{
            const value=String(n?.Value||'');
            return value && !/job rejected/i.test(value);
          });
          return match?.Value||'';
        });
    })
    .catch(()=>'');
}
/* ── SITE TAG HELPER ── */
function extractSiteTag(entries) {
  try {
    if (!Array.isArray(entries) || entries.length === 0) return '';
    const lastCheckin = entries
      .filter(e => /Measured-CheckIn/i.test(e.description ?? ''))
      .sort((a,b) => new Date(b.stateTime) - new Date(a.stateTime))[0];
    if (!lastCheckin) return '';
    const match = lastCheckin.description
      .match(/Measured-CheckIn\(.*?-([A-Z]{2,4})\)/i);
    const site = match?.[1]?.trim()?.toUpperCase();
    if (!site) return '';
    return `<span class="bog-tag bog-tag-${site.toLowerCase()}">${site}</span>`;
  } catch(e) {
    return '';
  }
}
/* ── SORTABLE TABLE ── */
document.addEventListener('click', e => {
  try {
    const altKey=e.shiftKey||e.altKey;
    const th=findElementRecursive(e.target,'TH'); if(!th) return;
    const tr=th.parentNode,thead=tr?.parentNode,table=thead?.parentNode;
    if(!thead||thead.nodeName!=='THEAD') return;
    if(!table||!table.classList.contains('sortable')) return;
    if(th.classList.contains('no-sort')) return;
    function getValue(cell){const v=altKey?cell.dataset.sortAlt:cell.dataset.sort;return v??cell.textContent.trim();}
    let colIndex; const cells=tr.cells;
    for(let i=0;i<cells.length;i++){if(cells[i]===th)colIndex=Number(th.dataset.sortCol)||i;else cells[i].setAttribute('aria-sort','none');}
    let direction='descending'; const current=th.getAttribute('aria-sort');
    if(current==='descending'||(table.classList.contains('asc')&&current!=='ascending')) direction='ascending';
    th.setAttribute('aria-sort',direction); const reverse=direction==='ascending';
    const nullLast=table.classList.contains('n-last');
    const compare=(a,b,index)=>{
      const x=getValue(b.cells[index]),y=getValue(a.cells[index]);
      if(nullLast){if(x===''&&y!=='')return -1;if(y===''&&x!=='')return 1;}
      const num=+x-+y; const result=Number.isNaN(num)?String(x).localeCompare(String(y)):num;
      return reverse?-result:result;
    };
    for(let i=0;i<table.tBodies.length;i++){
      const oldBody=table.tBodies[i]; const rows=Array.from(oldBody.rows); const tbr=Number(th.dataset.sortTbr);
      rows.sort((a,b)=>{
        const aT=a.dataset.type==='training'?1:0,bT=b.dataset.type==='training'?1:0;
        if(aT!==bT)return aT-bT; const r=compare(a,b,colIndex);
        return r===0&&!Number.isNaN(tbr)?compare(a,b,tbr):r;
      });
      const newBody=oldBody.cloneNode(); newBody.append(...rows); table.replaceChild(newBody,oldBody);
    }
  } catch(err){console.error('sortable click handler error:',err);}
});
function sortTableByColumn(tableId,colIndex,ascending=true){
  const table=document.getElementById(tableId); if(!table)return;
  const tbody=table.tBodies[0]; if(!tbody)return;
  const rows=Array.from(tbody.rows);
  rows.sort((a,b)=>{
    const aT=a.dataset.type==='training'?1:0,bT=b.dataset.type==='training'?1:0;
    if(aT!==bT)return aT-bT;
    const x=parseFloat(a.cells[colIndex]?.dataset.seconds||'0'),y=parseFloat(b.cells[colIndex]?.dataset.seconds||'0');
    return ascending?x-y:y-x;
  });
  tbody.innerHTML=''; rows.forEach(r=>tbody.appendChild(r));
}
/* ── COLUMN VISIBILITY ── */
const colVisState={};
function initColumnVisibility(tableId,storageKey,controlsId){
  if(!colVisState[tableId]) colVisState[tableId]={initialized:false,key:storageKey,controlsId};
  if(colVisState[tableId].initialized){reapplyColumnVisibility(tableId);return;}
  const table=document.getElementById(tableId); if(!table)return;
  const thead=table.tHead; if(!thead)return;
  const headerRow=thead.rows[0];
  const controls=document.getElementById(controlsId); if(!controls)return;
  controls.innerHTML='';
  const hiddenCols=getHiddenColumns(tableId);
  [...headerRow.cells].forEach((th,index)=>{
    const colName=th.textContent.replace(/[↑↓]/g,'').replace(/\s*\(\d+\)/,'').trim() || `Col ${index+1}`;
    const isHidden=hiddenCols.includes(index);
    const chip=document.createElement('button');
    chip.className='col-chip'+(isHidden?'':' col-on');
    chip.textContent=colName;
    chip.title=isHidden?'Show column':'Hide column';
    chip.addEventListener('click',()=>{
      const columnIsCurrentlyVisible=chip.classList.contains('col-on');
      chip.classList.toggle('col-on',!columnIsCurrentlyVisible);
      if(columnIsCurrentlyVisible){
        chip.title='Show column';
        toggleColumn(tableId,index,true);
      } else {
        chip.title='Hide column';
        toggleColumn(tableId,index,false);
      }
    });
    controls.appendChild(chip);
    if(isHidden)applyColumnHidden(tableId,index,true);
  });
  colVisState[tableId].initialized=true;
}
function reapplyColumnVisibility(tableId){getHiddenColumns(tableId).forEach(ci=>applyColumnHidden(tableId,ci,true));}
function toggleColumn(tableId,colIndex,hide){
  applyColumnHidden(tableId,colIndex,hide);
  let h=getHiddenColumns(tableId);
  if(hide&&!h.includes(colIndex))h.push(colIndex);
  if(!hide)h=h.filter(i=>i!==colIndex);
  localStorage.setItem(colVisState[tableId].key,JSON.stringify(h));
}
function applyColumnHidden(tableId,colIndex,hide){
  const table=document.getElementById(tableId); if(!table)return;
  const method=hide?'add':'remove';
  table.tHead?.rows[0]?.cells[colIndex]?.classList[method]('hidden-column');
  [...table.tBodies].forEach(tb=>[...tb.rows].forEach(row=>row.cells[colIndex]?.classList[method]('hidden-column')));
}
function getHiddenColumns(tableId){
  try{return JSON.parse(localStorage.getItem(colVisState[tableId]?.key))||[];}catch{return [];}
}
/* ── DYNAMIC TIMERS ── */
const dynamicTimersStarted={};
function startDynamicTimers(dataId){
  if(dynamicTimersStarted[dataId])return; dynamicTimersStarted[dataId]=true;
  // Single tick drives both the elapsed and due countdown columns, instead of
  // two independent setIntervals each re-querying the DOM every second.
  setInterval(()=>{
    document.querySelectorAll(`#${dataId} td.elapsed`).forEach(td=>{
      let sec=parseInt(td.dataset.seconds||'0',10); sec++; td.dataset.seconds=sec;
      const h=String(Math.floor(sec/3600)).padStart(2,'0');
      const m=String(Math.floor((sec%3600)/60)).padStart(2,'0');
      const s=String(sec%60).padStart(2,'0');
      const isTraining=td.closest('tr')?.dataset.type==='training';
      if(sec>=10800&&!isTraining)td.style.color='red';
      else if(sec>=7200)td.style.color='orangered';
      else if(sec>=3600)td.style.color='DarkOrange';
      else td.style.color='';
      td.textContent=`${h}:${m}:${s}`;
    });
    document.querySelectorAll(`#${dataId} td.due`).forEach(td=>{
      let sec=parseInt(td.dataset.seconds||'0',10); sec--; td.dataset.seconds=sec;
      const abs=Math.abs(sec);
      const h=abs>=3600?String(Math.floor(abs/3600)).padStart(2,'0'):'00';
      const m=String(Math.floor((abs%3600)/60)).padStart(2,'0');
      const s=String(abs%60).padStart(2,'0');
      if(sec<0){td.style.color='red';td.textContent=`-${h}:${m}:${s}`;}
      else if(sec<3600){td.style.color='red';td.textContent=`${h}:${m}:${s}`;}
      else if(sec<7200){td.style.color='orangered';td.textContent=`${h}:${m}:${s}`;}
      else if(sec<10800){td.style.color='DarkOrange';td.textContent=`${h}:${m}:${s}`;}
      else{td.style.color='';td.textContent=`${h}:${m}:${s}`;}
    });
  },1000);
}
/* ── APPLY ALL FILTERS ── */
function applyAllFilters(prefix){
  const searchValue=(document.getElementById(`${prefix}-myInput`)?.value||'').trim().toLowerCase();
  const showLive    =document.getElementById(`${prefix}-chkLive`)?.classList.contains('active-live')??false;
  const showTraining=document.getElementById(`${prefix}-chkTraining`)?.classList.contains('active-training')??false;
  const panelId=prefix==='m'?'panel-measure':'panel-qc';
  const activeLocs=[];
  document.querySelectorAll(`#${panelId} .loc-btn`).forEach(btn=>{
    if(btn.classList.contains('active-loc')) activeLocs.push(btn.dataset.location.toLowerCase());
  });
  const anyLocActive=activeLocs.length>0;
  const locCellIndex=prefix==='m'?8:7;
  let visibleLive=0,visibleLate=0,visibleTotal=0;
  const visibleBeingMeasuredUsernames = new Map();
  document.querySelectorAll(`#${prefix}-data tr`).forEach(row=>{
    const rowType=row.dataset.type;
    const isLive =rowType==='live';
    const isTrain=rowType==='training';
    const matchType=(!showLive&&!showTraining)
      ?false
      :((isLive&&showLive)||(isTrain&&showTraining));
    const text=row.textContent.toLowerCase();
    const matchSearch=searchValue===''?true:text.includes(searchValue);
    let matchLoc=false;
    if(anyLocActive){
      const locCell=row.cells[locCellIndex];
      const locText=locCell?locCell.textContent.trim().toLowerCase():'';
      matchLoc=activeLocs.some(loc=>locText===loc);
    }
    const show=matchType&&matchSearch&&matchLoc;
    row.style.display=show?'':'none';
    if(show){
      visibleTotal++;
      if(isLive)visibleLive++;
      const dueCell=row.cells[row.cells.length-1];
      if(dueCell&&dueCell.style.color==='red')visibleLate++;
      if(prefix==='m' && !isTrain && row.cells.length>=4){
        const stateText=row.cells[3].textContent.trim();
        if(stateText.includes('Being Measured')){
          const username=row.cells[2].textContent.trim();
          if(username) visibleBeingMeasuredUsernames.set(username,(visibleBeingMeasuredUsernames.get(username)||0)+1);
        }
      }
    }
  });
  const fc=document.getElementById(`${prefix}-fileCount`);
  if(fc)fc.innerHTML=`Reports (${visibleTotal})`;
  const pl=document.getElementById(`${prefix}-statLive`);
  const pt=document.getElementById(`${prefix}-statLate`);
  const pn=document.getElementById(`${prefix}-statTotal`);
  if(pl)pl.textContent=`Live: ${visibleLive}`;
  if(pt)pt.textContent=`Due: ${visibleLate}`;
  if(pn)pn.textContent=`Total: ${visibleTotal}`;
  if(prefix==='m') renderDuplicateUsernameAlerts(visibleBeingMeasuredUsernames);
}
/* ── buildTimeCells ── */
function buildTimeCells(renderTime,stateTime,dueRaw,isTraining){
  const elapsedSec=isNaN(stateTime.getTime())
    ?NaN
    :Math.max(0,Math.round((renderTime.getTime()-stateTime.getTime())/1000));
  const eh=isNaN(elapsedSec)?'00':String(Math.floor(elapsedSec/3600)).padStart(2,'0');
  const em=isNaN(elapsedSec)?'00':String(Math.floor((elapsedSec%3600)/60)).padStart(2,'0');
  const es=isNaN(elapsedSec)?'00':String(elapsedSec%60).padStart(2,'0');
  const elapsedAttr=isNaN(elapsedSec)?'':elapsedSec;
  let elapsedStyle='';
  if(!isNaN(elapsedSec)&&elapsedSec>=10800&&!isTraining) elapsedStyle='style="color:red;"';
  const elapsedCell=`<td class="elapsed" data-seconds="${elapsedAttr}" ${elapsedStyle}>${eh}:${em}:${es}</td>`;
  const dueMs=isNaN(dueRaw.getTime())?NaN:dueRaw.getTime()-renderTime.getTime();
  const dueSec=isNaN(dueMs)?NaN:Math.floor(dueMs/1000);
  const abs2=isNaN(dueSec)?0:Math.abs(dueSec);
  const dh=String(Math.floor(abs2/3600)).padStart(2,'0');
  const dm=String(Math.floor((abs2%3600)/60)).padStart(2,'0');
  const ds_=String(abs2%60).padStart(2,'0');
  let dd=`${dh}:${dm}:${ds_}`;
  if(isNaN(dueSec)){dd='00:00:00';}
  else if(dueSec<0){dd=`-${dd}`;}
  const dueAttr=isNaN(dueSec)?'':dueSec;
  let dc='';
  if(!isNaN(dueSec)){
    if(dueSec<0)dc='red';
    else if(dueSec<3600)dc='red';
    else if(dueSec<7200)dc='orangered';
    else if(dueSec<10800)dc='DarkOrange';
  }
  const dueCell=`<td class="due" data-seconds="${dueAttr}" style="color:${dc};">${dd}</td>`;
  return{elapsedCell,dueCell};
}
/* ============================================================================
   MEASURE: MAIN DATA FETCH
   ============================================================================ */
let m_pendingFetches=0, m_fileCount=0;
(function measureMain(){
  fetch('https://api.cmh.platform-prod2.evinternal.net/operations-center/api/Team')
    .then(r=>r.ok?r.json():Promise.reject()).then(d=>({dictTeam:new Map(d.map(t=>[t.teamId,t.name]))}))
    .then(({dictTeam})=>fetch('https://api.cmh.platform-prod2.evinternal.net/operations-center/api/Location')
      .then(r=>r.ok?r.json():Promise.reject()).then(d=>({dictTeam,dictLocation:new Map(d.map(l=>[l.id,l.description]))})))
    .then(({dictTeam,dictLocation})=>{
    const apiBMUrl       ='https://api.cmh.platform-prod.evinternal.net/operations-center/api/TaskTrafficView/?type=16&value=beingmeasured&type=30&value=test&type=30&value=training&type=26&value=true&type=18&value=HQ';
    const apiRTMUrl      ='https://api.cmh.platform-prod.evinternal.net/operations-center/api/TaskTrafficView/?type=16&value=readytomeasure&type=30&value=test&type=30&value=training&type=26&value=true&type=18&value=HQ&type=15&value=null';
    const apiTrainingRTM ='https://api.cmh.platform-prod.evinternal.net/operations-center/api/TaskTrafficView/?type=16&value=readytomeasure&type=29&value=test&type=29&value=training&type=26&value=true&type=18&value=HQ&type=15&value=null&';
    const apiTrainingBM  ='https://api.cmh.platform-prod.evinternal.net/operations-center/api/TaskTrafficView/?type=16&value=beingmeasured&type=29&value=test&type=29&value=training&type=26&value=true&type=18&value=HQ&';
    function processList(apiData=[],isRTM=false,isTraining=false){
      if(!Array.isArray(apiData))return;
      apiData.forEach(item=>{
        m_pendingFetches++; m_fileCount++;
        fetch(`https://api.cmh.platform-prod2.evinternal.net/operations-center/api/Report/${item.reportID}`)
          .then(r=>r.ok?r.json():Promise.reject())
          .then(report=>{
            const pmText=report.pmReportID?' [PM]':'';
            return fetch(`https://api.cmh.platform-prod2.evinternal.net/operations-center/api/TaskState/id/${item.taskStateID}`)
              .then(r=>r.ok?r.json():Promise.reject())
              .then(task=>fetch(`https://api.cmh.platform-prod2.evinternal.net/operations-center/api/TaskState/${task.taskID}`)
                .then(r=>r.ok?r.json():Promise.reject())
                .then(task2=>{
                  const entries=Array.isArray(task2)?task2:[];
                  const firstRTM=entries.filter(e=>e.description==='ReadyToMeasure-StateTransition').sort((a,b)=>new Date(a.stateTime)-new Date(b.stateTime))[0];
                  const sorted=entries.filter(e=>e.description&&e.description.includes('Rejected')&&firstRTM&&new Date(e.stateTime)>new Date(firstRTM.stateTime)).sort((a,b)=>new Date(a.stateTime)-new Date(b.stateTime));
                  const rejectedCounts=new Map();
                  sorted.forEach(e=>{const match=e.description.match(/Rejected\(([^)]+)\)/);if(match){const t=match[1];rejectedCounts.set(t,(rejectedCounts.get(t)||0)+1);}});
                  return{report,pmText,task,rejectedCounts,entries};
                }));
          })
          .then(({report,pmText,task,rejectedCounts,entries})=>{
            const userID=isRTM?task.preferredUserID:task.userID;
            return fetch(`https://api.cmh.platform-prod2.evinternal.net/operations-center/api/User/id?ids=${userID}`)
              .then(r=>r.ok?r.json():Promise.reject()).then(user=>({report,pmText,task,rejectedCounts,entries,user}));
          })
          .then(({report,pmText,task,rejectedCounts,entries,user})=>
            fetch(`https://api.cmh.platform-prod2.evinternal.net/operations-center/api/Report/${item.reportID}/measurement-items`)
              .then(r=>r.ok?r.json():Promise.reject()).then(mItems=>({report,pmText,task,rejectedCounts,entries,user,mItems})))
          .then(({report,pmText,task,rejectedCounts,entries,user,mItems})=>{
            const locationName=dictLocation.get(user[0]?.locationId)??'';
            const hasReworkHistory=[...rejectedCounts.keys()].some(type=>/rework/i.test(type));
            if(!hasReworkHistory){
              return{report,pmText,task,rejectedCounts,entries,user,mItems,reworkDetails:'',locationName};
            }
            return fetchMeasureReworkDetails(item.reportID,locationName)
              .then(reworkDetails=>({report,pmText,task,rejectedCounts,entries,user,mItems,reworkDetails,locationName}));
          })
          .then(({report,pmText,task,rejectedCounts,entries,user,mItems,reworkDetails,locationName})=>{
            const mText=(mItems.measurementItems||[]).map(m=>'*'+(m.name||'').replace(/\s+/g,'')).join('  ');
            const rejectedSuffix=[...rejectedCounts.entries()].map(([type,count])=>{
              let color;
              if(count>=3)      color='red';
              else if(count===2) color='DarkOrange';
              else               color=isRTM?'var(--text-primary)':'var(--text-secondary)';
              return `<span style="color:${color};">${type} ${count}x</span>`;
            }).join('<br>');
            const reworkHtml=escapeHtml(reworkDetails).replace(/\n/g,'<br>');
            const isHipsterErrorRow =
              /bellevue/i.test(locationName) ||
              /hipster/i.test(locationName)  ||
              /error/i.test(locationName);
            const siteTag = isHipsterErrorRow
              ? extractSiteTag(entries)
              : '';
            let row=`<tr data-type="${isTraining?'training':'live'}">
<td><span class="${isTraining?'badge-training':'badge-live'}">${isTraining?'Training':'Live'}</span></td>
<td>${item.reportID}</td>
<td>${user[0]?.userName??''}${siteTag}</td>
<td style="color:${isRTM?'var(--text-primary)':'var(--text-secondary)'};">${isRTM?'Ready To Measure':'Being Measured'}</td>
<td style="color:${isRTM?'var(--text-primary)':'var(--text-secondary)'};">${rejectedSuffix}</td>
<td style="color:${isRTM?'var(--text-primary)':'var(--text-secondary)'};">${reworkHtml}</td>
<td>${user[0]?.techUsername??''}</td>
<td>${dictTeam.get(user[0]?.teamId)??''}</td>
<td>${locationName}</td>
<td>${mText}${pmText}</td>`;
            const renderTime=new Date();
            const stateTime=parseServerUtc(task.stateTime);
            const dueRaw=parseServerUtc(item.dueDate);
            const{elapsedCell,dueCell}=buildTimeCells(renderTime,stateTime,dueRaw,isTraining);
            row+=elapsedCell+dueCell+'</tr>';
            const tbody=document.getElementById('m-data');
            if(tbody){const tmp=document.createElement('tbody');tmp.innerHTML=row;const nr=tmp.firstElementChild;if(nr)tbody.appendChild(nr);}
            document.getElementById('m-fileCount').innerHTML=`Reports (${m_fileCount})`;
            applyAllFilters('m');
            initColumnVisibility('measure-table','hiddenCols_measure','m-columnControls');
            m_pendingFetches--;
            if(m_pendingFetches===0){sortTableByColumn('measure-table',11,true);colorDuplicateMeasureUsernames();startDynamicTimers('m-data');if(!reloadTimerStarted)startReloadTimer();}
          })
          .catch(err=>{
            console.error('measure report chain error:',err);
            m_pendingFetches=Math.max(0,m_pendingFetches-1);
            if(m_pendingFetches===0){sortTableByColumn('measure-table',11,true);colorDuplicateMeasureUsernames();startDynamicTimers('m-data');if(!reloadTimerStarted)startReloadTimer();}
          });
      });
    }
    const loadMeasureTrainingData=()=>{
      if(m_trainingFetched)return;
      m_trainingFetched=true;
      fetch(apiTrainingBM).then(r=>r.ok?r.json():Promise.reject()).then(d=>processList(d,false,true)).catch(e=>console.error('apiTrainingBM:',e));
      fetch(apiTrainingRTM).then(r=>r.ok?r.json():Promise.reject()).then(d=>processList(d,true,true)).catch(e=>console.error('apiTrainingRTM:',e));
    };
    m_fetchTrainingOnDemand=loadMeasureTrainingData;
    Promise.all([
      fetch(apiBMUrl).then(r=>r.ok?r.json():Promise.reject()).then(d=>processList(d,false,false)).catch(e=>console.error('apiBMUrl:',e)),
      fetch(apiRTMUrl).then(r=>r.ok?r.json():Promise.reject()).then(d=>processList(d,true,false)).catch(e=>console.error('apiRTMUrl:',e))
    ]).then(()=>{
      if(document.getElementById('m-chkTraining')?.classList.contains('active-training')) loadMeasureTrainingData();
    });
  }).catch(err=>console.error('measure main chain error:',err));
})();
function colorDuplicateMeasureUsernames(){
  const table=document.getElementById('measure-table'); if(!table)return;
  const tbody=table.tBodies[0]; if(!tbody)return;
  const rows=Array.from(tbody.rows);
  const uC=new Map(),tC=new Map();
  rows.forEach(row=>{
    const cells=row.cells;
    if(cells.length>=7&&cells[3].textContent.trim().includes('Being Measured')&&row.dataset.type!=='training'){
      const u=cells[2].textContent.trim(),t=cells[6].textContent.trim();
      if(u)uC.set(u,(uC.get(u)||0)+1); if(t)tC.set(t,(tC.get(t)||0)+1);
    }
  });
  rows.forEach(row=>{
    const cells=row.cells;
    if(cells.length>=7&&cells[3].textContent.trim().includes('Being Measured')&&row.dataset.type!=='training'){
      const u=cells[2].textContent.trim(),t=cells[6].textContent.trim();
      if(u&&uC.get(u)>1)cells[2].style.color='red';
      if(t&&tC.get(t)>1)cells[6].style.color='red';
    }
  });
}
/* ── NOTIFICATION — duplicate username in "Being Measured" ── */
function renderDuplicateUsernameAlerts(usernameCounts){
  const container=document.getElementById('dupAlertContainer');
  if(!container) return;
  const duplicates=[...usernameCounts.entries()].filter(([,count])=>count>1);
  if(duplicates.length===0){ container.innerHTML=''; return; }
  container.innerHTML = duplicates.map(([username,count])=>`
    <div class="dup-alert">
      <span class="dup-alert-icon">⚠</span>
      <span class="dup-alert-text"><strong>${escapeHtml(username)}</strong> has ${count} files marked "Being Measured" at the same time</span>
      <button class="dup-alert-close" title="Dismiss" onclick="this.closest('.dup-alert').remove()">×</button>
    </div>
  `).join('');
}
/* ============================================================================
   QC: MAIN DATA FETCH
   ============================================================================ */
let q_pendingFetches=0, q_fileCount=0;
(function qcMain(){
  fetch('https://api.cmh.platform-prod2.evinternal.net/operations-center/api/Team')
    .then(r=>r.ok?r.json():Promise.reject()).then(d=>({dictTeam:new Map(d.map(t=>[t.teamId,t.name]))}))
    .then(({dictTeam})=>fetch('https://api.cmh.platform-prod2.evinternal.net/operations-center/api/Location')
      .then(r=>r.ok?r.json():Promise.reject()).then(d=>({dictTeam,dictLocation:new Map(d.map(l=>[l.id,l.description]))})))
    .then(({dictTeam,dictLocation})=>{
    const apiBQced        ='https://api.cmh.platform-prod.evinternal.net/operations-center/api/TaskTrafficView/?type=25&value=01/01/26&type=16&value=beingqced&type=30&value=test&type=30&value=training&type=26&value=true&type=18&value=HQ&';
    const apiRFQC         ='https://api.cmh.platform-prod.evinternal.net/operations-center/api/TaskTrafficView/?type=25&value=01/01/26&type=16&value=readyforqc&type=30&value=test&type=30&value=training&type=26&value=true&type=18&value=HQ&';
    const apiTrainingRFQC ='https://api.cmh.platform-prod.evinternal.net/operations-center/api/TaskTrafficView/?type=25&value=01/01/26&type=16&value=readyforqc&type=29&value=test&type=29&value=training&type=26&value=true&type=18&value=HQ&';
    const apiTrainingBQced='https://api.cmh.platform-prod.evinternal.net/operations-center/api/TaskTrafficView/?type=25&value=01/01/26&type=16&value=beingqced&type=29&value=test&type=29&value=training&type=26&value=true&type=18&value=HQ&';
    function processList(apiData=[],isRFQC=false,isTraining=false){
      if(!Array.isArray(apiData))return;
      apiData.forEach(item=>{
        q_pendingFetches++; q_fileCount++;
        let lastMeasured=null;
        fetch(`https://api.cmh.platform-prod2.evinternal.net/operations-center/api/Report/${item.reportID}`)
          .then(r=>r.ok?r.json():Promise.reject())
          .then(report=>{
            const pmText=report.pmReportID?' [PM]':'';
            return fetch(`https://api.cmh.platform-prod2.evinternal.net/operations-center/api/TaskState/id/${item.taskStateID}`)
              .then(r=>r.ok?r.json():Promise.reject())
              .then(task=>fetch(`https://api.cmh.platform-prod2.evinternal.net/operations-center/api/TaskState/report/${item.reportID}`)
                .then(r=>r.ok?r.json():Promise.reject())
                .then(taskReport=>{
                  if(Array.isArray(taskReport.taskStates)){
                    const measured=taskReport.taskStates.filter(ts=>ts.description&&ts.description.includes('Measured-CheckIn'));
                    if(measured.length>0)lastMeasured=measured[measured.length-1];
                  }
                  return fetch(`https://api.cmh.platform-prod2.evinternal.net/operations-center/api/TaskState/${task.taskID}`)
                    .then(r=>r.ok?r.json():Promise.reject())
                    .then(task2=>({report,pmText,task,isRework:JSON.stringify(task2).includes('Rework'),task2Entries:Array.isArray(task2)?task2:[]}));
                }));
          })
          .then(({report,pmText,task,isRework,task2Entries})=>{
            const userID=isRFQC?task.preferredUserID:task.userID;
            const userPromise=userID
              ?fetch(`https://api.cmh.platform-prod2.evinternal.net/operations-center/api/User/id?ids=${userID}`).then(r=>r.ok?r.json():Promise.reject())
              :Promise.resolve([{userName:null,techUsername:null,teamId:null,locationId:null}]);
            return userPromise.then(user=>({report,pmText,task,isRework,task2Entries,user}));
          })
          .then(({report,pmText,task,isRework,task2Entries,user})=>
            fetch(`https://api.cmh.platform-prod2.evinternal.net/operations-center/api/Report/${item.reportID}/measurement-items`)
              .then(r=>r.ok?r.json():Promise.reject()).then(mItems=>({report,pmText,task,isRework,task2Entries,user,mItems})))
          .then(({report,pmText,task,isRework,task2Entries,user,mItems})=>{
            const mText=(mItems.measurementItems||[]).map(m=>'*'+(m.name||'').replace(/\s+/g,'')).join('  ');
            const typeBadge=isTraining?'<span class="badge-training">Training</span>':'<span class="badge-live">Live</span>';
            const stateLabel=isRFQC
              ?`Ready For QC${isRework?' (Rework)':''}`
              :`Being Qced${isRework?' (Rework)':''}`;
            const qcLocationName=dictLocation.get(user[0]?.locationId)??'';
            const isHipsterErrorRowQC =
              /bellevue/i.test(qcLocationName) ||
              /hipster/i.test(qcLocationName)  ||
              /error/i.test(qcLocationName);
            const siteTagQC = isHipsterErrorRowQC
              ? extractSiteTag(task2Entries)
              : '';
            let row=`<tr data-type="${isTraining?'training':'live'}">
<td>${typeBadge}</td>
<td>${item.reportID}</td>
<td style="color:${isRFQC?'var(--text-primary)':'var(--text-secondary)'};">${stateLabel}</td>
<td>${lastMeasured&&lastMeasured.description?(lastMeasured.description.match(/\(([^)]+)\)/)||[])[1]||'':''}</td>
<td>${user[0]?.userName??''}${siteTagQC}</td>
<td>${user[0]?.techUsername??''}</td>
<td>${dictTeam.get(user[0]?.teamId)??''}</td>
<td>${dictLocation.get(user[0]?.locationId)??''}</td>
<td>${mText}${pmText}</td>`;
            const renderTime=new Date();
            const stateTime=parseServerUtc(task.stateTime);
            const dueRaw=parseServerUtc(item.dueDate);
            const{elapsedCell,dueCell}=buildTimeCells(renderTime,stateTime,dueRaw,isTraining);
            row+=elapsedCell+dueCell+'</tr>';
            const tbody=document.getElementById('q-data');
            if(tbody){const tmp=document.createElement('tbody');tmp.innerHTML=row;const nr=tmp.firstElementChild;if(nr)tbody.appendChild(nr);}
            document.getElementById('q-fileCount').innerHTML=`Reports (${q_fileCount})`;
            applyAllFilters('q');
            initColumnVisibility('qc-table','hiddenCols_qc','q-columnControls');
            q_pendingFetches--;
            if(q_pendingFetches===0){sortTableByColumn('qc-table',10,true);startDynamicTimers('q-data');if(!reloadTimerStarted)startReloadTimer();}
          })
          .catch(err=>{
            console.error('qc report chain error:',err);
            q_pendingFetches=Math.max(0,q_pendingFetches-1);
            if(q_pendingFetches===0){sortTableByColumn('qc-table',10,true);startDynamicTimers('q-data');if(!reloadTimerStarted)startReloadTimer();}
          });
      });
    }
    const loadQcTrainingData=()=>{
      if(q_trainingFetched)return;
      q_trainingFetched=true;
      fetch(apiTrainingBQced).then(r=>r.ok?r.json():Promise.reject()).then(d=>processList(d,false,true)).catch(e=>console.error('apiTrainingBQced:',e));
      fetch(apiTrainingRFQC) .then(r=>r.ok?r.json():Promise.reject()).then(d=>processList(d,true,true)).catch(e=>console.error('apiTrainingRFQC:',e));
    };
    q_fetchTrainingOnDemand=loadQcTrainingData;
    Promise.all([
      fetch(apiBQced).then(r=>r.ok?r.json():Promise.reject()).then(d=>processList(d,false,false)).catch(e=>console.error('apiBQced:',e)),
      fetch(apiRFQC) .then(r=>r.ok?r.json():Promise.reject()).then(d=>processList(d,true,false)).catch(e=>console.error('apiRFQC:',e))
    ]).then(()=>{
      if(document.getElementById('q-chkTraining')?.classList.contains('active-training')) loadQcTrainingData();
    });
  }).catch(err=>console.error('qc main chain error:',err));
})();
/* ============================================================================
   TRIPLE CLOCK — PH, Bogotá & PST/PDT
   ============================================================================ */
(function initTripleClock() {
  const CLOCKS = [
    { timeId: 'clock-time-ph',  iconId: 'clock-icon-ph',  itemId: 'clock-ph',  tz: 'Asia/Manila',        label: 'PH' },
    { timeId: 'clock-time-pst', iconId: 'clock-icon-pst', itemId: 'clock-pst', tz: 'America/Los_Angeles', label: 'US', labelId: 'clock-label-pst', dynamicLabel: true },
    { timeId: 'clock-time-bog', iconId: 'clock-icon-bog', itemId: 'clock-bog', tz: 'America/Bogota',     label: 'BOG' }
  ];
  function getDayNightIcon(hour) {
    if (hour >= 6  && hour < 12) return { icon: '☀️',  isNight: false };
    if (hour >= 12 && hour < 17) return { icon: '🌤️', isNight: false };
    if (hour >= 17 && hour < 20) return { icon: '🌅', isNight: false };
    return                               { icon: '🌙',  isNight: true  };
  }
  function getTimeInZone(tz) {
    const now       = new Date();
    const formatter = new Intl.DateTimeFormat('en-US', {
      timeZone: tz, hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false
    });
    const parts = formatter.formatToParts(now);
    const get   = type => parts.find(p => p.type === type)?.value ?? '00';
    const h = get('hour') === '24' ? '00' : get('hour');
    const m = get('minute');
    const s = get('second');
    return { display: `${h}:${m}:${s}`, hour: parseInt(h, 10) };
  }
  function getPacificLabel() {
    try {
      const name = new Intl.DateTimeFormat('en-US', {
        timeZone: 'America/Los_Angeles',
        timeZoneName: 'short'
      }).formatToParts(new Date())
        .find(p => p.type === 'timeZoneName')?.value || 'PST';
      return /PDT/i.test(name) ? 'PDT' : 'PST';
    } catch (e) {
      return 'PST';
    }
  }
  function tick() {
    CLOCKS.forEach(({ timeId, iconId, itemId, tz, labelId, dynamicLabel }) => {
      const timeEl = document.getElementById(timeId);
      const iconEl = document.getElementById(iconId);
      const itemEl = document.getElementById(itemId);
      if (!timeEl || !iconEl || !itemEl) return;
      const { display, hour } = getTimeInZone(tz);
      const { icon, isNight } = getDayNightIcon(hour);
      timeEl.textContent = display;
      iconEl.textContent = icon;
      itemEl.classList.toggle('is-night',  isNight);
      itemEl.classList.toggle('is-day',   !isNight);
      iconEl.classList.toggle('is-night',  isNight);
      if (dynamicLabel && labelId) {
        const labelEl = document.getElementById(labelId);
        if (labelEl) labelEl.textContent = getPacificLabel();
      }
    });
  }
  function init() { tick(); setInterval(tick, 1000); }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
/* ============================================================================
   QUEUE POPOVER — multi-instance
   ============================================================================ */
(function initQueuePopovers() {
  const QUEUE_SECTIONS = [
    {
      title: 'IP QUEUE',
      items: [
        { label: 'DROP', url: 'https://api.cmh.platform-prod.evinternal.net/operations-center/api/TaskTrafficView/?type=25&value=01/01/26&type=16&value=ReadyForDropping&type=26&value=true&type=30&value=Test&type=30&value=Pilot&type=18&value=HQ&type=30&value=Training' }
      ]
    },
    {
      title: 'MT TEAMLEAD',
      items: [
        { label: 'RTM',     url: 'https://api.cmh.platform-prod.evinternal.net/operations-center/api/TaskTrafficView/?type=25&value=01/01/26&type=16&value=readytomeasure&type=30&value=test&type=30&value=training&type=26&value=true&type=18&value=HQ&' },
        { label: 'Hipster', url: 'https://api.cmh.platform-prod.evinternal.net/operations-center/api/TaskTrafficView/?type=25&value=01/01/26&type=26&value=true&type=33&value=3DRoofHipster&type=18&value=hq&type=30&value=test&type=16&value=readytomeasure&type=30&value=training&' }
      ]
    },
    {
      title: 'QC TEAMLEAD',
      items: [
        { label: 'RFQC',    url: 'https://api.cmh.platform-prod.evinternal.net/operations-center/api/TaskTrafficView/?type=25&value=01/01/26&type=16&value=readyforqc&type=30&value=test&type=30&value=training&type=26&value=true&type=18&value=HQ&' },
        { label: 'Hipster', url: 'https://api.cmh.platform-prod.evinternal.net/operations-center/api/TaskTrafficView/?type=25&value=01/01/26&type=18&value=hq&type=16&value=readyforqc&type=26&value=true&type=33&value=3DRoofHipster&type=30&value=test&type=30&value=training&' }
      ]
    }
  ];
  let sharedResults = null;
  let isFetching    = false;
  const instances   = [];
  async function fetchCount(url) {
    try {
      const res = await fetch(url);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      return Array.isArray(data) ? data.length : 0;
    } catch (err) {
      return 'ERR';
    }
  }
  function buildResultsHtml(results) {
    let html    = '';
    let total   = 0;
    let isFirst = true;
    QUEUE_SECTIONS.forEach((section, si) => {
      if (!isFirst) html += `<div class="queue-section-divider"></div>`;
      isFirst = false;
      html += `<div class="queue-section">`;
      html += `<div class="queue-section-title">${section.title}</div>`;
      section.items.forEach((item, ii) => {
        const count    = results[si][ii];
        const isErr    = count === 'ERR';
        const isZero   = count === 0;
        const countCls = isErr ? 'is-error' : isZero ? 'is-zero' : 'has-value';
        if (!isErr && !isZero) total += count;
        html += `
          <div class="queue-item-row">
            <span class="queue-item-label">${item.label}</span>
            <span class="queue-item-count ${countCls}">${isErr ? '✗' : count}</span>
          </div>`;
      });
      html += `</div>`;
    });
    return { html, total };
  }
  function broadcast(state, payload) {
    instances.forEach(inst => {
      if (state === 'loading') {
        inst.totalBadge.textContent = '—';
        if (inst.isOpen) {
          inst.body.innerHTML = `
            <div class="queue-loading">
              <span class="queue-loading-dot"></span>
              <span class="queue-loading-dot"></span>
              <span class="queue-loading-dot"></span>
            </div>`;
          inst.timestamp.textContent = 'Last updated: loading…';
        }
      } else if (state === 'results') {
        const { html, total } = payload;
        inst.totalBadge.textContent = total > 0 ? total : '0';
        if (inst.isOpen) {
          inst.body.innerHTML        = html;
          inst.timestamp.textContent = `Last updated: ${new Date().toLocaleTimeString()}`;
        }
      } else if (state === 'error') {
        inst.totalBadge.textContent = '!';
        if (inst.isOpen) {
          inst.body.innerHTML = `
            <div class="queue-item-row">
              <span class="queue-item-label" style="color:var(--red);">Failed to load</span>
            </div>`;
          inst.timestamp.textContent = 'Last updated: failed';
        }
      }
    });
  }
  async function fetchAllShared(force) {
    if (isFetching) return;
    if (!force && sharedResults) {
      const { html, total } = buildResultsHtml(sharedResults);
      broadcast('results', { html, total });
      return;
    }
    isFetching = true;
    broadcast('loading');
    instances.forEach(inst => {
      inst.refreshBtn.classList.add('is-refreshing');
      inst.refreshBtn.textContent = '↻';
    });
    try {
      const results = await Promise.all(
        QUEUE_SECTIONS.map(section =>
          Promise.all(section.items.map(item => fetchCount(item.url)))
        )
      );
      sharedResults = results;
      const { html, total } = buildResultsHtml(results);
      broadcast('results', { html, total });
    } catch (err) {
      broadcast('error');
    } finally {
      isFetching = false;
      instances.forEach(inst => {
        inst.refreshBtn.classList.remove('is-refreshing');
        inst.refreshBtn.textContent = '↻ Refresh';
      });
    }
  }
  function buildCopyText() {
    if (!sharedResults) return '';
    const now  = new Date().toLocaleString();
    let   text = `As of ${now}\n============================\n`;
    QUEUE_SECTIONS.forEach((section, si) => {
      text += `\n${section.title}\n`;
      section.items.forEach((item, ii) => {
        const count = sharedResults[si][ii];
        const val   = count === 'ERR' ? 'ERROR' : count;
        text += `${item.label.padEnd(16)} ${val}\n`;
      });
    });
    text += `============================`;
    return text;
  }
  function setupInstance(wrap) {
    const toggleBtn  = wrap.querySelector('[data-queue="toggle"]');
    const popover    = wrap.querySelector('[data-queue="popover"]');
    const body       = wrap.querySelector('[data-queue="body"]');
    const timestamp  = wrap.querySelector('[data-queue="timestamp"]');
    const copyBtn    = wrap.querySelector('[data-queue="copy"]');
    const refreshBtn = wrap.querySelector('[data-queue="refresh"]');
    const totalBadge = wrap.querySelector('[data-queue="badge"]');
    if (!toggleBtn || !popover) return;
    const inst = { toggleBtn, popover, body, timestamp, copyBtn, refreshBtn, totalBadge, isOpen: false };
    instances.push(inst);
    function setCopyFeedback(state) {
      const ok = state === 'success';
      copyBtn.textContent = ok ? '✓' : '✗';
      copyBtn.classList.toggle('copy-success', ok);
      copyBtn.classList.toggle('copy-error', !ok);
      setTimeout(() => {
        copyBtn.textContent = '⧉';
        copyBtn.classList.remove('copy-success', 'copy-error');
      }, 2000);
    }
    async function copyToClipboard() {
      const text = buildCopyText();
      if (!text) return;
      try {
        await navigator.clipboard.writeText(text);
        setCopyFeedback('success');
      } catch (err) {
        try {
          const ta = document.createElement('textarea');
          ta.value = text;
          ta.style.position = 'fixed';
          ta.style.opacity  = '0';
          document.body.appendChild(ta);
          ta.focus(); ta.select();
          document.execCommand('copy');
          document.body.removeChild(ta);
          setCopyFeedback('success');
        } catch (fallbackErr) {
          setCopyFeedback('error');
        }
      }
    }
    function openPopover() {
      inst.isOpen = true;
      popover.classList.add('queue-popover-open');
      toggleBtn.classList.add('queue-open');
      popover.setAttribute('aria-hidden', 'false');
      if (sharedResults) {
        const { html, total } = buildResultsHtml(sharedResults);
        body.innerHTML         = html;
        totalBadge.textContent = total > 0 ? total : '0';
        timestamp.textContent  = `Last updated: ${new Date().toLocaleTimeString()}`;
      } else {
        fetchAllShared(false);
      }
    }
    function closePopover() {
      inst.isOpen = false;
      popover.classList.remove('queue-popover-open');
      toggleBtn.classList.remove('queue-open');
      popover.setAttribute('aria-hidden', 'true');
    }
    toggleBtn.addEventListener('click', e => {
      e.stopPropagation();
      inst.isOpen ? closePopover() : openPopover();
    });
    refreshBtn.addEventListener('click', e => { e.stopPropagation(); fetchAllShared(true); });
    copyBtn.addEventListener('click', e => { e.stopPropagation(); copyToClipboard(); });
    document.addEventListener('click', e => {
      if (!inst.isOpen) return;
      if (!popover.contains(e.target) && !toggleBtn.contains(e.target)) closePopover();
    });
    document.addEventListener('keydown', e => {
      if (e.key === 'Escape' && inst.isOpen) closePopover();
    });
  }
  document.querySelectorAll('.queue-btn-wrap').forEach(setupInstance);
  fetchAllShared(false);
  setInterval(() => fetchAllShared(true), 60000);
})();
/* ============================================================================
   TRANSITIONS — Tab anim, Skeletons, Due Pulse
   ============================================================================ */
(function initTransitions() {
  const ANIM_DURATION = 180;
  function initTabAnimations() {
    const tabButtons = document.querySelectorAll('.tab-btn');
    if (!tabButtons.length) return;
    tabButtons.forEach(btn => {
      btn.addEventListener('click', function() {
        const tabId        = this.id.replace('tab-','').replace('-btn','');
        const currentPanel = document.querySelector('.tab-panel.panel-active');
        const nextPanel    = document.getElementById('panel-' + tabId);
        if (!currentPanel || !nextPanel || currentPanel === nextPanel) return;
        currentPanel.classList.add('panel-exit');
        setTimeout(() => {
          currentPanel.classList.remove('panel-exit');
          nextPanel.classList.add('panel-enter');
          setTimeout(() => { nextPanel.classList.remove('panel-enter'); }, ANIM_DURATION);
        }, ANIM_DURATION);
      });
    });
  }
  const SKELETON_TABLES = [
    { tbodyId: 'm-data', colCount: 12, widths: ['sk-sm','sk-md','sk-lg','sk-md','sk-sm','sk-lg','sk-xs','sk-md','sk-sm','sk-xl','sk-xs','sk-xs'] },
    { tbodyId: 'q-data', colCount: 11, widths: ['sk-sm','sk-md','sk-lg','sk-md','sk-sm','sk-xs','sk-md','sk-sm','sk-xl','sk-xs','sk-xs'] }
  ];
  const SKELETON_ROW_COUNT = 5;
  function buildSkeletonRow(colCount, widths) {
    const tr = document.createElement('tr');
    tr.classList.add('skeleton-row');
    for (let i = 0; i < colCount; i++) {
      const td  = document.createElement('td');
      const div = document.createElement('div');
      div.classList.add('skeleton-cell', widths[i % widths.length]);
      td.appendChild(div);
      tr.appendChild(td);
    }
    return tr;
  }
  function injectSkeletons(tbodyId, colCount, widths) {
    const tbody = document.getElementById(tbodyId);
    if (!tbody || tbody.rows.length > 0) return;
    const fragment = document.createDocumentFragment();
    for (let i = 0; i < SKELETON_ROW_COUNT; i++) {
      fragment.appendChild(buildSkeletonRow(colCount, widths));
    }
    tbody.appendChild(fragment);
  }
  function watchForRealRows(tbodyId) {
    const tbody = document.getElementById(tbodyId);
    if (!tbody) return;
    const observer = new MutationObserver((mutations, obs) => {
      const realRows = tbody.querySelectorAll('tr:not(.skeleton-row)');
      if (realRows.length > 0) {
        tbody.querySelectorAll('.skeleton-row').forEach(row => {
          row.style.transition = 'opacity 0.3s ease';
          row.style.opacity    = '0';
          setTimeout(() => row.remove(), 300);
        });
        obs.disconnect();
      }
    });
    observer.observe(tbody, { childList: true });
  }
  function initSkeletons() {
    SKELETON_TABLES.forEach(({ tbodyId, colCount, widths }) => {
      injectSkeletons(tbodyId, colCount, widths);
      watchForRealRows(tbodyId);
    });
  }
  const PULSE_CONFIG = {
    warning:  { seconds: 3600, interval: 300, cls: 'due-warning-pulse' },
    critical: { seconds: 1800, interval: 120, cls: 'due-critical-pulse' }
  };
  const PULSE_ANIM_DURATION = 1500;
  const cellPulseMap        = new Map();
  function triggerPulse(cell, level) {
    const cls = PULSE_CONFIG[level].cls;
    cell.classList.remove(PULSE_CONFIG.warning.cls, PULSE_CONFIG.critical.cls);
    void cell.offsetWidth;
    cell.classList.add(cls);
    setTimeout(() => { cell.classList.remove(cls); }, PULSE_ANIM_DURATION);
  }
  function registerDueCell(cell) {
    if (cellPulseMap.has(cell)) return;
    const row = cell.closest('tr');
    if (row && row.dataset.type === 'training') return;
    cellPulseMap.set(cell, { level: null, intervalId: null, secondsSince: 0 });
  }
  function pulseTick() {
    cellPulseMap.forEach((state, cell) => {
      if (!document.body.contains(cell)) {
        if (state.intervalId) clearInterval(state.intervalId);
        cellPulseMap.delete(cell);
        return;
      }
      const row = cell.closest('tr');
      if (row && row.dataset.type === 'training') return;
      const sec = parseInt(cell.dataset.seconds || '0', 10);
      let newLevel = null;
      if (sec < PULSE_CONFIG.critical.seconds || sec < 0) {
        newLevel = 'critical';
      } else if (sec < PULSE_CONFIG.warning.seconds) {
        newLevel = 'warning';
      }
      if (newLevel !== state.level) {
        state.level        = newLevel;
        state.secondsSince = 0;
        cell.classList.remove(PULSE_CONFIG.warning.cls, PULSE_CONFIG.critical.cls);
        if (newLevel) triggerPulse(cell, newLevel);
        return;
      }
      if (!newLevel) return;
      state.secondsSince++;
      const intervalSec = PULSE_CONFIG[newLevel].interval;
      if (state.secondsSince >= intervalSec) {
        state.secondsSince = 0;
        triggerPulse(cell, newLevel);
      }
    });
  }
  function watchTbodyForDueCells(tbodyId) {
    const tbody = document.getElementById(tbodyId);
    if (!tbody) return;
    const observer = new MutationObserver(mutations => {
      mutations.forEach(mutation => {
        mutation.addedNodes.forEach(node => {
          if (node.nodeType !== 1) return;
          if (node.classList.contains('skeleton-row')) return;
          const dueCell = node.querySelector('td.due');
          if (dueCell) registerDueCell(dueCell);
        });
      });
    });
    observer.observe(tbody, { childList: true });
  }
  function initDuePulse() {
    watchTbodyForDueCells('m-data');
    watchTbodyForDueCells('q-data');
    setInterval(pulseTick, 1000);
  }
  function init() {
    initTabAnimations();
    initSkeletons();
    initDuePulse();
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
'@
# ============================================================================
# 1. WebView2 SDK bootstrap (download once, cache under %LOCALAPPDATA%)
# ============================================================================
function Get-WebView2Assemblies {
    param([switch]$Force)
    $cacheDir  = Join-Path $env:LOCALAPPDATA 'PAR-App\webview2'
    $coreDll   = Join-Path $cacheDir 'Microsoft.Web.WebView2.Core.dll'
    $wpfDll    = Join-Path $cacheDir 'Microsoft.Web.WebView2.Wpf.dll'
    $loaderDll = Join-Path $cacheDir 'WebView2Loader.dll'
    if ($Force -or -not (Test-Path $coreDll) -or -not (Test-Path $wpfDll) -or -not (Test-Path $loaderDll)) {
        Write-Host 'First run: fetching the WebView2 SDK (one-time, then cached locally)...' -ForegroundColor Cyan
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        $pkgDir  = Join-Path $cacheDir 'pkg'
        $zipPath = Join-Path $cacheDir 'webview2.nupkg.zip'
        try {
            Invoke-WebRequest -Uri 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2' `
                               -OutFile $zipPath -UseBasicParsing
            if (Test-Path $pkgDir) { Remove-Item $pkgDir -Recurse -Force }
            Expand-Archive -Path $zipPath -DestinationPath $pkgDir -Force
            $srcCore = Get-ChildItem -Path $pkgDir -Recurse -Filter 'Microsoft.Web.WebView2.Core.dll' |
                       Where-Object { $_.FullName -match 'net(4|standard|core)' } | Select-Object -First 1
            $srcWpf  = Get-ChildItem -Path $pkgDir -Recurse -Filter 'Microsoft.Web.WebView2.Wpf.dll'  |
                       Where-Object { $_.FullName -match 'net4' } | Select-Object -First 1
            $srcLoader = Get-ChildItem -Path $pkgDir -Recurse -Filter 'WebView2Loader.dll' |
                         Where-Object { $_.FullName -match 'win-x64' } | Select-Object -First 1
            if (-not $srcCore -or -not $srcWpf -or -not $srcLoader) {
                throw 'Could not locate the required WebView2 assemblies inside the downloaded package.'
            }
            Copy-Item $srcCore.FullName   $coreDll   -Force
            Copy-Item $srcWpf.FullName    $wpfDll    -Force
            Copy-Item $srcLoader.FullName $loaderDll -Force
        }
        finally {
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            if (Test-Path $pkgDir) { Remove-Item $pkgDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    return [pscustomobject]@{ Core = $coreDll; Wpf = $wpfDll; Loader = $loaderDll; Dir = $cacheDir }
}
try {
    $wv2 = Get-WebView2Assemblies -Force:$ForceWebView2Refresh
    Add-Type -Path $wv2.Core
    Add-Type -Path $wv2.Wpf
}
catch {
    [System.Windows.MessageBox]::Show(
        "Couldn't set up the WebView2 SDK components`n`n$($_.Exception.Message)`n`n" +
        "This app needs internet access the first time it runs so it can fetch " +
        "Microsoft.Web.WebView2 from nuget.org (cached afterward). If your machine " +
        "blocks nuget.org, ask IT to allow it once, or pre-seed the cache folder:`n" +
        "$env:LOCALAPPDATA\PAR-App\webview2",
        'PAR — setup failed', 'OK', 'Error') | Out-Null
    exit 1
}
# ============================================================================
# 2. Local loopback HTTP server (serves the embedded assets)
# ============================================================================
function Get-FreeLoopbackPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ($listener.LocalEndpoint).Port
    $listener.Stop()
    return $port
}
$port   = Get-FreeLoopbackPort
$prefix = "http://127.0.0.1:$port/"
$assets = @{
    '/'            = @{ Content = $ParHtml; Type = 'text/html; charset=utf-8' }
    '/PAR.html'    = @{ Content = $ParHtml; Type = 'text/html; charset=utf-8' }
    '/src/PAR.css' = @{ Content = $ParCss;  Type = 'text/css; charset=utf-8' }
    '/src/PAR.js'  = @{ Content = $ParJs;   Type = 'application/javascript; charset=utf-8' }
}
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
}
catch {
    [System.Windows.MessageBox]::Show(
        "Couldn't start the local server on ${prefix}:`n$($_.Exception.Message)",
        'PAR — startup failed', 'OK', 'Error') | Out-Null
    exit 1
}
# Background runspace serving requests, so the WPF message loop stays free.
$listenerRunspace = [runspacefactory]::CreateRunspace()
$listenerRunspace.Open()
$listenerRunspace.SessionStateProxy.SetVariable('Listener', $listener)
$listenerRunspace.SessionStateProxy.SetVariable('Assets', $assets)
$serverPs = [powershell]::Create()
$serverPs.Runspace = $listenerRunspace
[void]$serverPs.AddScript({
    while ($Listener.IsListening) {
        try { $ctx = $Listener.GetContext() } catch { break }
        try {
            $path = $ctx.Request.Url.AbsolutePath
            if ($Assets.ContainsKey($path)) {
                $item  = $Assets[$path]
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($item.Content)
                $ctx.Response.ContentType     = $item.Type
                $ctx.Response.ContentLength64 = $bytes.Length
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            else {
                $ctx.Response.StatusCode = 404
            }
        }
        catch { }
        finally { $ctx.Response.OutputStream.Close() }
    }
})
$serverHandle = $serverPs.BeginInvoke()
# ============================================================================
# 3. WPF window hosting the WebView2 control
# ============================================================================
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="PAR — Prod Active Reports"
        Height="900" Width="1500" MinHeight="500" MinWidth="800"
        WindowStartupLocation="CenterScreen"
        WindowState="Maximized"
        Background="#0e1117">
</Window>
"@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)
$webView = New-Object Microsoft.Web.WebView2.Wpf.WebView2
# Match the app's dark theme so the WebView2 surface doesn't flash white
# while WebView2 spins up and the page paints for the first time.
$webView.DefaultBackgroundColor = [System.Drawing.Color]::FromArgb(255, 14, 17, 23)
$window.Content = $webView
$window.Add_Closed({
    try { $listener.Stop() } catch { }
    try { $serverPs.Stop(); $serverPs.Dispose() } catch { }
    try { $listenerRunspace.Close() } catch { }
})
try {
    $userDataDir = Join-Path $env:LOCALAPPDATA 'PAR-App\webview2-profile'
    $additionalArgs = if ($EnforceWebSecurity) { $null } else { '--disable-web-security' }
    $envOptions = New-Object -TypeName Microsoft.Web.WebView2.Core.CoreWebView2EnvironmentOptions -ArgumentList $additionalArgs
    $envTask = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($null, $userDataDir, $envOptions)
    $coreEnv = $envTask.GetAwaiter().GetResult()
}
catch {
    [System.Windows.MessageBox]::Show(
        "Couldn't create the WebView2 environment`n`n$($_.Exception.Message)`n`n" +
        "Make sure the Microsoft Edge WebView2 Runtime is installed " +
        "(it ships by default on most Windows 10/11 machines).",
        'PAR — startup failed', 'OK', 'Error') | Out-Null
    try { $listener.Stop() } catch { }
    exit 1
}
$webView.add_CoreWebView2InitializationCompleted({
    param($eventSender, $e)
    if ($e.IsSuccess) {
        $webView.CoreWebView2.Navigate($prefix)
    }
    else {
        [System.Windows.MessageBox]::Show(
            "WebView2 failed to initialize`n`n$($e.InitializationException.Message)",
            'PAR — startup failed', 'OK', 'Error') | Out-Null
    }
})
$window.Add_Loaded({
    try {
        $webView.EnsureCoreWebView2Async($coreEnv) | Out-Null
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "Couldn't initialize the WebView2 control`n`n$($_.Exception.Message)",
            'PAR — startup failed', 'OK', 'Error') | Out-Null
    }
})
[void]$window.ShowDialog()