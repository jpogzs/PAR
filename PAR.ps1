#requires -Version 5.1
<#
============================================================================
PAR — Prod Active Reports (standalone desktop GUI)
Created and developed by PIA — members: Pogi, LT, Rona

Do not edit the code without informing PIA
PIA site: https://eagleviewcloud.sharepoint.com/sites/QualityTeam/SitePages/PIA.aspx
============================================================================
#>

[CmdletBinding()]
param(
    # Keep the browser's normal CORS enforcement instead of relaxing it.
    [switch]$EnforceWebSecurity,
    # Force re-download of the WebView2 SDK assemblies even if cached.
    [switch]$ForceWebView2Refresh
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# ============================================================
#  SHORTCUT SELF-DEPLOY
# ============================================================
$Desktop = [Environment]::GetFolderPath("Desktop")
Copy-Item -Path "P:\1_Coordinators\PIA\PAR.lnk" `
          -Destination "$Desktop\PAR.lnk" `
          -Force -ErrorAction SilentlyContinue

# ============================================================
#  USAGE LOGGING
# ============================================================
# Appends one line per launch to a shared CSV so PIA can see who is
# using PAR and when. Never throws — a log failure must not block the app.
function Write-ParUsageLog {
    param(
        [string]$LogPath = "P:\1_Coordinators\PIA\PAR\Logs\PAR_usage.csv",
        [string]$Action  = 'Launch',
        [string]$Details = ''
    )
    try {
        $logDir = Split-Path -Path $LogPath -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
        $entry = [PSCustomObject]@{
            Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            User      = $env:USERNAME
            Computer  = $env:COMPUTERNAME
            Action    = $Action
            Details   = $Details
        }
        $writeHeader = -not (Test-Path $LogPath)
        $entry | Export-Csv -Path $LogPath -NoTypeInformation -Append:(!$writeHeader) -Force:$writeHeader -ErrorAction Stop
    }
    catch {
        # Network share unreachable, off-VPN, permissions, etc. — fall back
        # to a local log so the launch is still recorded somewhere, and
        # never let a logging failure interrupt the app from starting.
        try {
            $fallback = Join-Path $env:TEMP 'PAR_usage_fallback.log'
            Add-Content -Path $fallback -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $env:USERNAME | $env:COMPUTERNAME | $Action | $Details | LOG_ERROR: $($_.Exception.Message)" -ErrorAction SilentlyContinue
        }
        catch { }
    }
}
Write-ParUsageLog -Action 'Launch'

# ============================================================
#  ROLE-BASED ACCESS CHECK
# ============================================================
# Confirms the launching user holds role 10 (required for PAR access)
# before the app is allowed to continue.
#
# >>> TEMP DEBUG: Write-ParDebug lines below print each step to the console
#     for troubleshooting. Set $ParDebugEnabled to $true to see them again;
#     leave $false (default) to keep the terminal quiet. <<<
$ParDebugEnabled = $false
function Write-ParDebug {
    param([string]$Message, [ConsoleColor]$Color = 'Cyan')
    if ($ParDebugEnabled) {
        Write-Host $Message -ForegroundColor $Color
    }
}
$userEmail = (whoami /upn).Trim()
Write-ParUsageLog -Action 'RoleCheckStart' -Details "email=$userEmail"
Write-ParDebug "[DEBUG] userEmail = $userEmail" -Color Cyan

function Get-ParUserRoleResponse {
    param([string]$Email)
    $url = "https://api.cmh.platform-prod2.evinternal.net/operations-center/api/UserRole?userEmail=$Email"
    Write-ParDebug "[DEBUG] GET $url" -Color Cyan
    Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
}

# Reads the response body off a failed web request (Invoke-RestMethod only
# throws on non-2xx, it doesn't give you the body directly), so we can check
# whether the API's error message was "No user found" vs. something else.
function Get-ParErrorResponseBody {
    param($ErrorRecord)
    try {
        if ($ErrorRecord.Exception.Response) {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Close()
            return $body
        }
        elseif ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            return $ErrorRecord.ErrorDetails.Message
        }
    }
    catch { }
    return $null
}

# Accounts may be registered under any of these email domains depending on
# site (PH main, PH "mnl" segment, or Bogotá). Build the candidate list from
# the local part of the UPN and try each domain in turn until one resolves
# to a real user.
function Get-ParCandidateEmails {
    param([string]$Email)
    $localPart = ($Email -split '@')[0]
    return @(
        "$localPart@eagleview.com",
        "$localPart@mnl.eagleview.com",
        "$localPart@bog.eagleview.net"
    )
}

$candidateEmails = Get-ParCandidateEmails -Email $userEmail
Write-ParDebug "[DEBUG] candidateEmails = $($candidateEmails -join ', ')" -Color Cyan

$userRoleResponse = $null
$lastLookupError  = $null
foreach ($candidateEmail in $candidateEmails) {
    try {
        $response = Get-ParUserRoleResponse -Email $candidateEmail
        Write-ParDebug "[DEBUG] userRoleResponse ($candidateEmail) = $($response | ConvertTo-Json -Compress -Depth 3)" -Color Cyan
        Write-ParUsageLog -Action 'RoleCheckLookup' -Details "email=$candidateEmail; response=$($response | ConvertTo-Json -Compress -Depth 3)"

        if ($response.message -and $response.message -match 'No user found') {
            Write-ParDebug "[DEBUG] '$candidateEmail' -> No user found, trying next candidate" -Color Yellow
            continue
        }

        $userRoleResponse = $response
        $userEmail        = $candidateEmail
        break
    }
    catch {
        $lastLookupError = $_
        $errorBody = Get-ParErrorResponseBody -ErrorRecord $_
        Write-ParDebug "[DEBUG] EXCEPTION during UserRoleLookup ($candidateEmail): $($_.Exception.Message)" -Color Red
        Write-ParDebug "[DEBUG] error response body = $errorBody" -Color Red

        $isNotFound = ($_.Exception.Message -match '404') -or ($errorBody -match 'No user found')
        if ($isNotFound) {
            Write-ParUsageLog -Action 'RoleCheckFallback' -Details "email=$candidateEmail; triggerError=$($_.Exception.Message)"
            continue
        }
        else {
            # A non-404 failure (network, auth, server error) isn't something
            # trying another domain will fix — surface it immediately instead
            # of burning through the remaining candidates.
            Write-ParUsageLog -Action 'RoleCheckFailed' -Details "stage=UserRoleLookup; email=$candidateEmail; error=$($_.Exception.Message)"
            [System.Windows.MessageBox]::Show(
                "Couldn't verify your access permissions.`n`n$($_.Exception.Message)`n`n" +
                "Please check your network connection and try again, or contact PIA if this continues.",
                'PAR — access check failed', 'OK', 'Error') | Out-Null
            exit 1
        }
    }
}

if (-not $userRoleResponse) {
    Write-ParDebug "[DEBUG] FAIL: no candidate email resolved to a user" -Color Red
    Write-ParUsageLog -Action 'RoleCheckFailed' -Details "stage=NoCandidateMatched; tried=$($candidateEmails -join ','); lastError=$($lastLookupError.Exception.Message)"
    [System.Windows.MessageBox]::Show(
        "Couldn't verify your access permissions.`n`nNo matching user was found.`n`n" +
        "Please contact PIA if this continues.",
        'PAR — access check failed', 'OK', 'Error') | Out-Null
    exit 1
}

$userId = $userRoleResponse.userId
Write-ParDebug "[DEBUG] userId = $userId" -Color Cyan
if (-not $userId) {
    Write-ParDebug "[DEBUG] FAIL: no userId in response" -Color Red
    Write-ParUsageLog -Action 'RoleCheckFailed' -Details "stage=NoUserId; email=$userEmail; response=$($userRoleResponse | ConvertTo-Json -Compress -Depth 3)"
    [System.Windows.MessageBox]::Show(
        "Couldn't verify your access permissions.`n`nNo user ID was returned for your account.`n`n" +
        "Please contact PIA if this continues.",
        'PAR — access check failed', 'OK', 'Error') | Out-Null
    exit 1
}

$allRolesApiUrl = "https://api.cmh.platform-prod2.evinternal.net/operations-center/api/UserRole/$userId/all"
Write-ParDebug "[DEBUG] GET $allRolesApiUrl" -Color Cyan
try {
    $allRolesResponse = Invoke-RestMethod -Uri $allRolesApiUrl -Method Get -ErrorAction Stop
    Write-ParDebug "[DEBUG] allRolesResponse = $($allRolesResponse | ConvertTo-Json -Compress -Depth 3)" -Color Cyan
    Write-ParUsageLog -Action 'RoleCheckAllRoles' -Details "userId=$userId; roleIds=$(($allRolesResponse | ForEach-Object { $_.roleId }) -join ',')"
}
catch {
    Write-ParDebug "[DEBUG] EXCEPTION during AllRolesLookup: $($_.Exception.Message)" -Color Red
    Write-ParUsageLog -Action 'RoleCheckFailed' -Details "stage=AllRolesLookup; userId=$userId; error=$($_.Exception.Message)"
    [System.Windows.MessageBox]::Show(
        "Couldn't verify your access permissions.`n`n$($_.Exception.Message)`n`n" +
        "Please check your network connection and try again, or contact PIA if this continues.",
        'PAR — access check failed', 'OK', 'Error') | Out-Null
    exit 1
}

$roleIds = $allRolesResponse | ForEach-Object { $_.roleId }
Write-ParDebug "[DEBUG] roleIds = $($roleIds -join ',')" -Color Cyan
Write-ParDebug "[DEBUG] has role 10? $(($roleIds -contains 10))" -Color Cyan
if (-not $allRolesResponse -or (-not ($allRolesResponse | Where-Object { $_.roleId -eq 10 }))) {
    Write-ParDebug "[DEBUG] RESULT: RESTRICTED (role 10 not found)" -Color Red
    Write-ParUsageLog -Action 'Restricted' -Details "userId=$userId; email=$userEmail; roleIds=$(($allRolesResponse | ForEach-Object { $_.roleId }) -join ',')"
    [System.Windows.MessageBox]::Show(
        "Restricted`n`nContact PIA",
        'PAR — access denied', 'OK', 'Warning') | Out-Null
    exit 1
}
Write-ParDebug "[DEBUG] RESULT: ACCESS GRANTED" -Color Green

Write-ParUsageLog -Action 'RoleCheckPassed' -Details "userId=$userId; email=$userEmail"
# >>> END TEMP DEBUG <<<

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
  <div id="reportDetailOverlay" class="detail-overlay" aria-hidden="true">
    <div class="detail-modal" role="dialog" aria-modal="true" aria-labelledby="detailModalTitle">
      <div class="detail-modal-header">
        <div>
          <div class="detail-modal-title" id="detailModalTitle">Report</div>
          <div class="detail-modal-subtitle" id="detailModalSubtitle"></div>
        </div>
        <button class="detail-close-btn" id="detailCloseBtn" title="Close" aria-label="Close">×</button>
      </div>
      <div class="detail-images-section" id="detailImagesSection">
        <div class="detail-section-title">Images<span class="detail-images-status" id="detailImagesStatus">Searching…</span></div>
        <div class="detail-images-grid" id="detailImagesGrid"></div>
      </div>
      <div class="detail-tabs" role="tablist">
        <div class="detail-tabs-list">
          <button class="detail-tab active" id="detailTabOverview" data-tab="overview" role="tab" aria-selected="true">Overview</button>
          <button class="detail-tab detail-tab-hidden" id="detailTabEvm" data-tab="evm" role="tab" aria-selected="false">EVM Data</button>
          <button class="detail-tab" id="detailTabHistory" data-tab="history" role="tab" aria-selected="false">History</button>
        </div>
        <div class="detail-tabs-actions">
          <button class="detail-footer-btn" id="detailExplorerBtn" type="button">Explorer</button>
          <button class="detail-footer-btn" id="detailGmapsBtn" type="button">Gmaps</button>
        </div>
      </div>
      <div class="detail-modal-body" id="detailModalBody">
        <div class="detail-panel active" id="detailPanelOverview"></div>
        <div class="detail-panel" id="detailPanelEvm"></div>
        <div class="detail-panel" id="detailPanelHistory"></div>
      </div>
      <div class="detail-modal-footer" id="detailModalFooter">
        <span class="detail-footer-meta" id="detailFooterMeta"></span>
      </div>
    </div>
  </div>
  <div id="imageLightbox" class="image-lightbox" aria-hidden="true">
    <button class="image-lightbox-close" id="imageLightboxClose" title="Close" aria-label="Close">×</button>
    <img id="imageLightboxImg" src="" alt="Report image full size">
  </div>
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
        <span class="stat-pill live" id="m-statRTM" title="Filter by Ready To Measure">RTM: —</span>
        <span class="stat-pill orange" id="m-statBM" title="Filter by Being Measured">BM: —</span>
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
      <button class="export-csv-btn" id="m-exportCsv" type="button" title="Export visible columns to CSV">⬇ Export</button>
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
          <th>Application</th>
          <th>Product Type</th>
          <th>Report Details</th>
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
        <span class="stat-pill live" id="q-statRFQC" title="Filter by Ready For QC">RFQC: —</span>
        <span class="stat-pill orange" id="q-statBQC" title="Filter by Being Qced">BQC: —</span>
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
      <button class="export-csv-btn" id="q-exportCsv" type="button" title="Export visible columns to CSV">⬇ Export</button>
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
          <th>Application</th>
          <th>Product Type</th>
          <th>Report Details</th>
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
      <span class="footer-brand" id="footerBrandPia" title="Open PIA site">PIA</span>
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
      <span class="footer-version">version 3.9.2</span>
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
.stat-pill.orange {
  border-color: #a85a1e; color: var(--orange);
  box-shadow: 0 0 10px rgba(255,140,66,0.3), 0 1px 3px rgba(0,0,0,0.2) !important;
}
.stat-pill.late {
  border-color: #7a2233; color: var(--red);
  box-shadow: 0 0 10px rgba(255,77,106,0.3), 0 1px 3px rgba(0,0,0,0.2) !important;
}
body.light .stat-pill { box-shadow: 0 1px 3px rgba(0,0,0,0.1) !important; }
body.light .stat-pill.live { box-shadow: 0 0 10px rgba(2,150,89,0.2), 0 1px 3px rgba(0,0,0,0.08) !important; }
body.light .stat-pill.orange { box-shadow: 0 0 10px rgba(255,140,66,0.25), 0 1px 3px rgba(0,0,0,0.08) !important; }
body.light .stat-pill.late { box-shadow: 0 0 10px rgba(217,48,80,0.2), 0 1px 3px rgba(0,0,0,0.08) !important; }
/* Clickable pills — RTM/BM (Measure) and RFQC/BQC (QC) filter the search
   box by that state; the Due pill stays non-interactive. */
#m-statRTM, #m-statBM, #q-statRFQC, #q-statBQC {
  cursor: pointer;
}
#m-statRTM:hover, #m-statBM:hover, #q-statRFQC:hover, #q-statBQC:hover {
  transform: translateY(-1px);
  filter: brightness(1.15);
}
.stat-pill-filter-active {
  outline: 2px solid currentColor;
  outline-offset: 1px;
}
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
/* ── EXPORT CSV BUTTON ── */
.export-csv-btn {
  margin-left: auto;
  font-family: var(--sans); font-size: 10px; font-weight: 600;
  letter-spacing: 0.03em; white-space: nowrap;
  padding: 5px 10px; border-radius: 5px;
  border: 1px solid var(--border-light); background: var(--bg-card);
  color: var(--text-secondary); cursor: pointer;
  transition: all 0.15s !important;
}
.export-csv-btn:hover {
  border-color: var(--green); color: var(--text-primary);
  transform: translateY(-1px);
  box-shadow: 0 2px 6px rgba(0,0,0,0.25);
}
.export-csv-btn:active { transform: translateY(0); }
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
.par-table tbody tr[data-detail-key]            { cursor:pointer; }
.par-table tbody tr.row-detail-active            { background: var(--green-glow); border-left-color: var(--green) !important; }
.par-table tbody tr.row-detail-active:hover      { background: var(--green-glow); }
@keyframes rowIn { from{opacity:0;transform:translateY(3px)} to{opacity:1;transform:translateY(0)} }
/* ── REPORT DETAIL MODAL ── */
.detail-overlay {
  position: fixed; inset: 0; z-index: 200;
  background: rgba(0,0,0,0.45);
  display: flex; align-items: center; justify-content: center;
  opacity: 0; pointer-events: none;
  transition: opacity 0.18s ease;
}
.detail-overlay.open { opacity: 1; pointer-events: auto; }
.detail-modal {
  width: 640px; max-width: 92vw; max-height: 90vh;
  background: var(--bg-base); border: 1px solid var(--border-light);
  border-radius: 10px; box-shadow: 0 12px 48px rgba(0,0,0,0.35), 0 2px 8px rgba(0,0,0,0.15);
  display: flex; flex-direction: column; overflow: hidden;
  transform: translateY(8px) scale(0.98); opacity: 0;
  transition: transform 0.18s ease, opacity 0.18s ease;
}
.detail-overlay.open .detail-modal { transform: translateY(0) scale(1); opacity: 1; }
.detail-modal-header {
  display: flex; align-items: flex-start; justify-content: space-between;
  padding: 16px 18px; border-bottom: 1px solid var(--border-light);
  background: var(--bg-surface); flex-shrink: 0;
}
.detail-modal-title { font-size: 14px; font-weight: 600; letter-spacing: 0.04em; color: var(--text-primary); }
.detail-modal-subtitle { font-size: 11px; color: var(--text-muted); margin-top: 4px; letter-spacing: 0.03em; }
.detail-product-line { font-size: 12px; color: var(--text-secondary); font-family: var(--sans); }
.detail-folder-name { font-size: 11px; color: var(--text-muted); margin-top: 4px; letter-spacing: 0.02em; word-break: break-word; }
.detail-close-btn {
  border: none; background: transparent; color: var(--text-muted);
  font-size: 20px; line-height: 1; cursor: pointer; padding: 2px 6px;
  border-radius: 6px; transition: background 0.12s, color 0.12s;
}
.detail-close-btn:hover { background: var(--bg-hover); color: var(--text-primary); }
.detail-images-section { flex-shrink: 0; max-height: 200px; overflow-y: auto; padding: 12px 18px 0; }
.detail-tabs { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 12px 18px 0; border-bottom: 1px solid var(--border-light); flex-shrink: 0; }
.detail-tabs-list { display: flex; gap: 4px; }
.detail-tabs-actions { display: flex; gap: 6px; margin-bottom: 8px; }
.detail-tab {
  border: none; background: transparent; color: var(--text-secondary);
  font-family: var(--sans); font-size: 12px; font-weight: 600; letter-spacing: 0.02em;
  padding: 10px 4px; margin-bottom: -1px; cursor: pointer;
  border-bottom: 2px solid transparent; transition: color 0.12s, border-color 0.12s;
}
.detail-tab + .detail-tab { margin-left: 14px; }
.detail-tab:hover { color: var(--text-primary); }
.detail-tab.active { color: var(--text-primary); border-bottom-color: var(--green); }
.detail-tab-hidden { display: none !important; }
.detail-panel { display: none; }
.detail-panel.active { display: block; }
.detail-modal-body { flex: 1 1 auto; min-height: 0; padding: 6px 18px 18px; overflow-y: auto; }
.detail-modal-footer {
  display: flex; align-items: center; justify-content: flex-end; gap: 10px;
  padding: 12px 18px; border-top: 1px solid var(--border-light);
  background: var(--bg-surface); flex-shrink: 0;
}
.detail-footer-meta {
  font-size: 11px; color: var(--text-muted); letter-spacing: 0.02em;
  margin-right: auto; font-family: var(--mono);
}
.detail-footer-btn {
  font-size: 10px; font-weight: 600; letter-spacing: 0.03em;
  padding: 4px 10px; border-radius: 5px;
  border: 1px solid var(--border-light); background: var(--bg-card);
  color: var(--text-secondary); cursor: pointer;
  transition: all 0.15s;
}
.detail-footer-btn:hover:not(:disabled) {
  border-color: var(--green); color: var(--text-primary);
  transform: translateY(-1px);
  box-shadow: 0 2px 6px rgba(0,0,0,0.25);
}
.detail-footer-btn:active:not(:disabled) { transform: translateY(0); }
.detail-footer-btn:disabled { opacity: 0.35; cursor: not-allowed; }
/* Row right-click context menu */
.row-context-menu {
  position: fixed;
  min-width: 180px;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius-md);
  box-shadow: 0 8px 32px rgba(0,0,0,0.4), 0 2px 8px rgba(0,0,0,0.3);
  z-index: 100000;
  padding: 5px;
  opacity: 0;
  transform: scale(0.97);
  pointer-events: none;
  transition: opacity 0.12s ease, transform 0.12s ease;
}
.row-context-menu.row-context-menu-open { opacity: 1; transform: scale(1); pointer-events: all; }
body.light .row-context-menu { box-shadow: 0 8px 32px rgba(0,0,0,0.12), 0 2px 8px rgba(0,0,0,0.08); }
.row-context-menu-item {
  display: block; width: 100%; text-align: left;
  font-family: var(--sans); font-size: 12px; font-weight: 500;
  color: var(--text-primary); background: transparent;
  border: none; border-radius: 5px; padding: 7px 10px;
  cursor: pointer; transition: background 0.1s;
}
.row-context-menu-item:hover:not(:disabled) { background: var(--bg-hover); }
.row-context-menu-item:disabled { color: var(--text-muted); cursor: not-allowed; opacity: 0.5; }
.row-context-menu-sep { height: 1px; margin: 5px 2px; background: var(--border); }
.detail-section { margin-top: 16px; }
.detail-section:first-child { margin-top: 12px; }
.detail-section-divider { border: none; border-top: 1px solid var(--border-light); margin: 18px 0 0; }
.detail-section-title {
  font-size: 10px; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase;
  color: var(--text-muted); margin-bottom: 6px;
}
.detail-row {
  display: flex; gap: 10px; padding: 5px 0;
  border-bottom: 1px solid var(--border-light); font-size: 12px;
}
.detail-row:last-child { border-bottom: none; }
.detail-label { flex: 0 0 18ch; color: var(--text-muted); }
.detail-value { flex: 1; color: var(--text-primary); word-break: break-word; }
.detail-value-placeholder { color: var(--text-secondary); }
.detail-row-split { gap: 24px; }
.detail-row-half { display: flex; gap: 10px; flex: 1 1 50%; min-width: 0; }
.detail-row-half .detail-label { flex: 0 0 auto; }
.detail-row-half .detail-value { flex: 1; }
.detail-columns { display: flex; gap: 32px; border-bottom: 1px solid var(--border-light); padding-bottom: 5px; }
.detail-column { flex: 1 1 50%; min-width: 0; display: flex; flex-direction: column; }
@media (max-width: 560px) {
  .detail-columns { flex-direction: column; gap: 0; }
}
.detail-grid {
  display: grid;
  grid-template-columns: max-content 1fr max-content 1fr;
  column-gap: 0;
}
.detail-grid > .detail-label,
.detail-grid > .detail-value {
  padding: 5px 20px 5px 0;
  border-bottom: 1px solid var(--border-light);
  font-size: 12px;
}
.detail-grid > .detail-label { color: var(--text-muted); flex: none; }
.detail-grid > .detail-value { color: var(--text-primary); word-break: break-word; }
@media (max-width: 560px) {
  .detail-grid { grid-template-columns: max-content 1fr; }
}
.detail-empty { font-size: 12px; color: var(--text-muted); font-style: italic; }
.detail-timeline { display: flex; flex-direction: column; gap: 10px; padding-bottom: 18px; }
.detail-timeline-item { display: flex; gap: 8px; align-items: flex-start; }
.detail-timeline-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--green); margin-top: 5px; flex-shrink: 0; }
.detail-timeline-text { display: flex; justify-content: space-between; align-items: baseline; gap: 10px; flex: 1; min-width: 0; }
.detail-timeline-desc { font-size: 12px; color: var(--text-primary); }
.detail-timeline-time { font-size: 10px; color: var(--text-muted); white-space: nowrap; flex-shrink: 0; }
/* ── DETAIL MODAL: IMAGES ── */
.detail-images-status {
  font-size: 10px; font-weight: 400; text-transform: none;
  letter-spacing: 0.02em; color: var(--text-muted); margin-left: 8px;
}
.detail-images-grid {
  display: grid; grid-template-columns: repeat(5, 1fr); gap: 8px;
}
@media (max-width: 480px) {
  .detail-images-grid { grid-template-columns: repeat(auto-fill, minmax(84px, 1fr)); }
}
.detail-image-thumb {
  position: relative; aspect-ratio: 1 / 1; border-radius: 6px; overflow: hidden;
  background: var(--bg-card); border: 1px solid var(--border-light); cursor: pointer;
}
.detail-image-thumb img { width: 100%; height: 100%; object-fit: cover; display: block; transition: transform 0.15s ease; }
.detail-image-thumb:hover img { transform: scale(1.06); }
.detail-image-thumb.img-error { display: none; }
.detail-image-skel {
  cursor: default;
  background: linear-gradient(90deg, var(--bg-card) 0%, var(--bg-hover) 40%, var(--bg-card) 80%);
  background-size: 200% 100%;
  animation: skeleton-shimmer 1.6s ease-in-out infinite;
}
.detail-images-empty { grid-column: 1 / -1; font-size: 12px; color: var(--text-muted); font-style: italic; padding: 8px 0; }
.image-lightbox {
  position: fixed; inset: 0; z-index: 300; background: rgba(0,0,0,0.82);
  display: flex; align-items: center; justify-content: center;
  opacity: 0; pointer-events: none; transition: opacity 0.15s ease;
}
.image-lightbox.open { opacity: 1; pointer-events: auto; }
.image-lightbox img { max-width: 90vw; max-height: 88vh; border-radius: 6px; box-shadow: 0 12px 48px rgba(0,0,0,0.5); }
.image-lightbox-close {
  position: absolute; top: 18px; right: 24px; border: none; background: transparent; color: #fff;
  font-size: 28px; cursor: pointer; line-height: 1; padding: 4px 10px; border-radius: 6px;
}
.image-lightbox-close:hover { background: rgba(255,255,255,0.12); }
.par-table td {
  padding:7px 12px; color:var(--text-primary);
  text-align:center; vertical-align:middle; border:none;
  font-family:var(--mono); font-size:13px;
  background-color: transparent;
}
/* Product Type: never wrap, regardless of table (measure col 11, qc col 10) */
#measure-table td:nth-child(11),
#qc-table td:nth-child(10)
  { white-space:nowrap; }
/* Report Details: never wrap (measure col 12, qc col 11) */
#measure-table td:nth-child(12),
#qc-table td:nth-child(11)
  { white-space:nowrap; }
/* Team: never wrap (measure col 8, qc col 7) */
#measure-table td:nth-child(8),
#qc-table td:nth-child(7)
  { white-space:nowrap; }
/* State: never wrap (measure col 4, qc col 3) */
#measure-table td:nth-child(4),
#qc-table td:nth-child(3)
  { white-space:nowrap; }
/* Rework Details: cap width so long notes/URLs wrap instead of forcing
   the table (and page) to scroll horizontally (measure col 6 only). */
#measure-table td:nth-child(6) {
  max-width: 420px;
  overflow-wrap: anywhere;
  word-break: break-word;
}
/* ── MEASURE column alignment ── */
#measure-table td:nth-child(3),#measure-table td:nth-child(4),#measure-table td:nth-child(5),
#measure-table td:nth-child(6),#measure-table td:nth-child(7),#measure-table td:nth-child(8),
#measure-table td:nth-child(9),#measure-table td:nth-child(10),#measure-table td:nth-child(11),
#measure-table td:nth-child(12)
  { text-align:left; }
#measure-table thead th:nth-child(3),#measure-table thead th:nth-child(4),#measure-table thead th:nth-child(5),
#measure-table thead th:nth-child(6),#measure-table thead th:nth-child(7),#measure-table thead th:nth-child(8),
#measure-table thead th:nth-child(9),#measure-table thead th:nth-child(10),#measure-table thead th:nth-child(11),
#measure-table thead th:nth-child(12)
  { text-align:left; }
#measure-table td:nth-child(4),#measure-table td:nth-child(5),#measure-table td:nth-child(6),
#measure-table td:nth-child(7),#measure-table td:nth-child(8),#measure-table td:nth-child(9) { color:var(--text-secondary); }
/* ── QC column alignment ── */
#qc-table td:nth-child(3),#qc-table td:nth-child(4),#qc-table td:nth-child(6),
#qc-table td:nth-child(7),#qc-table td:nth-child(8),#qc-table td:nth-child(9),#qc-table td:nth-child(10),
#qc-table td:nth-child(11)
  { text-align:left; }
#qc-table thead th:nth-child(3),#qc-table thead th:nth-child(4),#qc-table thead th:nth-child(6),
#qc-table thead th:nth-child(7),#qc-table thead th:nth-child(8),#qc-table thead th:nth-child(9),#qc-table thead th:nth-child(10),
#qc-table thead th:nth-child(11)
  { text-align:left; }
#qc-table td:nth-child(1),#qc-table td:nth-child(5),#qc-table td:nth-child(6),
#qc-table td:nth-child(7),#qc-table td:nth-child(8) { color:var(--text-secondary); }
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
  cursor: pointer;
}
.footer-brand:hover {
  color: var(--amber);
  text-decoration: underline;
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
// Auto-reload must not arm until BOTH tables have finished their initial
// fetch, render, and sort — otherwise whichever table happens to load
// faster would start the 5-minute countdown while the other is still
// mid-render.
let m_tableReady = false, q_tableReady = false;
function maybeStartReloadTimer(){
  if (m_tableReady && q_tableReady && !reloadTimerStarted) startReloadTimer();
}
let m_fetchTrainingOnDemand = null;
let q_fetchTrainingOnDemand = null;
let m_trainingFetched = false;
let q_trainingFetched = false;
/* ── ROW DETAIL STORE ── */
const rowDetailsStore = {};
let imageLoadToken = 0;
let fileInfoLoadToken = 0;
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
  const piaBrand = document.getElementById('footerBrandPia');
  if (piaBrand) {
    piaBrand.addEventListener('click', () => {
      window.open('https://eagleviewcloud.sharepoint.com/sites/QualityTeam/SitePages/PIA.aspx', '_blank', 'noopener');
    });
  }
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
  /* Stat pills → click to filter the search box by that state
     (clicking an already-active pill clears the filter). */
  function wirePillFilter(pillId, prefix, filterText){
    const pill = document.getElementById(pillId);
    if (!pill) return;
    pill.addEventListener('click', () => {
      const input = document.getElementById(`${prefix}-myInput`);
      if (!input) return;
      const isActive = input.value.trim().toLowerCase() === filterText.toLowerCase();
      input.value = isActive ? '' : filterText;
      localStorage.setItem(`myInputState_${prefix}`, input.value);
      applyAllFilters(prefix);
    });
  }
  wirePillFilter('m-statRTM',  'm', 'Ready To Measure');
  wirePillFilter('m-statBM',   'm', 'Being Measured');
  wirePillFilter('q-statRFQC', 'q', 'Ready For QC');
  wirePillFilter('q-statBQC',  'q', 'Being Qced');
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
  document.getElementById('m-exportCsv')?.addEventListener('click', () => exportTableToCsv('measure-table'));
  document.getElementById('q-exportCsv')?.addEventListener('click', () => exportTableToCsv('qc-table'));
  /* Row click → report detail modal
     (bound to the table, not the tbody: sorting replaces the tbody node
     via cloneNode/replaceChild, which would otherwise drop a listener
     attached directly to the old tbody element) */
  document.getElementById('measure-table').addEventListener('dblclick', handleRowClickForDetail);
  document.getElementById('qc-table').addEventListener('dblclick', handleRowClickForDetail);
  document.getElementById('detailCloseBtn')?.addEventListener('click', closeReportDetailModal);
  document.getElementById('reportDetailOverlay')?.addEventListener('click', e => {
    if (e.target.id === 'reportDetailOverlay') closeReportDetailModal();
  });
document.querySelector('.detail-modal')?.addEventListener('click', e => {
    const img = e.target.closest('.detail-image-thumb img');
    if (img && img.getAttribute('src')) openImageLightbox(img.getAttribute('src'));
});
  document.querySelectorAll('.detail-tab').forEach(tab => {
    tab.addEventListener('click', () => switchDetailTab(tab.dataset.tab));
  });
  document.getElementById('imageLightboxClose')?.addEventListener('click', closeImageLightbox);
  document.getElementById('imageLightbox')?.addEventListener('click', e => {
    if (e.target.id === 'imageLightbox') closeImageLightbox();
  });
  document.addEventListener('keydown', e => {
    if (e.key !== 'Escape') return;
    const lb = document.getElementById('imageLightbox');
    if (lb && lb.classList.contains('open')) closeImageLightbox();
    else closeReportDetailModal();
  });
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
  let reloadSeconds = 600;
  reloadTimerInterval = setInterval(() => {
    if (!autoReloadEnabled) return;
    const overlay = document.getElementById('reportDetailOverlay');
    if (overlay && overlay.classList.contains('open')) {
      const t = document.getElementById('reloadTimer');
      if (t) t.textContent = 'Auto Reload: PAUSED (report open)';
      return;
    }
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
    if (autoReloadEnabled) maybeStartReloadTimer();
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
const MEASUREMENT_REQUEST_TYPES = {
  1: 'PSDG',
  2: 'PSO',
  3: 'ASOP',
  4: 'COMM',
  5: 'OTHER'
};
function getMeasurementRequestTypeName(id){
  return MEASUREMENT_REQUEST_TYPES[id] || '';
}
function fetchMeasureReworkDetails(reportId){
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
// Twister equivalent of fetchMeasureReworkDetails above: instead of the
// remote Hipster job/notes API, runs the local fileinfo.exe lookup (the
// same one used for the EVM Data tab) and pulls its "notes" field, so
// Twister reports with rework history also get something to show in the
// Rework Details column / Rework Notes field.
function fetchTwisterReworkNotes(reportId, techId, teamNumber, locationName, stateLabel, source){
  const isQc = source === 'qc';
  const isFixedFolder = isQc
    ? /^Ready For QC/i.test(stateLabel || '')
    : (stateLabel === 'Ready To Measure');
  if (!isFixedFolder && (!techId || !teamNumber)) return Promise.resolve('');
  const qs = new URLSearchParams({
    reportId: String(reportId),
    techId: String(techId || ''),
    teamNumber: String(teamNumber || ''),
    location: String(locationName || ''),
    state: String(stateLabel || ''),
    source: String(source || 'measure')
  });
  return fetch(`/api/file-info?${qs.toString()}`)
    .then(r => r.json().catch(() => ({ found: false })))
    .then(data => {
      if (!data || !data.found) return '';
      let parsed = null;
      try { parsed = JSON.parse(data.output || '{}'); } catch { parsed = null; }
      return parsed?.notes || '';
    })
    .catch(() => '');
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
      let sec=parseInt(td.dataset.seconds||'0',10); sec++; td.dataset.seconds=sec; td.dataset.sort=sec;
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
      let sec=parseInt(td.dataset.seconds||'0',10); sec--; td.dataset.seconds=sec; td.dataset.sort=sec;
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
  let visibleLate=0,visibleTotal=0,visibleRTM=0,visibleBM=0,visibleRFQC=0,visibleBQC=0;
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
      const dueCell=row.cells[row.cells.length-1];
      if(dueCell&&dueCell.style.color==='red')visibleLate++;
      if(prefix==='m' && row.cells.length>=5){
        const stateText=row.cells[3].textContent.trim();
        if(stateText.includes('Being Measured')){
          visibleBM++;
          if(!isTrain){
            const username=row.cells[2].textContent.trim();
            if(username) visibleBeingMeasuredUsernames.set(username,(visibleBeingMeasuredUsernames.get(username)||0)+1);
          }
        } else if(stateText.includes('Ready To Measure')){
          visibleRTM++;
        }
      } else if(prefix==='q' && row.cells.length>=3){
        const stateText=row.cells[2].textContent.trim();
        if(stateText.includes('Ready For QC')) visibleRFQC++;
        else if(/Being Qced/i.test(stateText)) visibleBQC++;
      }
    }
  });
  const fc=document.getElementById(`${prefix}-fileCount`);
  if(fc)fc.innerHTML=`Reports (${visibleTotal})`;
  const pt=document.getElementById(`${prefix}-statLate`);
  const pn=document.getElementById(`${prefix}-statTotal`);
  if(pt)pt.textContent=`Due: ${visibleLate}`;
  if(pn)pn.textContent=`Total: ${visibleTotal}`;
  if(prefix==='m'){
    const prtm=document.getElementById('m-statRTM');
    const pbm=document.getElementById('m-statBM');
    if(prtm){prtm.textContent=`RTM: ${visibleRTM}`;prtm.classList.toggle('stat-pill-filter-active',searchValue==='ready to measure');}
    if(pbm){pbm.textContent=`BM: ${visibleBM}`;pbm.classList.toggle('stat-pill-filter-active',searchValue==='being measured');}
    renderDuplicateUsernameAlerts(visibleBeingMeasuredUsernames);
  } else {
    const prfqc=document.getElementById('q-statRFQC');
    const pbqc=document.getElementById('q-statBQC');
    if(prfqc){prfqc.textContent=`RFQC: ${visibleRFQC}`;prfqc.classList.toggle('stat-pill-filter-active',searchValue==='ready for qc');}
    if(pbqc){pbqc.textContent=`BQC: ${visibleBQC}`;pbqc.classList.toggle('stat-pill-filter-active',searchValue==='being qced');}
  }
}
/* ── buildTimeCells ── */
function formatElapsedHuman(totalSeconds){
  if (isNaN(totalSeconds)) return '';
  const totalMinutes = Math.floor(totalSeconds / 60);
  if (totalMinutes < 1) return 'Less than a minute';
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (hours <= 0) return `${minutes} minute${minutes === 1 ? '' : 's'}`;
  if (minutes === 0) return `${hours} hour${hours === 1 ? '' : 's'}`;
  return `${hours} hour${hours === 1 ? '' : 's'} and ${minutes} minute${minutes === 1 ? '' : 's'}`;
}
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
  const elapsedCell=`<td class="elapsed" data-seconds="${elapsedAttr}" data-sort="${isNaN(elapsedSec)?'':elapsedSec}" ${elapsedStyle}>${eh}:${em}:${es}</td>`;
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
  const dueCell=`<td class="due" data-seconds="${dueAttr}" data-sort="${dueAttr}" style="color:${dc};">${dd}</td>`;
  return{elapsedCell,dueCell};
}
/* ============================================================================
   REPORT DETAIL MODAL
   ============================================================================ */
function highlightRow(tr){
  tr.closest('tbody')?.querySelectorAll('tr.row-detail-active').forEach(row => row.classList.remove('row-detail-active'));
  tr.classList.add('row-detail-active');
}
function handleRowClickForDetail(e){
  const tr = e.target.closest('tr[data-detail-key]');
  if (!tr) return;
  const key = tr.dataset.detailKey;
  const details = rowDetailsStore[key];
  if (!details) return;
  highlightRow(tr);
  openReportDetailModal(details);
}
function detailRow(label, value, color){
  if (value === undefined || value === null || value === '') return '';
  const style = color ? ` style="color:${color};"` : '';
  return `<div class="detail-row"><div class="detail-label">${escapeHtml(label)}</div><div class="detail-value"${style}>${value}</div></div>`;
}
function lockModalHeightToOverview(){
  const overlay = document.getElementById('reportDetailOverlay');
  const modalEl = overlay?.querySelector('.detail-modal');
  const overviewPanel = document.getElementById('detailPanelOverview');
  const evmPanel = document.getElementById('detailPanelEvm');
  const historyPanel = document.getElementById('detailPanelHistory');
  if (!modalEl || !overviewPanel) return;
  // Measure Overview's natural height regardless of which tab is currently
  // shown, so images loading in while the user is on another tab doesn't
  // resize the modal out from under them.
  const wasOverviewActive = overviewPanel.classList.contains('active');
  const wasEvmActive = evmPanel?.classList.contains('active');
  const wasHistoryActive = historyPanel?.classList.contains('active');
  if (!wasOverviewActive) {
    evmPanel?.classList.remove('active');
    historyPanel?.classList.remove('active');
    overviewPanel.classList.add('active');
  }
  modalEl.style.height = 'auto';
  const naturalHeight = modalEl.offsetHeight;
  modalEl.style.height = naturalHeight + 'px';
  if (!wasOverviewActive) {
    overviewPanel.classList.toggle('active', false);
    if (wasEvmActive) evmPanel?.classList.add('active');
    if (wasHistoryActive) historyPanel?.classList.add('active');
  }
}
function switchDetailTab(tabName){
  document.querySelectorAll('.detail-tab').forEach(tab => {
    const isActive = tab.dataset.tab === tabName;
    tab.classList.toggle('active', isActive);
    tab.setAttribute('aria-selected', String(isActive));
  });
  document.getElementById('detailPanelOverview')?.classList.toggle('active', tabName === 'overview');
  document.getElementById('detailPanelEvm')?.classList.toggle('active', tabName === 'evm');
  document.getElementById('detailPanelHistory')?.classList.toggle('active', tabName === 'history');
  const body = document.getElementById('detailModalBody');
  if (body) body.scrollTop = 0;
}
function openReportDetailModal(details){
  const overlay = document.getElementById('reportDetailOverlay');
  const body    = document.getElementById('detailPanelOverview');
  const title   = document.getElementById('detailModalTitle');
  const sub     = document.getElementById('detailModalSubtitle');
  if (!overlay || !body) return;
  const typeLabel = details.isTraining ? 'Training' : 'Live';
  title.innerHTML = `Report #${details.reportID}`;
  sub.innerHTML = `<div id="detailFolderName" class="detail-folder-name"></div>`;
  const historyHtml = (details.history && details.history.length)
    ? `<div class="detail-timeline">${details.history.map(h => `
        <div class="detail-timeline-item">
          <span class="detail-timeline-dot"></span>
          <div class="detail-timeline-text">
            <div class="detail-timeline-desc">${escapeHtml(h.description || '')}</div>
            <div class="detail-timeline-time">${h.stateTime ? new Date(h.stateTime).toLocaleString() : ''}</div>
          </div>
        </div>`).join('')}</div>`
    : `<div class="detail-empty">No history available</div>`;
  const stateTimeDate = details.stateTime ? parseServerUtc(details.stateTime) : new Date(NaN);
  const elapsedSec = !isNaN(stateTimeDate.getTime())
    ? Math.max(0, Math.round((Date.now() - stateTimeDate.getTime()) / 1000))
    : NaN;
  const elapsedText = !isNaN(elapsedSec) ? formatElapsedHuman(elapsedSec) : '';
  let elapsedColor = '';
  if (!isNaN(elapsedSec)) {
    if (elapsedSec >= 10800 && !details.isTraining) elapsedColor = 'red';
    else if (elapsedSec >= 7200) elapsedColor = 'orangered';
    else if (elapsedSec >= 3600) elapsedColor = 'DarkOrange';
  }
  const dueDateObj = details.dueDate ? parseServerUtc(details.dueDate) : new Date(NaN);
  const dueSec = !isNaN(dueDateObj.getTime())
    ? Math.floor((dueDateObj.getTime() - Date.now()) / 1000)
    : NaN;
  const dueDateText = !isNaN(dueDateObj.getTime()) ? dueDateObj.toLocaleString() : '';
  let dueColor = '';
  if (!isNaN(dueSec)) {
    if (dueSec < 3600) dueColor = 'red';
    else if (dueSec < 7200) dueColor = 'orangered';
    else if (dueSec < 10800) dueColor = 'DarkOrange';
  }
  const isTwisterFileInfo = (details.source==='measure' || details.source==='qc') && details.appLabel==='Twister';
  const isHipster = details.appLabel === 'Hipster';
  const hasReworkCount = !!(details.reworkCountHtml && String(details.reworkCountHtml).trim());
  const fileTypeLabel = details.pmText ? 'PM' : 'Fresh';
  const rawMeasurementItems = details.measurementItems || '';
  const measurementItemsBase = rawMeasurementItems.replace(/\s*\[PM\]\s*$/, '');
  const measurementItemsHtml = escapeHtml(measurementItemsBase).replace(/\n/g,'<br>');
  let reworkNotesInitial = 'n/a';
  let reworkNotesIsPlaceholder = true;
  const reworkCountNum = Number(details.reworkCount) || 0;
  const reworkNotesColor = reworkCountNum >= 1 ? 'orangered' : '';
  if (hasReworkCount) {
    if (isTwisterFileInfo) {
      if (details.reworkHtml) {
        reworkNotesInitial = details.reworkHtml;
        reworkNotesIsPlaceholder = false;
      } else {
        reworkNotesInitial = 'Loading…';
        reworkNotesIsPlaceholder = true;
      }
    } else if (isHipster) {
      if (details.reworkHtml) {
        reworkNotesInitial = details.reworkHtml;
        reworkNotesIsPlaceholder = false;
      } else {
        reworkNotesInitial = '(unable to fetch Hipster operator notes)';
        reworkNotesIsPlaceholder = true;
      }
    }
  }
  const valueOrNA = (html) => {
    const str = (html === null || html === undefined) ? '' : String(html);
    return str.trim() ? str : '<span class="detail-value-placeholder">n/a</span>';
  };
  body.innerHTML = `
    <div class="detail-section">
      <div class="detail-columns">
        <div class="detail-column">
          <div class="detail-row"><div class="detail-label">Report ID</div><div class="detail-value">${details.reportID}</div></div>
          <div class="detail-row"><div class="detail-label">State</div><div class="detail-value">${valueOrNA(escapeHtml(details.stateLabel || ''))}</div></div>
          ${details.source==='qc' ? `<div class="detail-row"><div class="detail-label">Measured By</div><div class="detail-value">${valueOrNA(escapeHtml(details.measuredTech || ''))}</div></div>` : ''}
          <div class="detail-row"><div class="detail-label">${details.source==='qc' ? 'QC' : 'Tech'}</div><div class="detail-value">${valueOrNA(escapeHtml(details.userName || ''))}</div></div>
          <div class="detail-row"><div class="detail-label">${details.source==='qc' ? 'QC ID' : 'Tech ID'}</div><div class="detail-value">${valueOrNA(escapeHtml(details.techUsername || ''))}</div></div>
          <div class="detail-row"><div class="detail-label">Team</div><div class="detail-value">${valueOrNA(escapeHtml(details.team || ''))}</div></div>
          <div class="detail-row"><div class="detail-label">Location</div><div class="detail-value">${valueOrNA(escapeHtml(details.locationName || ''))}</div></div>
          <div class="detail-row"><div class="detail-label">Rework Count</div><div class="detail-value">${valueOrNA(details.reworkCountHtml)}</div></div>
          <div class="detail-row"><div class="detail-label">Rework Notes</div><div class="detail-value${reworkNotesIsPlaceholder ? ' detail-value-placeholder' : ''}"${reworkNotesColor ? ` style="color:${reworkNotesColor};"` : ''} id="detailReworkNotesValue">${reworkNotesInitial}</div></div>
          <div class="detail-row"><div class="detail-label">Reject History</div><div class="detail-value">${valueOrNA(details.rejectionHistoryHtml)}</div></div>
        </div>
        <div class="detail-column">
          <div class="detail-row"><div class="detail-label">Due Date</div><div class="detail-value"${dueColor ? ` style="color:${dueColor};"` : ''}>${valueOrNA(dueDateText)}</div></div>
          <div class="detail-row"><div class="detail-label">Last Modified</div><div class="detail-value">${valueOrNA(!isNaN(stateTimeDate.getTime()) ? stateTimeDate.toLocaleString() : '')}</div></div>
          <div class="detail-row"><div class="detail-label">Elapsed Time</div><div class="detail-value"${elapsedColor ? ` style="color:${elapsedColor};"` : ''}>${valueOrNA(elapsedText)}</div></div>
          <div class="detail-row"><div class="detail-label">Order Type</div><div class="detail-value">${valueOrNA(typeLabel)}</div></div>
          <div class="detail-row"><div class="detail-label">Product Type</div><div class="detail-value">${valueOrNA(escapeHtml(details.primaryProductName || ''))}</div></div>
          <div class="detail-row"><div class="detail-label">Delivery Type</div><div class="detail-value">${valueOrNA(escapeHtml(details.deliveryProductName || ''))}</div></div>
          <div class="detail-row"><div class="detail-label">Report Details</div><div class="detail-value">${valueOrNA(escapeHtml(getMeasurementRequestTypeName(details.measurementRequestTypeID)))}</div></div>
          <div class="detail-row"><div class="detail-label">Measurement Items</div><div class="detail-value">${valueOrNA(measurementItemsHtml)}</div></div>
        </div>
      </div>
      ${details.source==='qc' ? '' : detailRow('Measured By', escapeHtml(details.measuredTech || ''))}
    </div>
  `;
  const footerMeta = document.getElementById('detailFooterMeta');
  if (footerMeta) {
    footerMeta.innerHTML = valueOrNA(
      details.appLabel ? `${escapeHtml(details.appLabel)} · ${fileTypeLabel} file` : ''
    );
  }
  const explorerBtn = document.getElementById('detailExplorerBtn');
  if (explorerBtn) {
    const lat = Number(details.latitude);
    const lon = Number(details.longitude);
    const hasCoords = Number.isFinite(lat) && Number.isFinite(lon);
    explorerBtn.disabled = !hasCoords;
    explorerBtn.title = hasCoords ? '' : 'No coordinates available';
    explorerBtn.onclick = hasCoords
      ? () => window.open(`https://apps.eagleview.com/cloudexplorer#lat=${lat}&lon=${lon}&zoom=20&view=O`, '_blank', 'noopener')
      : null;
  }
  const gmapsBtn = document.getElementById('detailGmapsBtn');
  if (gmapsBtn) {
    const addressParts = [details.address, details.city, details.addressState, details.zip].filter(Boolean);
    const hasAddress = addressParts.length > 0;
    gmapsBtn.disabled = !hasAddress;
    gmapsBtn.title = hasAddress ? '' : 'No address available';
    gmapsBtn.onclick = hasAddress
      ? () => window.open(`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(addressParts.join(', '))}`, '_blank', 'noopener')
      : null;
  }
  const historyPanel = document.getElementById('detailPanelHistory');
  if (historyPanel) {
    historyPanel.innerHTML = `
    <div class="detail-section">
      ${historyHtml}
    </div>
  `;
  }
  const evmTabBtn = document.getElementById('detailTabEvm');
  const evmPanel  = document.getElementById('detailPanelEvm');
  if (evmTabBtn) evmTabBtn.classList.toggle('detail-tab-hidden', !isTwisterFileInfo);
  if (evmPanel) {
    evmPanel.innerHTML = isTwisterFileInfo ? `
    <div class="detail-section">
      <div class="detail-row"><div class="detail-label">Roof</div><div class="detail-value" id="detailRoofValue">Loading…</div></div>
      <div class="detail-row"><div class="detail-label">Penetration</div><div class="detail-value" id="detailPenetrationValue">Loading…</div></div>
      <div class="detail-row"><div class="detail-label">Wall</div><div class="detail-value" id="detailWallValue">Loading…</div></div>
      <div class="detail-row"><div class="detail-label">${details.source==='qc' ? 'QC Time' : 'Tech Time'}</div><div class="detail-value" id="detailTechTimeValue">Loading…</div></div>
      <div class="detail-row"><div class="detail-label">Last QC</div><div class="detail-value" id="detailLastQcValue">Loading…</div></div>
      <div class="detail-row"><div class="detail-label">Notes</div><div class="detail-value" id="detailEvmNotesValue">Loading…</div></div>
      <div class="detail-row"><div class="detail-label">Rollback</div><div class="detail-value" id="detailRollbackValue">Loading…</div></div>
      <div class="detail-row" style="border-bottom:1px solid var(--border-light);"><div class="detail-label">Checkpoint</div><div class="detail-value" id="detailCheckpointValue">Loading…</div></div>
    </div>
  ` : '';
  }
  const imagesGrid = document.getElementById('detailImagesGrid');
  const imagesStatus = document.getElementById('detailImagesStatus');
  if (imagesGrid) imagesGrid.innerHTML = buildImageSkeletons();
  if (imagesStatus) imagesStatus.textContent = 'Searching…';
  switchDetailTab('overview');
  // Size the modal to fit the Overview tab's content with no internal
  // scrollbar, then lock that height so switching to EVM Data/History
  // reuses it (those panels scroll within it instead of resizing the modal).
  lockModalHeightToOverview();
  overlay.classList.add('open');
  overlay.setAttribute('aria-hidden', 'false');
  if (isTwisterFileInfo) {
    // Kick off a broad image search by report ID immediately instead of
    // waiting for File Info to resolve the exact .evm/folder name first —
    // that SMB lookup + fileinfo.exe run was serializing the two calls and
    // made the images appear noticeably late. loadFileInfo will refine the
    // image search with the exact folder name once it resolves; the token
    // check inside loadReportImages ensures only the latest result renders.
    loadReportImages(details.reportID, details.locationName);
    // Rework Notes may already be populated from the table build
    // (details.reworkHtml) — only ask loadFileInfo to fetch/overwrite it
    // if we don't already have a value; the EVM Data fields still load
    // either way.
    const needsReworkNotesFetch = hasReworkCount && !details.reworkHtml;
    loadFileInfo(details.reportID, details.techUsername, details.teamNumber, details.locationName, details.stateLabel, details.source, needsReworkNotesFetch);
  } else {
    loadReportImages(details.reportID, details.locationName);
  }
}
/* ----------------------------------------------------------------------
   Row right-click context menu
   Copy Report ID / Copy Row Details / Overview / Gmaps / Explorer.
   Right-click anywhere that isn't a data row is suppressed entirely
   (no native browser/WebView2 context menu).
   ---------------------------------------------------------------------- */
function cellVisibleText(td){
  // Render <br> as a separator instead of letting textContent collapse
  // multi-line cell content (rework/reject history, etc.) together.
  const clone = td.cloneNode(true);
  clone.querySelectorAll('br').forEach(br => br.replaceWith('; '));
  return clone.textContent.replace(/\s+/g, ' ').trim();
}
function csvEscape(value){
  const str = String(value == null ? '' : value);
  return /[",\r\n]/.test(str) ? `"${str.replace(/"/g, '""')}"` : str;
}
function exportTableToCsv(tableId){
  const table = document.getElementById(tableId);
  if (!table) return;
  const headerCells = [...(table.tHead?.rows[0]?.cells || [])];
  const visibleColIdx = headerCells
    .map((th, i) => ({ th, i }))
    .filter(({ th }) => !th.classList.contains('hidden-column'))
    .map(({ i }) => i);
  if (!visibleColIdx.length) return;
  const headerLine = visibleColIdx
    .map(i => csvEscape(headerCells[i].textContent.replace(/[↑↓]/g, '').trim()))
    .join(',');
  const rows = [...table.tBodies].flatMap(tb => [...tb.rows])
    .filter(row => row.style.display !== 'none' && !row.classList.contains('skeleton-row'));
  const dataLines = rows.map(row =>
    visibleColIdx.map(i => csvEscape(cellVisibleText(row.cells[i]))).join(',')
  );
  const csvContent = [headerLine, ...dataLines].join('\r\n');
  const blob = new Blob(['\uFEFF' + csvContent], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  const stamp = new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19);
  a.href = url;
  a.download = `${tableId}_${stamp}.csv`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}
function buildRowDetailsText(tr){
  if (!tr) return '';
  return [...tr.cells]
    .filter(td => !td.classList.contains('hidden-column'))
    .map(cellVisibleText)
    .join('\t');
}
async function copyTextToClipboard(text){
  if (!text) return false;
  try {
    await navigator.clipboard.writeText(text);
    return true;
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
      return true;
    } catch (fallbackErr) {
      console.error('copyTextToClipboard failed:', fallbackErr);
      return false;
    }
  }
}
(function initRowContextMenu(){
  const menu = document.createElement('div');
  menu.className = 'row-context-menu';
  menu.setAttribute('role', 'menu');
  menu.setAttribute('aria-hidden', 'true');
  const ITEMS = [
    { key: 'copyId',    label: '⧉ Copy Report ID' },
    { key: 'copyRow',    label: '⎘ Copy Row Details' },
    { sep: true },
    { key: 'overview',  label: '▤ Overview' },
    { key: 'gmaps',     label: '📍 Gmaps' },
    { key: 'explorer',  label: '🛰️ Explorer' },
    { sep: true },
    { key: 'refresh',   label: '↻ Refresh' }
  ];
  ITEMS.forEach(item => {
    if (item.sep) {
      const sep = document.createElement('div');
      sep.className = 'row-context-menu-sep';
      menu.appendChild(sep);
      return;
    }
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'row-context-menu-item';
    btn.dataset.action = item.key;
    btn.textContent = item.label;
    menu.appendChild(btn);
  });
  document.body.appendChild(menu);
  let activeDetails = null;
  let activeTr = null;
  function closeMenu(){
    menu.classList.remove('row-context-menu-open');
    menu.setAttribute('aria-hidden', 'true');
    activeDetails = null;
    activeTr = null;
  }
  function flashLabel(btn, tempLabel){
    const original = btn.textContent;
    btn.textContent = tempLabel;
    setTimeout(() => { closeMenu(); btn.textContent = original; }, 450);
  }
  function openMenu(x, y, details, tr){
    activeDetails = details;
    activeTr = tr;
    // Row-specific items (and their separators) only make sense when the
    // click actually landed on a data row; a right-click on empty space
    // (background, header, etc.) should offer Refresh only.
    const isRowContext = !!details;
    menu.querySelectorAll('.row-context-menu-item, .row-context-menu-sep').forEach(el => {
      const isRefresh = el.dataset.action === 'refresh';
      el.style.display = (isRowContext || isRefresh) ? '' : 'none';
    });
    if (isRowContext) {
      const lat = Number(details.latitude);
      const lon = Number(details.longitude);
      const hasCoords = Number.isFinite(lat) && Number.isFinite(lon);
      const addressParts = [details.address, details.city, details.addressState, details.zip].filter(Boolean);
      const hasAddress = addressParts.length > 0;
      const gmapsBtn = menu.querySelector('[data-action="gmaps"]');
      const explorerBtn = menu.querySelector('[data-action="explorer"]');
      if (gmapsBtn) { gmapsBtn.disabled = !hasAddress; gmapsBtn.title = hasAddress ? '' : 'No address available'; }
      if (explorerBtn) { explorerBtn.disabled = !hasCoords; explorerBtn.title = hasCoords ? '' : 'No coordinates available'; }
    }
    // Render off-screen first to measure, then clamp inside the viewport.
    menu.style.left = '0px';
    menu.style.top  = '0px';
    menu.classList.add('row-context-menu-open');
    menu.setAttribute('aria-hidden', 'false');
    const menuW = menu.offsetWidth;
    const menuH = menu.offsetHeight;
    const clampedX = Math.min(x, window.innerWidth  - menuW - 6);
    const clampedY = Math.min(y, window.innerHeight - menuH - 6);
    menu.style.left = Math.max(6, clampedX) + 'px';
    menu.style.top  = Math.max(6, clampedY) + 'px';
  }
  menu.addEventListener('click', e => {
    const btn = e.target.closest('.row-context-menu-item');
    if (!btn || btn.disabled) return;
    if (btn.dataset.action !== 'refresh' && !activeDetails) return;
    const details = activeDetails;
    const tr = activeTr;
    switch (btn.dataset.action) {
      case 'copyId':
        copyTextToClipboard(String(details.reportID ?? ''));
        flashLabel(btn, 'Copied!');
        return;
      case 'copyRow':
        copyTextToClipboard(buildRowDetailsText(tr));
        flashLabel(btn, 'Copied!');
        return;
      case 'overview':
        if (tr) highlightRow(tr);
        openReportDetailModal(details);
        break;
      case 'gmaps': {
        const addressParts = [details.address, details.city, details.addressState, details.zip].filter(Boolean);
        if (addressParts.length) window.open(`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(addressParts.join(', '))}`, '_blank', 'noopener');
        break;
      }
      case 'explorer': {
        const lat = Number(details.latitude);
        const lon = Number(details.longitude);
        if (Number.isFinite(lat) && Number.isFinite(lon)) window.open(`https://apps.eagleview.com/cloudexplorer#lat=${lat}&lon=${lon}&zoom=20&view=O`, '_blank', 'noopener');
        break;
      }
      case 'refresh':
        window.location.reload();
        return;
    }
    closeMenu();
  });
  document.addEventListener('contextmenu', e => {
    // Suppress the native context menu everywhere. Right-clicking an actual
    // data row shows the full menu; right-clicking anywhere else shows a
    // Refresh-only menu instead of nothing.
    e.preventDefault();
    const tr = e.target.closest('tr[data-detail-key]');
    const details = tr ? rowDetailsStore[tr.dataset.detailKey] : null;
    if (!details) {
      document.querySelectorAll('tr.row-detail-active').forEach(row => row.classList.remove('row-detail-active'));
      openMenu(e.clientX, e.clientY, null, null);
      return;
    }
    highlightRow(tr);
    openMenu(e.clientX, e.clientY, details, tr);
  });
  document.addEventListener('click', e => {
    // Clicks inside the context menu manage the row highlight themselves
    // (e.g. "Overview" re-highlights the row it opens), so leave those alone.
    if (menu.contains(e.target)) return;
    closeMenu();
    document.querySelectorAll('tr.row-detail-active').forEach(row => row.classList.remove('row-detail-active'));
  });
  document.addEventListener('scroll', closeMenu, true);
  window.addEventListener('resize', closeMenu);
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape') closeMenu();
  });
})();
function buildImageSkeletons(count = 5){
  return Array.from({ length: count }).map(() => `<div class="detail-image-thumb detail-image-skel"></div>`).join('');
}
function getEvmBaseName(filePath){
  if (!filePath) return '';
  const parts = String(filePath).split(/[\\\/]/);
  const fileName = parts[parts.length - 1] || '';
  return fileName.replace(/\.evm$/i, '');
}
function loadReportImages(reportId, locationName, folderName){
  const myToken = ++imageLoadToken;
  const grid       = document.getElementById('detailImagesGrid');
  const status     = document.getElementById('detailImagesStatus');
  const folderNameEl = document.getElementById('detailFolderName');
  if (!grid) return;
  const qs = new URLSearchParams({ reportId: String(reportId), location: locationName || '' });
  if (folderName) qs.set('folderName', folderName);
  fetch(`/api/images?${qs.toString()}`)
    .then(r => r.json().catch(() => ({ found: false, error: 'Unexpected response from image search' })))
    .then(data => {
      if (myToken !== imageLoadToken) return;
      if (data && data.found && Array.isArray(data.images) && data.images.length) {
        if (status) status.textContent = '';
        if (folderNameEl) folderNameEl.textContent = data.folder || '';
        grid.innerHTML = data.images.map(src => `
          <div class="detail-image-thumb">
            <img src="${src}" alt="Report image" loading="eager" decoding="async" fetchpriority="high" onerror="this.closest('.detail-image-thumb').classList.add('img-error')">
          </div>`).join('');
      } else if (data && data.found) {
        if (status) status.textContent = '';
        if (folderNameEl) folderNameEl.textContent = data.folder || '';
        grid.innerHTML = `<div class="detail-images-empty">No images found in the Images subfolder.</div>`;
      } else {
        if (status) status.textContent = '';
        if (folderNameEl) folderNameEl.textContent = '';
        grid.innerHTML = `<div class="detail-images-empty">${escapeHtml((data && (data.message || data.error)) || 'No matching report folder found.')}</div>`;
      }
      lockModalHeightToOverview();
    })
    .catch(() => {
      if (myToken !== imageLoadToken) return;
      if (status) status.textContent = '';
      grid.innerHTML = `<div class="detail-images-empty">Couldn't reach the archive share. Check your network/VPN connection.</div>`;
      lockModalHeightToOverview();
    });
}
function loadFileInfo(reportId, techUsername, teamNumber, locationName, stateLabel, source, hasReworkCount){
  const myToken = ++fileInfoLoadToken;
  const roofEl     = document.getElementById('detailRoofValue');
  const penEl      = document.getElementById('detailPenetrationValue');
  const wallEl     = document.getElementById('detailWallValue');
  const techTimeEl = document.getElementById('detailTechTimeValue');
  const lastQcEl   = document.getElementById('detailLastQcValue');
  const evmNotesEl = document.getElementById('detailEvmNotesValue');
  const rollbackEl   = document.getElementById('detailRollbackValue');
  const checkpointEl = document.getElementById('detailCheckpointValue');
  const notesEl    = document.getElementById('detailReworkNotesValue');
  if (!roofEl) return;
  const setValue = (el, text, isPlaceholder) => {
    if (!el) return;
    el.textContent = text;
    el.classList.toggle('detail-value-placeholder', !!isPlaceholder);
  };
  const fieldEls = [roofEl, penEl, wallEl, techTimeEl, lastQcEl, evmNotesEl, rollbackEl, checkpointEl];
  const setFields = (text, isPlaceholder) => fieldEls.forEach(el => setValue(el, text, isPlaceholder));
  // Rework Notes shows a shorter, friendlier form of the searched-path than
  // the raw box path (data.filePath):
  //   "[TeamLead]\New"            -> "TeamLead"
  //   "{tech/qc box}\InProgress"  -> "{tech/qc box}"
  const shortenPathForNotes = (path) => {
    if (!path) return '';
    let s = String(path);
    s = s.replace(/^\[(.+?)\]\\New$/i, '$1');
    s = s.replace(/\\InProgress$/i, '');
    return s;
  };
  const isQc = source === 'qc';
  // The .evm's location depends on source + state:
  //  Measure — Being Measured: tech's own InProgress box (tech ID + team).
  //          — Ready To Measure: fixed "[TeamLead]\New".
  //  QC — Being Qced: the QC's own InProgress box (QC ID + QC team).
  //     — Ready For QC: fixed "2_Measured\QC\[TeamLead]\New".
  // "Fixed folder" states don't need a per-tech/QC box, so only require an
  // ID + team for the "in someone's box" states.
  const isFixedFolder = isQc
    ? /^Ready For QC/i.test(stateLabel || '')
    : (stateLabel === 'Ready To Measure');
  if (!isFixedFolder && (!techUsername || !teamNumber)) {
    const message = (isQc ? 'QC ID' : 'Tech ID') + ' or team not available for this report yet.';
    setFields(message, true);
    if (hasReworkCount) setValue(notesEl, message, true);
    loadReportImages(reportId, locationName);
    return;
  }
  setFields('Loading…', true);
  const qs = new URLSearchParams({
    reportId: String(reportId),
    techId: String(techUsername || ''),
    teamNumber: String(teamNumber || ''),
    location: String(locationName || ''),
    state: String(stateLabel || ''),
    source: String(source || 'measure')
  });
  fetch(`/api/file-info?${qs.toString()}`)
    .then(r => r.json().catch(() => ({ found: false, error: 'Unexpected response from file info lookup' })))
    .then(data => {
      if (myToken !== fileInfoLoadToken) return;
      if (data && data.found) {
        let parsed = null;
        try { parsed = JSON.parse(data.output || '{}'); } catch { parsed = null; }
        if (parsed) {
          const userTimes = parsed.user_times || {};
          const techKey = techUsername
            ? Object.keys(userTimes).find(k => k.toUpperCase().startsWith(String(techUsername).toUpperCase()))
            : null;
          const techTotalTime = techKey ? (userTimes[techKey].total_time || '') : '';
          setValue(roofEl, parsed.roof ?? '', false);
          setValue(penEl, parsed.penetration ?? '', false);
          setValue(wallEl, parsed.wall ?? '', false);
          setValue(techTimeEl, techTotalTime, false);
          setValue(lastQcEl, parsed.qc || 'n/a', !parsed.qc);
          setValue(evmNotesEl, parsed.notes || 'n/a', !parsed.notes);
          setValue(rollbackEl, data.rollback || 'n/a', !data.rollback);
          setValue(checkpointEl, data.checkpoint || 'n/a', !data.checkpoint);
          if (hasReworkCount) {
            if (parsed.notes) setValue(notesEl, parsed.notes, false);
            else setValue(notesEl, '(no notes)', true);
          }
        } else {
          const raw = data.output && data.output.trim() ? data.output : '(no output)';
          setValue(roofEl, '', false);
          setValue(penEl, '', false);
          setValue(wallEl, '', false);
          setValue(techTimeEl, '', false);
          setValue(lastQcEl, 'n/a', true);
          setValue(evmNotesEl, raw, true);
          setValue(rollbackEl, data.rollback || 'n/a', !data.rollback);
          setValue(checkpointEl, data.checkpoint || 'n/a', !data.checkpoint);
          if (hasReworkCount) setValue(notesEl, '(unable to parse file info)', true);
        }
        // Twister's .evm filename (minus extension) is the exact archive
        // folder name, so go straight there instead of scanning the share.
        const evmBaseName = getEvmBaseName(data.filePath);
        loadReportImages(reportId, locationName, evmBaseName);
      } else {
        // "No rollback found" isn't useful on its own — show the short
        // two-level box path (e.g. "2027JHTCT79\InProgress") instead so the
        // person can see exactly where the .evm was expected to be.
        const shortPath = data && data.searchedPath;
        const notFoundMessage = shortPath
          ? `EVM not found in ${shortPath}`
          : ((data && (data.message || data.error)) || 'File info not available.');
        const notesNotFoundMessage = shortPath
          ? `EVM not found in ${shortenPathForNotes(shortPath)}`
          : notFoundMessage;
        setFields(notFoundMessage, true);
        if (hasReworkCount) setValue(notesEl, notesNotFoundMessage, true);
        // No filename to go on — fall back to the archive search by report ID.
        loadReportImages(reportId, locationName);
      }
    })
    .catch(() => {
      if (myToken !== fileInfoLoadToken) return;
      const message = "Couldn't reach the local file-info service.";
      setFields(message, true);
      if (hasReworkCount) setValue(notesEl, message, true);
      loadReportImages(reportId, locationName);
    });
}
function openImageLightbox(src){
  const lb  = document.getElementById('imageLightbox');
  const img = document.getElementById('imageLightboxImg');
  if (!lb || !img) return;
  img.src = src;
  lb.classList.add('open');
  lb.setAttribute('aria-hidden', 'false');
}
function closeImageLightbox(){
  const lb = document.getElementById('imageLightbox');
  if (!lb) return;
  lb.classList.remove('open');
  lb.setAttribute('aria-hidden', 'true');
  const img = document.getElementById('imageLightboxImg');
  if (img) img.src = '';
}
function closeReportDetailModal(){
  const overlay = document.getElementById('reportDetailOverlay');
  if (!overlay) return;
  overlay.classList.remove('open');
  overlay.setAttribute('aria-hidden', 'true');
  closeImageLightbox();
  imageLoadToken++;
  fileInfoLoadToken++;
  document.querySelectorAll('tr.row-detail-active').forEach(row => row.classList.remove('row-detail-active'));
}
/* ============================================================================
   MEASURE: MAIN DATA FETCH
   ============================================================================ */
let m_pendingFetches=0, m_fileCount=0;
(function measureMain(){
  fetch('https://api.cmh.platform-prod2.evinternal.net/operations-center/api/Team')
    .then(r=>r.ok?r.json():Promise.reject()).then(d=>({dictTeam:new Map(d.map(t=>[t.teamId,{name:t.name,teamNumber:t.teamNumber}]))}))
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
        const rowKey=`m-${item.reportID}-${m_fileCount}`;
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
          .then(({report,pmText,task,rejectedCounts,entries,user,mItems})=>
            fetch(`https://api.cmh.platform-prod2.evinternal.net/operations-center/api/TaskTrafficView/report/${item.reportID}`)
              .then(r=>r.ok?r.json():Promise.reject())
              .then(productInfo=>({report,pmText,task,rejectedCounts,entries,user,mItems,deliveryProductName:productInfo?.deliveryProductName??'',primaryProductName:productInfo?.primaryProductName??''}))
              .catch(()=>({report,pmText,task,rejectedCounts,entries,user,mItems,deliveryProductName:'',primaryProductName:''})))
          .then(({report,pmText,task,rejectedCounts,entries,user,mItems,deliveryProductName,primaryProductName})=>{
            const locationName=dictLocation.get(user[0]?.locationId)??'';
            const hasReworkHistory=[...rejectedCounts.keys()].some(type=>/rework/i.test(type));
            const isHipster=(mItems.measurementItems||[]).some(m=>/hipster/i.test(m.name||''));
            if(!hasReworkHistory){
              return{report,pmText,task,rejectedCounts,entries,user,mItems,reworkDetails:'',locationName,deliveryProductName,primaryProductName};
            }
            if(isHipster){
              return fetchMeasureReworkDetails(item.reportID)
                .then(reworkDetails=>({report,pmText,task,rejectedCounts,entries,user,mItems,reworkDetails,locationName,deliveryProductName,primaryProductName}));
            }
            // Twister with rework history — pull notes from the local
            // fileinfo.exe lookup instead of the Hipster job/notes API.
            const techId = user[0]?.techUsername ?? '';
            const teamNumber = dictTeam.get(user[0]?.teamId)?.teamNumber ?? '';
            const stateLabelForFileInfo = isRTM ? 'Ready To Measure' : 'Being Measured';
            return fetchTwisterReworkNotes(item.reportID, techId, teamNumber, locationName, stateLabelForFileInfo, 'measure')
              .then(reworkDetails=>({report,pmText,task,rejectedCounts,entries,user,mItems,reworkDetails,locationName,deliveryProductName,primaryProductName}));
          })
          .then(({report,pmText,task,rejectedCounts,entries,user,mItems,reworkDetails,locationName,deliveryProductName,primaryProductName})=>{
            const mText=(mItems.measurementItems||[]).map(m=>'*'+(m.name||'').replace(/\s+/g,'')).join('  ');
            const rowStateColor = isRTM?'var(--text-primary)':'var(--text-secondary)';
            const styleRejectedEntry=([type,count])=>{
              let color;
              if(count>=3)        color='red';
              else if(count===2)  color='orangered';
              else if(/rework/i.test(type)) color='orangered';
              else                color=rowStateColor;
              return `<span style="color:${color};white-space:nowrap;">${type} ${count}x</span>`;
            };
            const rejectedSuffix=[...rejectedCounts.entries()].map(styleRejectedEntry).join('<br>');
            const reworkTotalCount=[...rejectedCounts.entries()].filter(([type])=>/rework/i.test(type)).reduce((sum,[,count])=>sum+count,0);
            let reworkColor = 'var(--text-primary)';
            if(reworkTotalCount>=2)       reworkColor='red';
            else if(reworkTotalCount===1) reworkColor='orangered';
            const reworkDetailsColor = 'orangered';
            const reworkCountHtml=reworkTotalCount?`<span style="color:${reworkColor};">${reworkTotalCount}</span>`:'';
            const rejectionHistoryHtml=[...rejectedCounts.entries()].map(styleRejectedEntry).join('<br>');
            const reworkHtml=reworkTotalCount?`<span style="color:${reworkDetailsColor};">${escapeHtml(reworkDetails).replace(/\n/g,'<br>')}</span>`:escapeHtml(reworkDetails).replace(/\n/g,'<br>');
            const isHipsterErrorRow =
              /bellevue/i.test(locationName) ||
              /hipster/i.test(locationName)  ||
              /error/i.test(locationName);
            const siteTag = isHipsterErrorRow
              ? extractSiteTag(entries)
              : '';
            const appLabel = (mItems.measurementItems||[]).some(m=>/hipster/i.test(m.name||''))
              ? 'Hipster'
              : 'Twister';
            rowDetailsStore[rowKey]={
              reportID:item.reportID,
              pmText,
              isTraining,
              source:'measure',
              stateLabel:isRTM?'Ready To Measure':'Being Measured',
              appLabel,
              reworkCount:reworkTotalCount,
              userName:(user[0]?.userName??'')+siteTag,
              techUsername:user[0]?.techUsername??'',
              team:dictTeam.get(user[0]?.teamId)?.name??'',
              teamNumber:dictTeam.get(user[0]?.teamId)?.teamNumber??'',
              locationName,
              deliveryProductName,
              primaryProductName,
              measurementRequestTypeID:report.measurementRequestTypeID,
              latitude:report.latitude,
              longitude:report.longitude,
              address:report.address,
              city:report.city,
              addressState:report.state,
              zip:report.zip,
              measurementItems:(mItems.measurementItems||[]).map(m=>m.name).filter(Boolean).join('\n')+(pmText?' [PM]':''),
              stateTime:task.stateTime,
              dueDate:item.dueDate,
              rejectedSuffix,
              reworkCountHtml,
              rejectionHistoryHtml,
              reworkHtml,
              history:entries.map(e=>({description:e.description,stateTime:e.stateTime}))
                .sort((a,b)=>new Date(b.stateTime)-new Date(a.stateTime))
            };
            let row=`<tr data-type="${isTraining?'training':'live'}" data-detail-key="${rowKey}">
<td><span class="${isTraining?'badge-training':'badge-live'}">${isTraining?'Training':'Live'}</span></td>
<td>${item.reportID}</td>
<td>${user[0]?.userName??''}${siteTag}</td>
<td style="color:${isRTM?'var(--text-primary)':'var(--text-secondary)'};">${isRTM?'Ready To Measure':'Being Measured'}</td>
<td style="color:${isRTM?'var(--text-primary)':'var(--text-secondary)'};">${rejectedSuffix}</td>
<td>${reworkHtml}</td>
<td>${user[0]?.techUsername??''}</td>
<td>${dictTeam.get(user[0]?.teamId)?.name??''}</td>
<td>${locationName}</td>
<td>${appLabel}</td>
<td>${escapeHtml(primaryProductName||'')}</td>
<td>${escapeHtml(getMeasurementRequestTypeName(report.measurementRequestTypeID))}</td>`;
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
            if(m_pendingFetches===0){sortTableByColumn('measure-table',13,true);colorDuplicateMeasureUsernames();startDynamicTimers('m-data');m_tableReady=true;maybeStartReloadTimer();window.flashDueCellsNow&&window.flashDueCellsNow('m-data');}
          })
          .catch(err=>{
            console.error('measure report chain error:',err);
            m_pendingFetches=Math.max(0,m_pendingFetches-1);
            if(m_pendingFetches===0){sortTableByColumn('measure-table',13,true);colorDuplicateMeasureUsernames();startDynamicTimers('m-data');m_tableReady=true;maybeStartReloadTimer();window.flashDueCellsNow&&window.flashDueCellsNow('m-data');}
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
      // Safety net: if neither list returned any items, the per-row
      // completion above never runs, so the table would never be marked
      // ready and auto-reload would never arm. Mark it ready here instead.
      if(m_pendingFetches===0 && !m_tableReady){sortTableByColumn('measure-table',13,true);colorDuplicateMeasureUsernames();startDynamicTimers('m-data');m_tableReady=true;maybeStartReloadTimer();window.flashDueCellsNow&&window.flashDueCellsNow('m-data');}
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
    if(cells.length>=9&&cells[3].textContent.trim().includes('Being Measured')&&row.dataset.type!=='training'){
      const u=cells[2].textContent.trim(),t=cells[6].textContent.trim();
      if(u)uC.set(u,(uC.get(u)||0)+1); if(t)tC.set(t,(tC.get(t)||0)+1);
    }
  });
  rows.forEach(row=>{
    const cells=row.cells;
    if(cells.length>=9&&cells[3].textContent.trim().includes('Being Measured')&&row.dataset.type!=='training'){
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
    .then(r=>r.ok?r.json():Promise.reject()).then(d=>({dictTeam:new Map(d.map(t=>[t.teamId,{name:t.name,teamNumber:t.teamNumber}]))}))
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
        const rowKey=`q-${item.reportID}-${q_fileCount}`;
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
          .then(({report,pmText,task,isRework,task2Entries,user,mItems})=>
            fetch(`https://api.cmh.platform-prod2.evinternal.net/operations-center/api/TaskTrafficView/report/${item.reportID}`)
              .then(r=>r.ok?r.json():Promise.reject())
              .then(productInfo=>({report,pmText,task,isRework,task2Entries,user,mItems,deliveryProductName:productInfo?.deliveryProductName??'',primaryProductName:productInfo?.primaryProductName??''}))
              .catch(()=>({report,pmText,task,isRework,task2Entries,user,mItems,deliveryProductName:'',primaryProductName:''})))
          .then(({report,pmText,task,isRework,task2Entries,user,mItems,deliveryProductName,primaryProductName})=>{
            const mText=(mItems.measurementItems||[]).map(m=>'*'+(m.name||'').replace(/\s+/g,'')).join('  ');
            const typeBadge=isTraining?'<span class="badge-training">Training</span>':'<span class="badge-live">Live</span>';
            const stateLabel=isRFQC
              ?`Ready For QC${isRework?' (Rework)':''}`
              :`Being Qced${isRework?' (Rework)':''}`;
            const qcLocationName=dictLocation.get(user[0]?.locationId)??'';
            const appLabel = (mItems.measurementItems||[]).some(m=>/hipster/i.test(m.name||''))
              ? 'Hipster'
              : 'Twister';
            const isHipsterErrorRowQC =
              /bellevue/i.test(qcLocationName) ||
              /hipster/i.test(qcLocationName)  ||
              /error/i.test(qcLocationName);
            const siteTagQC = isHipsterErrorRowQC
              ? extractSiteTag(task2Entries)
              : '';
            const lastMeasuredTech=lastMeasured&&lastMeasured.description?(lastMeasured.description.match(/\(([^)]+)\)/)||[])[1]||'':'';
            const reworkCount=task2Entries.reduce((count,e)=>{
              const match=e.description&&e.description.match(/Rejected\(([^)]+)\)/);
              return(match&&/rework/i.test(match[1]))?count+1:count;
            },0);
            const reworkCountHtml=reworkCount?(()=>{
              const color = reworkCount>=2 ? 'red' : 'orangered';
              return `<span style="color:${color};">${reworkCount}</span>`;
            })():'';
            const rejectionHistoryHtmlQC=reworkCount?(()=>{
              const color = reworkCount>=2 ? 'red' : 'orangered';
              return `<span style="color:${color};white-space:nowrap;">Rework ${reworkCount}x</span>`;
            })():'';
            rowDetailsStore[rowKey]={
              reportID:item.reportID,
              pmText,
              isTraining,
              source:'qc',
              stateLabel,
              appLabel,
              reworkCount,
              measuredTech:lastMeasuredTech,
              userName:(user[0]?.userName??'')+siteTagQC,
              techUsername:user[0]?.techUsername??'',
              team:dictTeam.get(user[0]?.teamId)?.name??'',
              teamNumber:dictTeam.get(user[0]?.teamId)?.teamNumber??'',
              locationName:qcLocationName,
              deliveryProductName,
              primaryProductName,
              measurementRequestTypeID:report.measurementRequestTypeID,
              latitude:report.latitude,
              longitude:report.longitude,
              address:report.address,
              city:report.city,
              addressState:report.state,
              zip:report.zip,
              measurementItems:(mItems.measurementItems||[]).map(m=>m.name).filter(Boolean).join('\n')+(pmText?' [PM]':''),
              stateTime:task.stateTime,
              dueDate:item.dueDate,
              rejectedSuffix:lastMeasuredTech?`Measured Tech: ${lastMeasuredTech}`:'',
              reworkCountHtml,
              rejectionHistoryHtml:rejectionHistoryHtmlQC,
              reworkHtml:'',
              history:task2Entries.map(e=>({description:e.description,stateTime:e.stateTime}))
                .sort((a,b)=>new Date(b.stateTime)-new Date(a.stateTime))
            };
            let row=`<tr data-type="${isTraining?'training':'live'}" data-detail-key="${rowKey}">
<td>${typeBadge}</td>
<td>${item.reportID}</td>
<td style="color:${isRFQC?'var(--text-primary)':'var(--text-secondary)'};">${stateLabel}</td>
<td>${lastMeasured&&lastMeasured.description?(lastMeasured.description.match(/\(([^)]+)\)/)||[])[1]||'':''}</td>
<td>${user[0]?.userName??''}${siteTagQC}</td>
<td>${user[0]?.techUsername??''}</td>
<td>${dictTeam.get(user[0]?.teamId)?.name??''}</td>
<td>${dictLocation.get(user[0]?.locationId)??''}</td>
<td>${appLabel}</td>
<td>${escapeHtml(primaryProductName||'')}</td>
<td>${escapeHtml(getMeasurementRequestTypeName(report.measurementRequestTypeID))}</td>`;
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
            if(q_pendingFetches===0){sortTableByColumn('qc-table',12,true);startDynamicTimers('q-data');q_tableReady=true;maybeStartReloadTimer();window.flashDueCellsNow&&window.flashDueCellsNow('q-data');}
          })
          .catch(err=>{
            console.error('qc report chain error:',err);
            q_pendingFetches=Math.max(0,q_pendingFetches-1);
            if(q_pendingFetches===0){sortTableByColumn('qc-table',12,true);startDynamicTimers('q-data');q_tableReady=true;maybeStartReloadTimer();window.flashDueCellsNow&&window.flashDueCellsNow('q-data');}
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
      // Safety net: if neither list returned any items, the per-row
      // completion above never runs, so the table would never be marked
      // ready and auto-reload would never arm. Mark it ready here instead.
      if(q_pendingFetches===0 && !q_tableReady){sortTableByColumn('qc-table',12,true);startDynamicTimers('q-data');q_tableReady=true;maybeStartReloadTimer();window.flashDueCellsNow&&window.flashDueCellsNow('q-data');}
    });
  }).catch(err=>console.error('qc main chain error:',err));
})();
/* ============================================================================
   TRIPLE CLOCK — PH, Bogotá & PST/PDT
   ============================================================================ */
(function initTripleClock() {
  const CLOCKS = [
    { timeId: 'clock-time-ph',  iconId: 'clock-icon-ph',  itemId: 'clock-ph',  tz: 'Asia/Manila',        label: 'PH' },
    { timeId: 'clock-time-pst', iconId: 'clock-icon-pst', itemId: 'clock-pst', tz: 'America/Los_Angeles', label: 'US', labelId: 'clock-label-pst', dynamicLabel: false },
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
    { tbodyId: 'm-data', colCount: 12, widths: ['sk-sm','sk-md','sk-lg','sk-md','sk-sm','sk-lg','sk-xs','sk-md','sk-sm','sk-sm','sk-xs','sk-xs'] },
    { tbodyId: 'q-data', colCount: 11, widths: ['sk-sm','sk-md','sk-lg','sk-md','sk-sm','sk-xs','sk-md','sk-sm','sk-sm','sk-xs','sk-xs'] }
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
    warning:  { seconds: 3600, interval: 60, cls: 'due-warning-pulse' },
    critical: { seconds: 1800, interval: 60, cls: 'due-critical-pulse' }
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
  // Fires the fade→peak→fade flash immediately on every currently-due cell
  // in a table, meant to be called once the table has finished loading and
  // been sorted (rather than waiting for the per-row appearance to trickle
  // through the MutationObserver, or for the next scheduled 1-min tick).
  function flashDueCellsNow(dataId) {
    const tbody = document.getElementById(dataId);
    if (!tbody) return;
    tbody.querySelectorAll('tr').forEach(row => {
      if (row.dataset.type === 'training') return;
      const cell = row.querySelector('td.due');
      if (!cell) return;
      registerDueCell(cell);
      const sec = parseInt(cell.dataset.seconds || '0', 10);
      let level = null;
      if (sec < PULSE_CONFIG.critical.seconds || sec < 0) level = 'critical';
      else if (sec < PULSE_CONFIG.warning.seconds)        level = 'warning';
      if (!level) return;
      const state = cellPulseMap.get(cell);
      if (state) { state.level = level; state.secondsSince = 0; }
      triggerPulse(cell, level);
    });
  }
  window.flashDueCellsNow = flashDueCellsNow;
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
# 0. fileinfo.exe local cache (avoid re-fetching over SMB on every request)
# ============================================================================
# The File Info panel was slow because Handle-FileInfo invoked fileinfo.exe
# straight off a UNC path on every single request — Windows has to pull the
# executable over SMB each time before it can even start running, on top of
# whatever the tool itself does. Same fix as the WebView2 SDK below: fetch
# once, cache locally, and only re-copy if the share's copy is newer.
function Get-FileInfoExeLocal {
    $cacheDir   = Join-Path $env:LOCALAPPDATA 'PAR-App\fileinfo'
    $localExe   = Join-Path $cacheDir 'fileinfo.exe'
    $remoteBase = 'P:\1_Coordinators\PIA\fileinfo'
    $remoteExe  =
        if (Test-Path -LiteralPath "$remoteBase.exe" -PathType Leaf) { "$remoteBase.exe" }
        elseif (Test-Path -LiteralPath $remoteBase -PathType Leaf) { $remoteBase }
        else { $null }
    if (-not $remoteExe) {
        # Share unreachable / tool missing — fall back to any already-cached
        # local copy rather than failing outright.
        if (Test-Path -LiteralPath $localExe -PathType Leaf) { return $localExe }
        return $null
    }
    try {
        $needsCopy = (-not (Test-Path -LiteralPath $localExe -PathType Leaf)) -or
                     ((Get-Item -LiteralPath $remoteExe).LastWriteTime -gt (Get-Item -LiteralPath $localExe).LastWriteTime)
        if ($needsCopy) {
            New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
            Copy-Item -LiteralPath $remoteExe -Destination $localExe -Force
        }
    }
    catch {
        # Copy failed (offline, permissions, etc.) — use whatever's cached, if anything.
    }
    if (Test-Path -LiteralPath $localExe -PathType Leaf) { return $localExe }
    return $null
}
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
# Network shares containing per-report archive folders and their images,
# selected by the report's Location column.
$ArchiveRoots = @{
    Cebu    = '\\ceb-pure01.mnl.eagleview.com\reports-production\archive'
    Manila  = '\\mnl-pure01.mnl.eagleview.com\reports-production\archive'
    Default = '\\reports-fs-sing.cmh.reportsprod.evinternal.net\Production\archive'
}
# Tech "InProgress" boxes, where a tech's working .evm rollback files live
# while a report is being measured. Folder name is "<TechID>TCT<teamNumber>",
# e.g. "1580LGTCT24". Selected by the report's Location column, same as
# $ArchiveRoots above.
$InProgressRoots = @{
    Cebu    = '\\ceb-pure01.mnl.eagleview.com\reports-production\1_InBox\Day Shift'
    Manila  = '\\mnl-pure01.mnl.eagleview.com\reports-production\1_InBox\Day Shift'
    Default = '\\reports-fs-sing.cmh.reportsprod.evinternal.net\Production\1_InBox\Day Shift'
}
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
# Requests are handled by a small pool of runspaces (instead of one runspace
# processing requests one at a time), so things like "Images" and "File Info"
# — both fired the instant the detail popup opens — actually run at the same
# time instead of queueing behind each other. A short-lived cache of report
# folder lookups (shared across the pool) also means the two endpoints don't
# each pay for their own separate SMB directory scan for the same report.
$FolderCache = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
# Resolved once up front (copies fileinfo.exe locally if needed) so every
# pooled request just uses the cached local path instead of re-resolving
# it — and re-hitting the share — per request.
$FileInfoExeLocal = Get-FileInfoExeLocal
# fileinfo.exe writes its own intermediate file to a FIXED path in the
# user's Temp folder while it parses (not something we control — it's
# internal to the tool). With the request pool running several requests at
# once, two concurrent fileinfo.exe invocations can collide on that fixed
# filename — one process deletes/rewrites it while the other still has it
# open, surfacing as a WinError 32 "process cannot access the file" in the
# Notes field. A pool-wide semaphore serializes actual fileinfo.exe runs
# (cache hits still skip it entirely) so only one instance ever touches
# that file at a time.
$FileInfoExeLock = [System.Threading.SemaphoreSlim]::new(1, 1)
$initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
foreach ($varDef in @(
    @{ Name = 'Assets'           ; Value = $assets }
    @{ Name = 'ArchiveRoots'     ; Value = $ArchiveRoots }
    @{ Name = 'InProgressRoots'  ; Value = $InProgressRoots }
    @{ Name = 'FolderCache'      ; Value = $FolderCache }
    @{ Name = 'FileInfoExeLocal' ; Value = $FileInfoExeLocal }
    @{ Name = 'FileInfoExeLock'  ; Value = $FileInfoExeLock }
)) {
    $entry = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry(
        $varDef.Name, $varDef.Value, $null)
    $initialSessionState.Variables.Add($entry)
}
$requestPool = [runspacefactory]::CreateRunspacePool(4, 12, $initialSessionState, $Host)
$requestPool.Open()
# The script each pooled runspace runs for a single request. Function
# definitions are cheap to re-parse per call, so they're kept inline here
# rather than shared, to avoid relying on pooled runspaces retaining state
# between invocations.
$requestScript = {
    param($ctx)

    $ImageExtensions  = @('.jpg', '.jpeg')
    $ArchiveRootsFull = $ArchiveRoots.Values | ForEach-Object { [System.IO.Path]::GetFullPath($_) }

    function Write-JsonResponse($ctx, $obj, [int]$statusCode = 200) {
        $json  = $obj | ConvertTo-Json -Compress -Depth 6
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $ctx.Response.StatusCode     = $statusCode
        $ctx.Response.ContentType    = 'application/json; charset=utf-8'
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    }

    function Get-ArchiveRootForLocation($location) {
        # Trying a single archive root for all locations instead of routing
        # by Cebu/Manila/Default, since report folders for every location
        # appear to live under this one share.
        return $ArchiveRoots.Default
    }

    function Get-InProgressRootForLocation($location) {
        # Unlike the archive share, a tech's InProgress box genuinely lives
        # on a per-site file server, so this one does route by location.
        if ($location -match 'cebu')   { return $InProgressRoots.Cebu }
        if ($location -match 'manila') { return $InProgressRoots.Manila }
        return $InProgressRoots.Default
    }

    # Known report folder prefixes: P1-P4, 1H-3H. Filtering on "<prefix>_<id>*"
    # anchors the wildcard to the right side only, which the filesystem/SMB
    # layer resolves much faster than a leading-wildcard "*<id>*" scan.
    $ReportFolderPrefixes = @('P1', 'P2', 'P3', 'P4', '1H', '2H', '3H')

    function Find-ReportFolders($archiveRoot, $reportId) {
        # Reuse a recent lookup for this report if another request (e.g. the
        # sibling images/file-info call fired at the same time) already found
        # it, instead of re-scanning the SMB share.
        $cacheKey = "$archiveRoot|$reportId"
        $cached = $null
        if ($FolderCache.TryGetValue($cacheKey, [ref]$cached) -and
            ((Get-Date) - $cached.Time).TotalSeconds -lt 120) {
            return $cached.Result
        }
        # Fastest path: try each known "<prefix>_<reportId>_..." pattern directly.
        # A trailing-only wildcard lets the filesystem/SMB layer resolve the
        # match immediately instead of scanning every folder name for a
        # substring anywhere in it.
        $result = $null
        foreach ($prefix in $ReportFolderPrefixes) {
            $hit = @(Get-ChildItem -LiteralPath $archiveRoot -Directory -Filter "${prefix}_${reportId}_*" -ErrorAction Stop)
            if ($hit.Count -gt 0) {
                $result = [pscustomobject]@{ Folders = $hit; Method = 'prefix' }
                break
            }
        }
        # Fast path: folders directly under the archive root, matched by a
        # broader substring pattern (covers naming that doesn't match a known
        # prefix). -Filter still pushes the wildcard down to the filesystem/
        # SMB layer itself, so on a huge archive share the server only returns
        # matching entries instead of us listing every folder and filtering
        # in memory (which was slow enough on production shares to look like
        # a dead connection).
        if (-not $result) {
            $direct = @(Get-ChildItem -LiteralPath $archiveRoot -Directory -Filter "*$reportId*" -ErrorAction Stop)
            if ($direct.Count -gt 0) {
                $result = [pscustomobject]@{ Folders = $direct; Method = 'direct' }
            }
        }
        # Fallback: some archives group report folders under year/month/site
        # subdirectories, so walk a few levels deep. Ignore per-folder access
        # errors (permissions, offline DFS links, etc.) rather than aborting.
        if (-not $result) {
            $recursed = @(Get-ChildItem -LiteralPath $archiveRoot -Directory -Filter "*$reportId*" -Recurse -Depth 3 -ErrorAction SilentlyContinue)
            $result = [pscustomobject]@{ Folders = $recursed; Method = 'recursive' }
        }
        $FolderCache[$cacheKey] = [pscustomobject]@{ Result = $result; Time = Get-Date }
        return $result
    }

    function Handle-ImagesSearch($ctx) {
        $reportId   = $ctx.Request.QueryString['reportId']
        $location   = $ctx.Request.QueryString['location']
        $folderName = $ctx.Request.QueryString['folderName']
        if ([string]::IsNullOrWhiteSpace($reportId) -or ($reportId -notmatch '^[A-Za-z0-9_-]+$')) {
            Write-JsonResponse $ctx @{ found = $false; error = 'Invalid report id' } 400
            return
        }
        $archiveRoot = Get-ArchiveRootForLocation $location
        try {
            if (-not (Test-Path -LiteralPath $archiveRoot)) {
                Write-JsonResponse $ctx @{ found = $false; error = "Archive share not reachable: $archiveRoot" } 502
                return
            }
        }
        catch {
            Write-JsonResponse $ctx @{ found = $false; error = "Couldn't reach the archive share: $($_.Exception.Message)" } 502
            return
        }
        $folder       = $null
        $searchMethod = $null
        # When the caller already knows the exact report folder name (e.g.
        # a Twister .evm filename, which matches the archive folder name
        # exactly), go straight there instead of scanning the archive share.
        if (-not [string]::IsNullOrWhiteSpace($folderName) -and
            ($folderName -notmatch '[\\/]') -and ($folderName -notmatch '\.\.')) {
            $directPath = Join-Path $archiveRoot $folderName
            try {
                if (Test-Path -LiteralPath $directPath -PathType Container) {
                    $folder       = Get-Item -LiteralPath $directPath
                    $searchMethod = 'evm-filename'
                }
            }
            catch { }
        }
        if (-not $folder) {
            try {
                $result  = Find-ReportFolders $archiveRoot $reportId
                $folders = @($result.Folders | Sort-Object LastWriteTime -Descending)
            }
            catch {
                Write-JsonResponse $ctx @{ found = $false; error = "Search failed: $($_.Exception.Message)" } 502
                return
            }
            if ($folders.Count -eq 0) {
                Write-JsonResponse $ctx @{
                    found      = $false
                    reportId   = $reportId
                    searchRoot = $archiveRoot
                    message    = "No archive folder found for report $reportId (searched directly under $archiveRoot and up to 3 levels deep)"
                }
                return
            }
            $folder       = $folders[0]
            $searchMethod = $result.Method
        }
        $imagesDir = Join-Path $folder.FullName 'Images'
        $imageUrls = @()
        if (Test-Path -LiteralPath $imagesDir) {
            try {
                # Direction order for elevation shots: Overview, North, East, West, South.
                $ElevationOrder = @{ 'O' = 0; 'N' = 1; 'E' = 2; 'W' = 3; 'S' = 4 }
                $files = Get-ChildItem -LiteralPath $imagesDir -File -ErrorAction Stop |
                         Where-Object { $ImageExtensions -contains $_.Extension.ToLowerInvariant() } |
                         Sort-Object LastWriteTime -Descending |
                         Select-Object -First 5 |
                         Sort-Object @{ Expression = {
                             $prefix = $_.BaseName.Substring(0,1).ToUpperInvariant()
                             if ($ElevationOrder.ContainsKey($prefix)) { $ElevationOrder[$prefix] } else { 99 }
                         } }
                $imageUrls = @($files | ForEach-Object { '/api/image-file?path=' + [Uri]::EscapeDataString($_.FullName) })
            }
            catch { }
        }
        Write-JsonResponse $ctx @{
            found       = $true
            reportId    = $reportId
            folder      = $folder.Name
            folderPath  = $folder.FullName
            archiveRoot = $archiveRoot
            searchDepth = $searchMethod
            matchCount  = 1
            imageCount  = $imageUrls.Count
            images      = $imageUrls
        }
    }

    function Handle-ImageFile($ctx) {
        $reqPath = $ctx.Request.QueryString['path']
        if ([string]::IsNullOrWhiteSpace($reqPath)) { $ctx.Response.StatusCode = 400; return }
        try {
            $full = [System.IO.Path]::GetFullPath($reqPath)
            $withinKnownRoot = $false
            foreach ($root in $ArchiveRootsFull) {
                if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { $withinKnownRoot = $true; break }
            }
            if (-not $withinKnownRoot) {
                $ctx.Response.StatusCode = 403
                return
            }
            $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
            if ($ImageExtensions -notcontains $ext) { $ctx.Response.StatusCode = 403; return }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $ctx.Response.StatusCode = 404; return }
            $mime = switch ($ext) {
                '.jpg'  { 'image/jpeg' }
                '.jpeg' { 'image/jpeg' }
                '.png'  { 'image/png' }
                '.gif'  { 'image/gif' }
                '.bmp'  { 'image/bmp' }
                '.webp' { 'image/webp' }
                '.tif'  { 'image/tiff' }
                '.tiff' { 'image/tiff' }
                default { 'application/octet-stream' }
            }
            $bytes = [System.IO.File]::ReadAllBytes($full)
            $ctx.Response.ContentType     = $mime
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        catch {
            $ctx.Response.StatusCode = 404
        }
    }

    function Handle-FileInfo($ctx) {
        $reportId = $ctx.Request.QueryString['reportId']
        $location = $ctx.Request.QueryString['location']
        if ([string]::IsNullOrWhiteSpace($reportId) -or ($reportId -notmatch '^[A-Za-z0-9_-]+$')) {
            Write-JsonResponse $ctx @{ found = $false; error = 'Invalid report id' } 400
            return
        }
        # File Info now always reads from the report's archive folder rather
        # than the tech/QC InProgress boxes: the working .evm the tech/QC has
        # checked out isn't necessarily the newest version on disk, but the
        # Rollback folder under the archive keeps every saved version, so the
        # highest-numbered file there ("<n>.0.evm") is always the latest.
        #   \\reports-fs-sing.cmh.reportsprod.evinternal.net\Production\archive\<folder prefix match>\Rollback\<latest .evm>
        $archiveRoot = Get-ArchiveRootForLocation $location
        try {
            if (-not (Test-Path -LiteralPath $archiveRoot)) {
                Write-JsonResponse $ctx @{ found = $false; error = "Archive share not reachable: $archiveRoot" } 502
                return
            }
        }
        catch {
            Write-JsonResponse $ctx @{ found = $false; error = "Couldn't reach the archive share: $($_.Exception.Message)" } 502
            return
        }
        try {
            $result  = Find-ReportFolders $archiveRoot $reportId
            $folders = @($result.Folders | Sort-Object LastWriteTime -Descending)
        }
        catch {
            Write-JsonResponse $ctx @{ found = $false; error = "Search failed: $($_.Exception.Message)" } 502
            return
        }
        if ($folders.Count -eq 0) {
            Write-JsonResponse $ctx @{
                found      = $false
                reportId   = $reportId
                searchRoot = $archiveRoot
                message    = "No archive folder found for report $reportId (searched directly under $archiveRoot and up to 3 levels deep)"
            }
            return
        }
        $folder       = $folders[0]
        $searchMethod = $result.Method
        $searchDir    = Join-Path $folder.FullName 'Rollback'
        $searchedPath = "$($folder.Name)\Rollback"
        try {
            if (-not (Test-Path -LiteralPath $searchDir)) {
                Write-JsonResponse $ctx @{
                    found         = $false
                    reportId      = $reportId
                    folder        = $folder.Name
                    searchedPath  = $searchedPath
                    fullSearchDir = $searchDir
                    message       = 'No rollback found'
                }
                return
            }
        }
        catch {
            Write-JsonResponse $ctx @{ found = $false; error = "Couldn't reach the share: $($_.Exception.Message)" } 502
            return
        }
        try {
            # Rollback .evm files are named "<version>.0.evm" (e.g. "1.0.evm",
            # "2.0.evm" ... "5.0.evm"). Sort by that numeric version rather
            # than LastWriteTime, since successive versions can land with the
            # same/near-identical timestamp and the version number is the
            # authoritative "latest" signal. Fall back to LastWriteTime for
            # any file that doesn't match the expected naming.
            $evmFiles = @(Get-ChildItem -LiteralPath $searchDir -File -Filter '*.evm' -ErrorAction Stop |
                Sort-Object -Descending -Property @{
                    Expression = {
                        $ver = 0.0
                        if ([double]::TryParse(($_.BaseName -replace '[^0-9.]', ''), [ref]$ver)) { $ver } else { -1 }
                    }
                }, LastWriteTime)
        }
        catch {
            Write-JsonResponse $ctx @{ found = $false; error = "Search failed: $($_.Exception.Message)" } 502
            return
        }
        if ($evmFiles.Count -eq 0) {
            Write-JsonResponse $ctx @{
                found         = $false
                reportId      = $reportId
                folder        = $folder.Name
                searchedPath  = $searchedPath
                fullSearchDir = $searchDir
                message       = 'No rollback found'
            }
            return
        }
        $evmFile = $evmFiles[0].FullName

        # --- Output cache: if this exact .evm version has already been
        # parsed (by this request or a concurrent sibling one), skip
        # fileinfo.exe entirely. Keyed on write time so a newer .evm always
        # gets re-parsed.
        $evmWriteTime   = (Get-Item -LiteralPath $evmFile).LastWriteTime
        # "Rollback" is the version number pulled from the filename itself
        # (e.g. "5.0.evm" -> "5.0"), not the parsed fileinfo output.
        # "Checkpoint" is that file's last-modified time, formatted to match
        # what Explorer shows (e.g. "8/31/2026 9:31 AM").
        $rollbackVersion  = $evmFiles[0].BaseName
        $checkpointStamp  = $evmWriteTime.ToString('M/d/yyyy h:mm tt')
        $outputCacheKey = "out:$evmFile|$($evmWriteTime.Ticks)"
        $cachedEntry = $null
        if ($FolderCache.TryGetValue($outputCacheKey, [ref]$cachedEntry)) {
            Write-JsonResponse $ctx @{
                found      = $true
                reportId   = $reportId
                folder     = $folder.Name
                filePath   = $evmFile
                rollback   = $rollbackVersion
                checkpoint = $checkpointStamp
                output     = $cachedEntry
                cached     = $true
            }
            return
        }

        # fileinfo.exe is resolved once at startup and cached locally under
        # %LOCALAPPDATA% (see Get-FileInfoExeLocal) instead of being invoked
        # straight off the UNC share on every request — Windows previously
        # had to pull the whole executable over SMB each time before it
        # could even start running.
        $fileInfoExe = $FileInfoExeLocal
        if (-not $fileInfoExe -or -not (Test-Path -LiteralPath $fileInfoExe -PathType Leaf)) {
            Write-JsonResponse $ctx @{ found = $false; error = 'fileinfo tool not available (local cache empty and share unreachable)' } 500
            return
        }

        # Copy the .evm locally before handing it to fileinfo.exe, rather
        # than pointing the tool at the UNC path directly — if the tool
        # seeks around the file instead of reading it once sequentially,
        # that's multiple SMB round trips per lookup instead of one copy.
        $localEvm = Join-Path $env:TEMP ("parfi_{0}.evm" -f ([guid]::NewGuid().ToString('N')))
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $copyMs = 0; $execMs = 0
        $lockAcquired = $false
        try {
            Copy-Item -LiteralPath $evmFile -Destination $localEvm -Force
            $copyMs = $sw.ElapsedMilliseconds
            $sw.Restart()
            # Only one fileinfo.exe run at a time pool-wide — see
            # $FileInfoExeLock's comment above for why.
            $FileInfoExeLock.Wait()
            $lockAcquired = $true
            $output = & $fileInfoExe $localEvm 2>&1 | Out-String
            $execMs = $sw.ElapsedMilliseconds
        }
        catch {
            Write-JsonResponse $ctx @{ found = $false; error = "fileinfo failed: $($_.Exception.Message)" } 500
            return
        }
        finally {
            if ($lockAcquired) { $FileInfoExeLock.Release() | Out-Null }
            Remove-Item -LiteralPath $localEvm -Force -ErrorAction SilentlyContinue
        }
        $output = $output.Trim()
        $FolderCache[$outputCacheKey] = $output
        Write-JsonResponse $ctx @{
            found      = $true
            reportId   = $reportId
            folder     = $folder.Name
            filePath   = $evmFile
            rollback   = $rollbackVersion
            checkpoint = $checkpointStamp
            output     = $output
            timingMs   = @{ copy = $copyMs; exec = $execMs }
        }
    }

    try {
        $path = $ctx.Request.Url.AbsolutePath
        if ($path -eq '/api/images') {
            Handle-ImagesSearch $ctx
        }
        elseif ($path -eq '/api/image-file') {
            Handle-ImageFile $ctx
        }
        elseif ($path -eq '/api/file-info') {
            Handle-FileInfo $ctx
        }
        elseif ($Assets.ContainsKey($path)) {
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
# Background runspace whose only job is accepting connections and immediately
# handing each one to the pool. Because Accept() itself is the only thing
# happening on this runspace, a slow request (an SMB scan, running the
# fileinfo tool) never delays accepting or starting the next one.
$listenerRunspace = [runspacefactory]::CreateRunspace()
$listenerRunspace.Open()
$listenerRunspace.SessionStateProxy.SetVariable('Listener', $listener)
$listenerRunspace.SessionStateProxy.SetVariable('RequestPool', $requestPool)
$listenerRunspace.SessionStateProxy.SetVariable('RequestScript', $requestScript)
$serverPs = [powershell]::Create()
$serverPs.Runspace = $listenerRunspace
[void]$serverPs.AddScript({
    $inFlight = New-Object System.Collections.Generic.List[object]
    while ($Listener.IsListening) {
        try { $ctx = $Listener.GetContext() } catch { break }
        # Reap any requests that finished since the last time round, so this
        # list doesn't grow without bound over a long-running session.
        for ($i = $inFlight.Count - 1; $i -ge 0; $i--) {
            if ($inFlight[$i].AsyncResult.IsCompleted) {
                try { $inFlight[$i].Pipe.EndInvoke($inFlight[$i].AsyncResult) } catch { }
                $inFlight[$i].Pipe.Dispose()
                $inFlight.RemoveAt($i)
            }
        }
        $pipe = [powershell]::Create()
        $pipe.RunspacePool = $RequestPool
        [void]$pipe.AddScript($RequestScript).AddArgument($ctx)
        $async = $pipe.BeginInvoke()
        $inFlight.Add([pscustomobject]@{ Pipe = $pipe; AsyncResult = $async })
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
# WPF doesn't automatically hand keyboard/mouse focus down to the WebView2
# control's embedded Chromium child window, so without this the first click
# after the window opens (or regains focus) only activates/focuses the
# control instead of reaching the page — the click has to be repeated to
# actually register. Explicitly focusing WebView2 on window activation and
# once navigation completes fixes the "needs a double click" symptom.
$window.Add_Activated({
    try { $webView.Focus() | Out-Null } catch { }
})
$window.Add_Closed({
    try { $listener.Stop() } catch { }
    try { $serverPs.Stop(); $serverPs.Dispose() } catch { }
    try { $listenerRunspace.Close() } catch { }
    try { $requestPool.Close(); $requestPool.Dispose() } catch { }
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
        # Disable WebView2's own browser-style right-click menu (Reload,
        # Back, View Source, etc.). The page has its own custom row context
        # menu with a JS-level e.preventDefault(), but that only covers the
        # HTML document; without this setting the native Chromium menu can
        # still surface on top of/before it, which is what showed "Refresh".
        try { $webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = $false } catch { }
        $webView.CoreWebView2.Navigate($prefix)
        try { $webView.Focus() | Out-Null } catch { }
        # Any window.open()/target="_blank" link (e.g. the Explorer and
        # Gmaps buttons in the report detail modal) would otherwise spawn a
        # second embedded WebView2 popup window. Intercept those requests
        # and hand the URL to the user's actual default browser instead.
        $webView.CoreWebView2.add_NewWindowRequested({
            param($wvSender, $wvArgs)
            $wvArgs.Handled = $true
            try { Start-Process $wvArgs.Uri } catch { }
        })
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