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
    [switch]$ForceWebView2Refresh,
    # Silence the terminal log (startup, requests, image/file-info/wireframe work, errors).
    [switch]$Quiet
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
#  TERMINAL LOGGING
# ============================================================
# Timestamped, colour-coded lines in this PowerShell window showing what PAR is
# doing: startup, access check, every local API request (with status + time),
# image / file-info / wireframe work, python output, and errors from the page.
# Run with -Quiet to silence it. Never throws.
$ParLogEnabled = -not $Quiet
function Write-ParLog {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO',
        [Parameter(Position = 2)][string]$Source = 'PAR'
    )
    if (-not $ParLogEnabled) { return }
    try {
        $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'DEBUG' { 'DarkGray' } default { 'Cyan' } }
        Write-Host ("[{0}] [{1,-5}] [{2}] {3}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Level, $Source, $Message) -ForegroundColor $color
    }
    catch { }
}
Write-ParLog "PAR starting (user $env:USERNAME on $env:COMPUTERNAME)" 'INFO' 'startup'

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
        $echoLevel = if ($Action -match 'Fail|Restricted') { 'WARN' } elseif ($Action -match 'Passed') { 'OK' } else { 'DEBUG' }
        $echoText  = if ($Details) { "$Action | $Details" } else { $Action }
        if ($echoText.Length -gt 220) { $echoText = $echoText.Substring(0, 220) + '...' }
        Write-ParLog $echoText $echoLevel 'usage'
    }
    catch { }
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
#     for troubleshooting. Enabled by default; run PAR with -Quiet to silence
#     them (or set $ParDebugEnabled to $false). <<<
$ParDebugEnabled = -not $Quiet
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
Write-ParLog 'Access check finished - terminal logging stays on (run with -Quiet to silence it).' 'INFO' 'PAR'
# Terminal logging now continues after the role check (requests, image/file-info/wireframe work,
# python output, page errors); $ParLogEnabled is still passed to the request runspaces.
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
    <button class="image-lightbox-close" id="imageLightboxClose" title="Close (Esc)" aria-label="Close">×</button>
    <button class="image-lightbox-nav image-lightbox-prev" id="imageLightboxPrev" title="Previous image (←)" aria-label="Previous image">‹</button>
    <img id="imageLightboxImg" src="" alt="Report image full size">
    <button class="image-lightbox-nav image-lightbox-next" id="imageLightboxNext" title="Next image (→)" aria-label="Next image">›</button>
    <div class="image-lightbox-caption" id="imageLightboxCaption"></div>
  </div>
  <div id="view3dViewer" class="image-lightbox view3d-viewer" aria-hidden="true">
    <button class="image-lightbox-close" id="view3dClose" title="Close (Esc)" aria-label="Close">×</button>
    <div class="view3d-toolbar">
      <button type="button" id="view3dSpin">Auto-rotate: off</button>
      <label class="view3d-shade" title="Shading opacity (100% = default, 0% = off)">Shading <input type="range" id="view3dShade" min="0" max="300" step="5" value="100"><span id="view3dShadeVal">100%</span></label>
      <button type="button" id="view3dReset">Reset view</button>
      <span class="view3d-sep" aria-hidden="true"></span>
      <button type="button" id="view3dPts">Points: on</button>
      <button type="button" id="view3dLbl">Pitch: on</button>
    </div>
    <button class="image-lightbox-nav image-lightbox-prev" id="view3dPrev" title="Previous image (←)" aria-label="Previous image">‹</button>
    <button class="image-lightbox-nav image-lightbox-next" id="view3dNext" title="Next image (→)" aria-label="Next image">›</button>
    <canvas id="view3dCanvas"></canvas>
    <div class="image-lightbox-caption" id="view3dCaption">Wireframes (3D)  ·  drag to rotate  ·  right-drag to pan  ·  scroll to zoom  ·  double-click to reset</div>
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
  padding: 9px 18px; border-bottom: 1px solid var(--border-light);
  background: var(--bg-surface); flex-shrink: 0;
}
.detail-modal-title { font-size: 14px; font-weight: 600; letter-spacing: 0.04em; color: var(--text-primary); }
.detail-modal-subtitle { font-size: 11px; color: var(--text-muted); margin-top: 2px; letter-spacing: 0.03em; }
.detail-product-line { font-size: 12px; color: var(--text-secondary); font-family: var(--sans); }
.detail-folder-name { font-size: 11px; color: var(--text-muted); margin-top: 4px; letter-spacing: 0.02em; word-break: break-word; }
.detail-close-btn {
  border: none; background: transparent; color: var(--text-muted);
  font-size: 20px; line-height: 1; cursor: pointer; padding: 0 6px;
  border-radius: 6px; transition: background 0.12s, color 0.12s;
}
.detail-close-btn:hover { background: var(--bg-hover); color: var(--text-primary); }
.detail-images-section { flex-shrink: 0; max-height: min(400px, 48vh); overflow-y: auto; padding: 8px 18px 0; }
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
  padding: 5px 18px; border-top: 1px solid var(--border-light);
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
  display: grid; grid-template-columns: repeat(12, 1fr); gap: 8px;
}
@media (max-width: 480px) {
  .detail-images-grid { grid-template-columns: repeat(auto-fill, minmax(84px, 1fr)); }
}
.detail-image-thumb {
  position: relative; grid-column: span 3; aspect-ratio: 1 / 1; border-radius: 6px; overflow: hidden;
  background: var(--bg-card); border: 1px solid var(--border-light); cursor: pointer;
}
.detail-image-thumb img { width: 100%; height: 100%; object-fit: cover; display: block; transition: transform 0.15s ease; }
.detail-image-thumb:hover img { transform: scale(1.06); }
.detail-image-thumb.img-error { display: none; }
.detail-feature-thumb { grid-column: span 4; aspect-ratio: 4 / 3; }
.detail-feature-thumb img { object-fit: contain; }
.detail-overlay-thumb { background: #000; }
@media (max-width: 480px) { .detail-image-thumb, .detail-feature-thumb { grid-column: auto; } }
.detail-image-skel {
  cursor: default;
  background: linear-gradient(90deg, var(--bg-card) 0%, var(--bg-hover) 40%, var(--bg-card) 80%);
  background-size: 200% 100%;
  animation: skeleton-shimmer 1.6s ease-in-out infinite;
}
.detail-wireframe-loading-status {
  position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%);
  padding: 5px 9px; background: transparent;
  color: #fff; font-family: var(--sans); font-size: 11px; font-weight: 500;
  line-height: 1.3; text-align: center; white-space: nowrap; pointer-events: none;
  text-shadow: 0 1px 3px rgba(0,0,0,0.9);
}
body.light .detail-wireframe-loading-status { color: #1a1f2e; text-shadow: none; }
.detail-images-empty { grid-column: 1 / -1; font-size: 12px; color: var(--text-muted); font-style: italic; padding: 8px 0; }
.detail-wireframe-thumb { background: #fff; }
.detail-wireframe-thumb img { object-fit: contain; background: #fff; }
.detail-wireframe-thumb:hover img { transform: none; }
.detail-wireframe-badge {
  position: absolute; left: 4px; bottom: 4px; padding: 1px 6px; border-radius: 3px;
  font-size: 9px; font-weight: 600; letter-spacing: 0.03em; text-transform: uppercase;
  background: rgba(10,77,140,0.88); color: #fff; pointer-events: none;
}
.detail-wireframe-reason { margin-top: 4px; font-size: 8px; line-height: 1.25; word-break: break-word; opacity: 0.85; }
.detail-wireframe-error {
  display: flex; align-items: center; justify-content: center; text-align: center;
  padding: 6px; font-size: 10px; color: var(--text-muted); cursor: default; background: var(--bg-card);
}
.image-lightbox {
  position: fixed; inset: 0; z-index: 300; background: rgba(0,0,0,0.82);
  display: flex; align-items: center; justify-content: center;
  opacity: 0; pointer-events: none; transition: opacity 0.15s ease;
}
.image-lightbox.open { opacity: 1; pointer-events: auto; }
.image-lightbox { overflow: hidden; }
/* Every preview image is shown at the same height. */
.image-lightbox img {
  height: 88vh; width: auto; max-width: 94vw; object-fit: contain;
  border-radius: 6px; box-shadow: 0 12px 48px rgba(0,0,0,0.5);
  transform-origin: 50% 50%; will-change: transform; user-select: none; -webkit-user-drag: none;
}
.image-lightbox img.zoomed { cursor: grab; }
.image-lightbox img.dragging { cursor: grabbing; }
.image-lightbox-close, .image-lightbox-nav, .image-lightbox-caption { z-index: 2; }
.image-lightbox-close {
  position: absolute; top: 18px; right: 24px; border: none; background: transparent; color: #fff;
  font-size: 28px; cursor: pointer; line-height: 1; padding: 4px 10px; border-radius: 6px;
}
.image-lightbox-close:hover { background: rgba(255,255,255,0.12); }
.image-lightbox-nav {
  position: absolute; top: 50%; transform: translateY(-50%);
  width: 46px; height: 68px; border: none; border-radius: 8px;
  background: rgba(255,255,255,0.10); color: #fff;
  font-size: 38px; line-height: 1; cursor: pointer; padding: 0 0 4px;
  transition: background 0.12s;
}
.image-lightbox-nav:hover { background: rgba(255,255,255,0.24); }
.detail-view3d-thumb { background: #fff; }
.detail-view3d-thumb img { object-fit: contain; background: #fff; }
.detail-view3d-thumb:hover img { transform: none; }
.view3d-viewer canvas {
  width: min(94vw, 1500px); height: 88vh; background: #fff; border-radius: 6px;
  box-shadow: 0 12px 48px rgba(0,0,0,0.5); cursor: grab; touch-action: none; display: block;
}
.view3d-viewer canvas.dragging { cursor: grabbing; }
.view3d-toolbar { position: absolute; top: 18px; left: 24px; display: flex; flex-wrap: wrap; gap: 8px; max-width: calc(100% - 110px); z-index: 2; }
.view3d-sep { align-self: stretch; width: 1px; margin: 2px 4px; background: rgba(255,255,255,0.35); }
.view3d-toolbar label.view3d-shade { display: inline-flex; align-items: center; gap: 8px; border: 1px solid rgba(255,255,255,0.28); background: rgba(255,255,255,0.10); color: #fff; font-family: var(--sans); font-size: 12px; padding: 4px 12px; border-radius: 6px; }
.view3d-toolbar label.view3d-shade input { width: 110px; cursor: pointer; }
.view3d-toolbar label.view3d-shade span { min-width: 38px; text-align: right; }
.view3d-toolbar button.off { opacity: 0.5; text-decoration: line-through; }
.view3d-toolbar button {
  border: 1px solid rgba(255,255,255,0.28); background: rgba(255,255,255,0.10); color: #fff;
  font-family: var(--sans); font-size: 12px; padding: 5px 12px; border-radius: 6px; cursor: pointer;
}
.view3d-toolbar button:hover { background: rgba(255,255,255,0.24); }
.image-lightbox-prev { left: 18px; }
.image-lightbox-next { right: 18px; }
.image-lightbox-caption {
  position: absolute; bottom: 34px; left: 50%; transform: translateX(-50%);
  padding: 3px 14px; border-radius: 12px; background: rgba(0,0,0,0.6); color: #fff;
  font-family: var(--sans); font-size: 12px; letter-spacing: 0.03em; white-space: nowrap;
  pointer-events: none;
}
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
/* ── TERMINAL LOG BRIDGE ──
   parLog(level, message) forwards a line to the PowerShell window (level: info|ok|warn|error).
   console.error / console.warn and uncaught errors are forwarded too. Never throws. */
function parLog(level, message){
  try {
    const text = String(message == null ? '' : message).slice(0, 600);
    if (window.chrome && window.chrome.webview) {
      window.chrome.webview.postMessage(JSON.stringify({ level: level, message: text }));
    }
  } catch (e) { /* logging must never break the UI */ }
}
(function hookConsoleForTerminal(){
  const origError = console.error.bind(console);
  const origWarn  = console.warn.bind(console);
  const fmt = args => Array.from(args).map(a => {
    if (a && a.message) return a.message;
    if (a && typeof a === 'object') { try { return JSON.stringify(a); } catch (e) { return String(a); } }
    return String(a);
  }).join(' ');
  console.error = function(){ origError.apply(null, arguments); parLog('error', fmt(arguments)); };
  console.warn  = function(){ origWarn.apply(null, arguments);  parLog('warn',  fmt(arguments)); };
  window.addEventListener('error', e => parLog('error', `Uncaught: ${e.message} (${e.filename || ''}:${e.lineno || 0})`));
  window.addEventListener('unhandledrejection', e => parLog('error', `Unhandled promise rejection: ${(e.reason && e.reason.message) ? e.reason.message : e.reason}`));
})();
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
let wireframeToken = 0;
// Generated tiles shown after the top-down image: the wireframe drawn over the
// top-down photo (2D) and the rotatable 3D wireframes.
const WF_TILES = {
  overlay:   { id: 'detailOverlayThumb',   label: 'Overlay (2D)', query: '&overlay=1', cls: 'detail-overlay-thumb',   loading: 'Generating overlay…' },
  // Wireframes (3D): the server returns 3D geometry (JSON); the tile shows a snapshot of it and a click opens a rotatable viewer.
  view3d:    { id: 'detailView3dThumb',    label: 'Wireframes (3D)', query: '&view3d=1', cls: 'detail-view3d-thumb', loading: 'Generating 3D wireframes…' }
};
const wireframeStates = {};
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
    if (e.target.closest('.detail-view3d-thumb')) { const v3 = wireframeStates.view3d; if (v3 && v3.status === 'ready' && v3.src) openImageLightbox(v3.src); return; }
    const img = e.target.closest('.detail-image-thumb img');
    if (img && img.getAttribute('src')) openImageLightbox(img.getAttribute('src'));
});
  document.querySelectorAll('.detail-tab').forEach(tab => {
    tab.addEventListener('click', () => switchDetailTab(tab.dataset.tab));
  });
  document.getElementById('imageLightboxClose')?.addEventListener('click', closeImageLightbox);
  wireView3dViewer();
  (function wireLightboxZoom(){
    const lbEl  = document.getElementById('imageLightbox');
    const imgEl = document.getElementById('imageLightboxImg');
    if (!lbEl || !imgEl) return;
    imgEl.draggable = false;
    lbEl.addEventListener('wheel', e => {
      if (!lbEl.classList.contains('open')) return;
      e.preventDefault();
      zoomLightboxAt(e.clientX, e.clientY, e.deltaY < 0 ? 1.2 : 1 / 1.2);
    }, { passive: false });
    let drag = null;
    imgEl.addEventListener('mousedown', e => {
      if (lbZoom.s <= 1 || e.button !== 0) return;
      e.preventDefault();
      drag = { sx: e.clientX, sy: e.clientY, ox: lbZoom.x, oy: lbZoom.y };
      lightboxDragged = false;
      imgEl.classList.add('dragging');
    });
    document.addEventListener('mousemove', e => {
      if (!drag) return;
      const dx = e.clientX - drag.sx, dy = e.clientY - drag.sy;
      if (Math.abs(dx) + Math.abs(dy) > 3) lightboxDragged = true;
      lbZoom.x = drag.ox + dx; lbZoom.y = drag.oy + dy;
      applyLightboxZoom();
    });
    document.addEventListener('mouseup', () => {
      if (!drag) return;
      drag = null;
      imgEl.classList.remove('dragging');
      setTimeout(() => { lightboxDragged = false; }, 0);   // swallow the click that ends a drag
    });
    imgEl.addEventListener('dblclick', resetLightboxZoom);
  })();
  document.getElementById('imageLightboxPrev')?.addEventListener('click', () => stepImageLightbox(-1));
  document.getElementById('imageLightboxNext')?.addEventListener('click', () => stepImageLightbox(1));
  document.getElementById('imageLightbox')?.addEventListener('click', e => {
    if (e.target.id === 'imageLightbox' && !lightboxDragged) closeImageLightbox();
  });
  document.addEventListener('keydown', e => {
    const lb = document.getElementById('imageLightbox');
    const lightboxOpen = !!(lb && lb.classList.contains('open'));
    // With an image open in the preview, Left/Right step to the previous/next image.
    if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
      if (lightboxOpen) { e.preventDefault(); stepImageLightbox(e.key === 'ArrowRight' ? 1 : -1); }
      return;
    }
    if (e.key !== 'Escape') return;
    const v3 = document.getElementById('view3dViewer');
    if (v3 && v3.classList.contains('open')) { closeView3dViewer(); return; }
    if (lightboxOpen) closeImageLightbox();
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
  parLog('info', `Report #${details.reportID} opened (${details.source || '?'}, ${details.appLabel || '?'}, ${details.stateLabel || '?'})`);
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
  resetWireframe();
  if (isTwisterFileInfo) markWireframePending();
  else if (isHipster) setWireframeUnavailable('No evm data for this Hipster report');
  if (imagesGrid) imagesGrid.innerHTML = buildImageSkeletons();
  if (isTwisterFileInfo || isHipster) renderWireframeThumb();
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
function buildImageSkeletons(count = 4){
  // Same layout as the loaded grid: Ortho (top) first, then 4 photo slots. The Overlay (2D) and
  // Wireframes (3D) placeholders are inserted after the Ortho slot by renderWireframeThumb().
  const ortho = `<div class="detail-image-thumb detail-feature-thumb detail-topdown-thumb detail-image-skel" title="Loading top-down image…"><span class="detail-wireframe-badge">Ortho (top)</span></div>`;
  return ortho + Array.from({ length: count }).map(() => `<div class="detail-image-thumb detail-image-skel"></div>`).join('');
}
function getEvmBaseName(filePath){
  if (!filePath) return '';
  const parts = String(filePath).split(/[\\\/]/);
  const fileName = parts[parts.length - 1] || '';
  return fileName.replace(/\.evm$/i, '');
}
/* Generated roof wireframe (top-down, from the latest rollback .evm). It is
   rendered as the first tile of the Images grid. Because loadReportImages()
   rewrites the grid, the tile is driven by wireframeState and re-applied
   after every grid rewrite, so the order the two requests finish in
   doesn't matter. */
function resetWireframe(){
  wireframeToken++;
  Object.keys(WF_TILES).forEach(kind => {
    const st = wireframeStates[kind];
    if (st && st.src) { try { URL.revokeObjectURL(st.src); } catch {} }
    wireframeStates[kind] = { status: 'idle', src: null, error: '', detail: '' };
    const el = document.getElementById(WF_TILES[kind].id);
    if (el) el.remove();
  });
}
// Twister reports: show Overlay (2D) / Wireframes (3D) placeholder boxes right away (before the EVM is located).
function markWireframePending(){
  Object.keys(WF_TILES).forEach(kind => { wireframeStates[kind] = { status: 'pending', src: null, error: '', detail: '' }; });
}
function setWireframeUnavailable(reason){
  Object.keys(WF_TILES).forEach(kind => {
    wireframeStates[kind] = { status: 'error', src: null, error: reason, detail: '' };
  });
}
// If the EVM can't be found, turn any still-pending placeholder into an "unavailable" tile.
function settleWireframe(reason){
  let changed = false;
  Object.keys(WF_TILES).forEach(kind => {
    const st = wireframeStates[kind];
    if (st && st.status === 'pending') {
      wireframeStates[kind] = { status: 'error', src: null, error: reason || 'No EVM file found', detail: '' };
      changed = true;
    }
  });
  if (changed) renderWireframeThumb();
}
function renderWireframeThumb(){
  const grid = document.getElementById('detailImagesGrid');
  if (!grid) return;
  // Order: top-down image, wireframe, overlay, then the remaining photos.
  let prev = grid.querySelector('.detail-topdown-thumb');
  Object.keys(WF_TILES).forEach(kind => {
    const cfg = WF_TILES[kind];
    const st = wireframeStates[kind] || { status: 'idle' };
    let el = document.getElementById(cfg.id);
    if (st.status === 'idle') { if (el) el.remove(); return; }
    if (!el) { el = document.createElement('div'); el.id = cfg.id; }
    grid.insertBefore(el, prev ? prev.nextSibling : grid.firstChild);
    prev = el;
    if (st.status === 'loading' || st.status === 'pending') {
      el.className = 'detail-image-thumb detail-feature-thumb detail-image-skel';
      el.title = cfg.loading;
      el.innerHTML = `<span class="detail-wireframe-badge">${cfg.label}</span><span class="detail-wireframe-loading-status" role="status" aria-live="polite">${cfg.loading}</span>`;
    } else if (st.status === 'error') {
      el.className = 'detail-image-thumb detail-feature-thumb detail-wireframe-error';
      el.title = st.detail || st.error || (cfg.label + ' unavailable');
      const reason = String(st.error || '');
      el.innerHTML = `<div><div>${cfg.label} unavailable</div><div class="detail-wireframe-reason">${escapeHtml(reason.length > 90 ? reason.slice(0, 90) + '…' : reason)}</div></div>`;
    } else {
      el.className = `detail-image-thumb detail-feature-thumb ${cfg.cls}`;
      el.title = kind === 'view3d' ? 'Wireframes (3D) - click to open and rotate' : cfg.label;
      el.innerHTML = `<img src="${st.src}" alt="${cfg.label}"><span class="detail-wireframe-badge">${cfg.label}</span>`;
    }
  });
  lockModalHeightToOverview();
}
function startWireframe(evmPath){
  if (!evmPath) return;
  const myToken = ++wireframeToken;
  Object.keys(WF_TILES).forEach(kind => {
    const old = wireframeStates[kind];
    if (old && old.src) { try { URL.revokeObjectURL(old.src); } catch {} }
    wireframeStates[kind] = { status: 'loading', src: null, error: '', detail: '' };
  });
  renderWireframeThumb();
  Object.keys(WF_TILES).forEach(kind => {
    fetch(`/api/wireframe?evm=${encodeURIComponent(evmPath)}${WF_TILES[kind].query}`)
      .then(r => {
        const type = r.headers.get('content-type') || '';
        if (r.ok && type.startsWith('image/')) return r.blob().then(b => ({ blob: b }));
        if (r.ok && kind === 'view3d' && type.includes('json')) return r.json().then(g => ({ geo: g }));
        return r.json().catch(() => ({})).then(j => ({
          error: (j && (j.error || j.message)) || `HTTP ${r.status}`,
          detail: (j && j.detail) || '',
          code: (j && j.code) || ''
        }));
      })
      .then(res => {
        if (myToken !== wireframeToken) return;
        if (res.blob) wireframeStates[kind] = { status: 'ready', src: URL.createObjectURL(res.blob), error: '', detail: '' };
        else if (res.geo) {
          let snap = '';
          try { snap = render3dSnapshot(res.geo); } catch {}
          if (snap && res.geo.P && res.geo.P.length) wireframeStates[kind] = { status: 'ready', src: snap, geo: res.geo, error: '', detail: '' };
          else wireframeStates[kind] = { status: 'error', src: null, error: 'No 3D geometry in this EVM', detail: '' };
        }
        else if (res.code === 'no-topdown') wireframeStates[kind] = { status: 'idle', src: null, error: '', detail: '' };
        else wireframeStates[kind] = { status: 'error', src: null, error: res.error, detail: res.detail || '' };
        {
          const st = wireframeStates[kind];
          parLog(st.status === 'error' ? 'warn' : (st.status === 'ready' ? 'ok' : 'info'),
            `${WF_TILES[kind].label}: ${st.status === 'idle' ? 'skipped (no top-down photo)' : st.status}${st.error ? ' - ' + st.error : ''}`);
        }
        renderWireframeThumb();
      })
      .catch(() => {
        if (myToken !== wireframeToken) return;
        wireframeStates[kind] = { status: 'error', src: null, error: "Couldn't reach the local wireframe service.", detail: '' };
        renderWireframeThumb();
      });
  });
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
        // Top-down (O_****_**.jpg) is featured first; the wireframe tile is
        // inserted right after it (see renderWireframeThumb), then the rest.
        // Each photo gets a badge like the Overlay (2D) / Wireframes (3D) tiles: Ortho (top), North, East, West, South.
        const imageLabels = Array.isArray(data.imageLabels) ? data.imageLabels : [];
        grid.innerHTML = data.images.map((src, idx) => {
          const isTop = !!data.topDown && src === data.topDown;
          const label = imageLabels[idx] || (isTop ? 'Ortho (top)' : '');
          return `
          <div class="detail-image-thumb${isTop ? ' detail-feature-thumb detail-topdown-thumb' : ''}">
            <img src="${src}" alt="${escapeHtml(label || (isTop ? 'Top-down image' : 'Report image'))}" loading="eager" decoding="async" fetchpriority="high" onerror="this.closest('.detail-image-thumb').classList.add('img-error');parLog('warn','Image failed to load: ${escapeHtml(label || 'image')}')">
            ${label ? `<span class="detail-wireframe-badge">${escapeHtml(label)}</span>` : ''}
          </div>`;
        }).join('');
        parLog('info', `Report ${reportId}: ${data.images.length} image(s) from ${data.folder || 'archive folder'}`);
      } else if (data && data.found) {
        if (status) status.textContent = '';
        if (folderNameEl) folderNameEl.textContent = data.folder || '';
        grid.innerHTML = `<div class="detail-images-empty">No images found in the Images subfolder.</div>`;
      } else {
        if (status) status.textContent = '';
        if (folderNameEl) folderNameEl.textContent = '';
        grid.innerHTML = `<div class="detail-images-empty">${escapeHtml((data && (data.message || data.error)) || 'No matching report folder found.')}</div>`;
      }
      renderWireframeThumb();
      lockModalHeightToOverview();
    })
    .catch(() => {
      if (myToken !== imageLoadToken) return;
      if (status) status.textContent = '';
      grid.innerHTML = `<div class="detail-images-empty">Couldn't reach the archive share. Check your network/VPN connection.</div>`;
      renderWireframeThumb();
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
    settleWireframe(message);
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
        parLog('ok', `EVM data for ${reportId}: rollback ${data.rollback || '?'}${data.cached ? ' (cached)' : ''}`);
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
        startWireframe(data.filePath);
        loadReportImages(reportId, locationName, evmBaseName);
      } else {
        // "No rollback found" isn't useful on its own — show the short
        // two-level box path (e.g. "2027JHTCT79\InProgress") instead so the
        // person can see exactly where the .evm was expected to be.
        const shortPath = data && data.searchedPath;
        parLog('warn', `EVM data for ${reportId}: ${(data && (data.searchedPath || data.message || data.error)) || 'not available'}`);
        const notFoundMessage = shortPath
          ? `EVM not found in ${shortPath}`
          : ((data && (data.message || data.error)) || 'File info not available.');
        const notesNotFoundMessage = shortPath
          ? `EVM not found in ${shortenPathForNotes(shortPath)}`
          : notFoundMessage;
        setFields(notFoundMessage, true);
        settleWireframe(notFoundMessage);
        if (hasReworkCount) setValue(notesEl, notesNotFoundMessage, true);
        // No filename to go on — fall back to the archive search by report ID.
        loadReportImages(reportId, locationName);
      }
    })
    .catch(() => {
      if (myToken !== fileInfoLoadToken) return;
      const message = "Couldn't reach the local file-info service.";
      setFields(message, true);
      settleWireframe(message);
      if (hasReworkCount) setValue(notesEl, message, true);
      loadReportImages(reportId, locationName);
    });
}
/* Wireframes (3D): rotatable wireframe drawn on a canvas from the geometry the server sends
   ({P: points, S: [i, j, segmentCode], colors, names}). Z is up; drag rotates, wheel zooms. */
/* Default = top-down, same orientation as the top-down wireframe image (x right, y down). */
const VIEW3D_DEFAULT = { yaw: 0, pitch: -Math.PI / 2, zoom: 1 };
const VIEW3D_DASHED = new Set(['StepFlashing', 'Rake', 'Valley', 'Hip']);
/* Facet-type flags the viewer can hide (Facets[].Type bits; a facet like Roof+Object+Hole = 672 is hidden if any of its flags is off). */
const VIEW3D_FLAGS = [['Hole', 32], ['Obstruction', 64], ['Object', 128], ['External', 256], ['Roof', 512], ['Wall', 1024], ['Floor', 2048], ['Unknown', 4096], ['Surface', 8192], ['Material', 16384]];
let view3dState = { geo: null, yaw: VIEW3D_DEFAULT.yaw, pitch: VIEW3D_DEFAULT.pitch, zoom: 1, panX: 0, panY: 0, hide: 0, shade: 1, auto: false, pts: true, labels: true, raf: 0 };
function view3dNormalize(geo){
  if (geo._q) return geo._q;
  const P = geo.P, lo = [0, 1, 2].map(k => Math.min(...P.map(p => p[k]))), hi = [0, 1, 2].map(k => Math.max(...P.map(p => p[k])));
  const c = lo.map((v, k) => (v + hi[k]) / 2), R = Math.max(...hi.map((v, k) => v - lo[k]), 1e-6) / 2;
  const nrm = p => [(p[0] - c[0]) / R, (p[1] - c[1]) / R, (p[2] - c[2]) / R];
  geo._q = P.map(nrm);
  geo._ql = (geo.F || []).map(f => nrm(f.l));   // pitch label positions, same normalisation
  return geo._q;
}
function drawView3d(ctx, w, h, geo, v, dpr){
  const Q = view3dNormalize(geo);
  const cy = Math.cos(v.yaw), sy = Math.sin(v.yaw), cp = Math.cos(v.pitch), sp = Math.sin(v.pitch);
  const sc = Math.min(w, h) * 0.42 * v.zoom;
  const proj = p => {
    const x = p[0] * cy - p[1] * sy, y = p[0] * sy + p[1] * cy, z = p[2];
    return [w / 2 + (v.panX || 0) * dpr + x * sc, h / 2 + (v.panY || 0) * dpr - (y * sp + z * cp) * sc, y * cp - z * sp];
  };
  const T = Q.map(proj);
  const hide = v.hide || 0;
  // A segment stays visible if it has no facet, or any facet using it has none of the hidden flags (shared edges stay).
  const segVisible = s => { if (!hide) return true; const fts = s[3]; return !fts || !fts.length || fts.some(t => (t & hide) === 0); };
  ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, w, h);
  ctx.lineCap = 'round'; ctx.lineWidth = 1.8 * dpr;
  // Material shading: facet outlines filled with their material colour (semi-transparent), far ones first.
  const sk = v.shade == null ? 1 : +v.shade;   // Shading slider: scales every fill's opacity (0 = off)
  if (sk > 0 && geo.A && geo.A.length) {
    const mc = geo.mat || {};
    // Floor facets (2048) get no shading; Roof (512) and Surface (8192) facets get a tint over the material colour.
    const polys = geo.A.filter(a => (mc[a[0]] || (a[1] & (32 | 512 | 8192))) && !(a[1] & 2048) && !(hide && (a[1] & hide)))
      .map(a => ({ a, d: a[2].reduce((sum, i) => sum + T[i][2], 0) / a[2].length }))
      .sort((p, q) => q.d - p.d);
    const matAs = geo.matAlphas || {}, roofA = geo.roofAlpha == null ? 0.25 : geo.roofAlpha, surfA = geo.surfAlpha == null ? 0.25 : geo.surfAlpha, holeA = geo.holeAlpha == null ? 0.25 : geo.holeAlpha;
    const al = x => Math.min(1, x * sk);
    const path = a => { ctx.beginPath(); a[2].forEach((i, k) => k ? ctx.lineTo(T[i][0], T[i][1]) : ctx.moveTo(T[i][0], T[i][1])); ctx.closePath(); };
    polys.forEach(({ a }) => {
      if (mc[a[0]]) { ctx.globalAlpha = al(matAs[a[0]] == null ? 0.25 : matAs[a[0]]); ctx.fillStyle = mc[a[0]]; path(a); ctx.fill(); }
      if (a[1] & 512) { ctx.globalAlpha = al(roofA); ctx.fillStyle = geo.roof || '#a8f5a8'; path(a); ctx.fill(); }   // Roof tint
      if (a[1] & 8192) { ctx.globalAlpha = al(surfA); ctx.fillStyle = geo.surf || '#f224e8'; path(a); ctx.fill(); }   // Surface tint
      if (a[1] & 32) { ctx.globalAlpha = al(holeA); ctx.fillStyle = geo.hole || '#808080'; path(a); ctx.fill(); }   // Hole: gray, on top
    });
    ctx.globalAlpha = 1; ctx.setLineDash([]);
  }
  geo.S.forEach(s => {
    if (!segVisible(s)) return;
    let [a, b, code] = s;
    // Floor outline (a segment of a visible Floor facet, flag 2048): gray dotted, like unspecified lines.
    const isFloor = !(hide & 2048) && (s[3] || []).some(t => (t & 2048) !== 0);
    if (isFloor) code = 0;
    // Hole outline (a segment of a visible Hole facet, flag 32): solid gray.
    const isHole = !isFloor && !(hide & 32) && (s[3] || []).some(t => (t & 32) !== 0);
    const depth = (T[a][2] + T[b][2]) / 2;
    const name = (geo.names || {})[code];
    ctx.strokeStyle = isHole ? (geo.hole || '#808080') : ((geo.colors || {})[code] || '#808080');
    ctx.globalAlpha = Math.max(0.35, Math.min(1, (code === 0 ? 0.6 : 1) - 0.25 * depth));
    ctx.setLineDash(code === 0 ? [2 * dpr, 3 * dpr] : (!isHole && VIEW3D_DASHED.has(name) ? [6 * dpr, 4 * dpr] : []));
    ctx.beginPath(); ctx.moveTo(T[a][0], T[a][1]); ctx.lineTo(T[b][0], T[b][1]); ctx.stroke();
  });
  ctx.setLineDash([]); ctx.globalAlpha = 1;
  let ptShown = null;
  if (hide) { ptShown = new Set(); geo.S.forEach(s => { if (segVisible(s)) { ptShown.add(s[0]); ptShown.add(s[1]); } }); }
  if (v.pts) { ctx.fillStyle = '#0a4d8c'; T.forEach((t, i) => { if (ptShown && !ptShown.has(i)) return; ctx.beginPath(); ctx.arc(t[0], t[1], 2.4 * dpr, 0, 6.2832); ctx.fill(); }); }
  if (v.labels && geo._ql && geo._ql.length) {
    // Pitch label on each finite-pitch facet (none for infinite pitch); a white halo keeps it readable over the lines.
    ctx.font = 'bold ' + Math.round(Math.max(10, Math.min(24, 12 * v.zoom)) * dpr) + 'px Arial, sans-serif';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.lineJoin = 'round'; ctx.lineWidth = 3.5 * dpr; ctx.strokeStyle = '#fff'; ctx.fillStyle = '#0a4d8c';
    geo._ql.forEach((p, i) => { if (hide && (geo.F[i].t & hide)) return; const t = proj(p); ctx.strokeText(geo.F[i].p, t[0], t[1]); ctx.fillText(geo.F[i].p, t[0], t[1]); });
  }
}
// Small still of the default view, used as the tile image.
function render3dSnapshot(geo){
  const cv = document.createElement('canvas');
  cv.width = 800; cv.height = 600;
  drawView3d(cv.getContext('2d'), cv.width, cv.height, geo, { yaw: VIEW3D_DEFAULT.yaw, pitch: VIEW3D_DEFAULT.pitch, zoom: 1, pts: false, labels: true }, 1.5);
  return cv.toDataURL('image/png');
}
function view3dRedraw(){
  const cv = document.getElementById('view3dCanvas');
  if (!cv || !view3dState.geo) return;
  const dpr = window.devicePixelRatio || 1;
  const w = Math.round(cv.clientWidth * dpr), h = Math.round(cv.clientHeight * dpr);
  if (cv.width !== w || cv.height !== h) { cv.width = w; cv.height = h; }
  drawView3d(cv.getContext('2d'), w, h, view3dState.geo, view3dState, dpr);
}
function view3dLoop(){
  const st = view3dState;
  if (st.auto) { st.yaw += 0.006; view3dRedraw(); }
  st.raf = requestAnimationFrame(view3dLoop);
}
// One on/off button per facet-type flag that occurs in this model, placed before "Reset view".
function view3dBuildFlagButtons(geo){
  const bar = document.querySelector('.view3d-toolbar');
  if (!bar) return;
  bar.querySelectorAll('.view3d-flag').forEach(b => b.remove());
  const types = new Set();
  (geo.S || []).forEach(s => (s[3] || []).forEach(t => types.add(t)));
  (geo.F || []).forEach(f => types.add(f.t || 0));
  VIEW3D_FLAGS.forEach(([name, bit]) => {
    if (![...types].some(t => t & bit)) return;
    const b = document.createElement('button');
    b.type = 'button'; b.className = 'view3d-flag'; b.textContent = name + ': on'; b.title = 'Show/hide ' + name + ' facets';
    b.addEventListener('click', () => {
      view3dState.hide ^= bit;
      const off = (view3dState.hide & bit) !== 0;
      b.textContent = name + ': ' + (off ? 'off' : 'on'); b.classList.toggle('off', off);
      view3dRedraw();
    });
    bar.appendChild(b);
  });
}
function openView3dViewer(){
  const st = wireframeStates.view3d;
  const el = document.getElementById('view3dViewer');
  if (!el || !st || st.status !== 'ready' || !st.geo) return;
  Object.assign(view3dState, { geo: st.geo, yaw: VIEW3D_DEFAULT.yaw, pitch: VIEW3D_DEFAULT.pitch, zoom: 1, panX: 0, panY: 0, hide: 0, shade: 1, auto: false });
  document.getElementById('view3dSpin').textContent = 'Auto-rotate: off';
  { const sl = document.getElementById('view3dShade'), sv = document.getElementById('view3dShadeVal'); if (sl) sl.value = 100; if (sv) sv.textContent = '100%'; }
  view3dBuildFlagButtons(st.geo);
  el.classList.add('open'); el.setAttribute('aria-hidden', 'false');
  view3dRedraw();
  if (!view3dState.raf) view3dLoop();
  parLog('info', `Wireframes (3D) opened (${st.geo.P.length} points, ${st.geo.S.length} segments)`);
}
function closeView3dViewer(){ hideView3dViewer(); closeImageLightbox(); }
function hideView3dViewer(){
  const el = document.getElementById('view3dViewer');
  if (!el) return;
  el.classList.remove('open'); el.setAttribute('aria-hidden', 'true');
  if (view3dState.raf) { cancelAnimationFrame(view3dState.raf); view3dState.raf = 0; }
}
function wireView3dViewer(){
  const el = document.getElementById('view3dViewer'), cv = document.getElementById('view3dCanvas');
  if (!el || !cv) return;
  const st = view3dState, pointers = new Map();
  let last = null, pinch = 0;
  document.getElementById('view3dClose')?.addEventListener('click', closeView3dViewer);
  document.getElementById('view3dPrev')?.addEventListener('click', () => stepImageLightbox(-1));
  document.getElementById('view3dNext')?.addEventListener('click', () => stepImageLightbox(1));
  // Right-drag pans here: block the native menu and the page's Refresh menu (stopPropagation keeps it from the document-level handler).
  el.addEventListener('contextmenu', e => { e.preventDefault(); e.stopPropagation(); });
  el.addEventListener('click', e => { if (e.target === el) closeView3dViewer(); });
  document.getElementById('view3dSpin')?.addEventListener('click', e => { st.auto = !st.auto; e.currentTarget.textContent = 'Auto-rotate: ' + (st.auto ? 'on' : 'off'); });
  document.getElementById('view3dPts')?.addEventListener('click', e => { st.pts = !st.pts; e.currentTarget.textContent = 'Points: ' + (st.pts ? 'on' : 'off'); view3dRedraw(); });
  document.getElementById('view3dShade')?.addEventListener('input', e => { st.shade = e.currentTarget.value / 100; const sv = document.getElementById('view3dShadeVal'); if (sv) sv.textContent = e.currentTarget.value + '%'; view3dRedraw(); });
  document.getElementById('view3dLbl')?.addEventListener('click', e => { st.labels = !st.labels; e.currentTarget.textContent = 'Pitch: ' + (st.labels ? 'on' : 'off'); view3dRedraw(); });
  const reset = () => { st.yaw = VIEW3D_DEFAULT.yaw; st.pitch = VIEW3D_DEFAULT.pitch; st.zoom = 1; st.panX = 0; st.panY = 0; view3dRedraw(); };
  document.getElementById('view3dReset')?.addEventListener('click', reset);
  cv.addEventListener('dblclick', reset);
  let panning = false;   // true while the right mouse button is held
  cv.addEventListener('pointerdown', e => { cv.setPointerCapture(e.pointerId); pointers.set(e.pointerId, [e.clientX, e.clientY]); last = [e.clientX, e.clientY]; panning = e.button === 2; cv.classList.add('dragging'); });
  cv.addEventListener('pointermove', e => {
    if (!pointers.has(e.pointerId)) return;
    pointers.set(e.pointerId, [e.clientX, e.clientY]);
    if (pointers.size === 2) {
      const [a, b] = [...pointers.values()], d = Math.hypot(a[0] - b[0], a[1] - b[1]);
      if (pinch) st.zoom = Math.min(8, Math.max(0.3, st.zoom * d / pinch));
      pinch = d; view3dRedraw(); return;
    }
    if (panning) { st.panX += e.clientX - last[0]; st.panY += e.clientY - last[1]; }
    else {
      st.yaw -= (e.clientX - last[0]) * 0.008;   // inverted: model turns opposite to the mouse
      st.pitch = Math.max(-Math.PI / 2, Math.min(Math.PI / 2, st.pitch - (e.clientY - last[1]) * 0.008));
    }
    last = [e.clientX, e.clientY]; view3dRedraw();
  });
  const up = e => { pointers.delete(e.pointerId); pinch = 0; last = pointers.size ? [...pointers.values()][0] : null; if (!pointers.size) cv.classList.remove('dragging'); };
  cv.addEventListener('pointerup', up); cv.addEventListener('pointercancel', up);
  cv.addEventListener('wheel', e => { e.preventDefault(); st.zoom = Math.min(8, Math.max(0.3, st.zoom * Math.exp(-e.deltaY * 0.0015))); view3dRedraw(); }, { passive: false });
  window.addEventListener('resize', () => { if (el.classList.contains('open')) view3dRedraw(); });
}
/* Image preview (lightbox). Left/Right arrow keys (or the on-screen < > buttons) step through
   every visible tile of the Images grid in grid order, wrapping around:
   Ortho (top) -> Overlay (2D) -> North -> East -> West -> South.
   (The Wireframes (3D) tile opens its own rotatable viewer and is not part of this sequence.) */
let lightboxSrc = '';
let lightboxIndex = 0;
function getLightboxItems(){
  const grid = document.getElementById('detailImagesGrid');
  if (!grid) return [];
  return Array.from(grid.querySelectorAll('.detail-image-thumb:not(.img-error) img'))
    .filter(img => img.getAttribute('src'))
    .map(img => {
      const badge = img.parentElement && img.parentElement.querySelector('.detail-wireframe-badge');
      return { src: img.getAttribute('src'), label: badge ? badge.textContent.trim() : '', is3d: !!img.closest('.detail-view3d-thumb') };
    });
}
function showLightboxItem(item, index, total){
  const img = document.getElementById('imageLightboxImg');
  const cap = document.getElementById('imageLightboxCaption');
  if (!img || !item) return;
  lightboxSrc = item.src;
  lightboxIndex = index;
  resetLightboxZoom();
  if (item.is3d) openView3dViewer(); else hideView3dViewer();   // 3D view is shown on top of the preview
  img.src = item.src;
  img.alt = item.label || 'Report image full size';
  if (cap) {
    const parts = [];
    if (item.label) parts.push(item.label);
    if (total > 1) parts.push(`${index + 1} / ${total}`);
    cap.textContent = parts.join('  ·  ');
    cap.style.display = parts.length ? '' : 'none';
  }
  if (item.is3d) {
    const cap3 = document.getElementById('view3dCaption');
    if (cap3) cap3.textContent = 'Wireframes (3D)  ·  drag to rotate  ·  right-drag to pan  ·  scroll to zoom  ·  double-click to reset' + (total > 1 ? `  ·  ${index + 1} / ${total}` : '');
  }
  document.querySelectorAll('.image-lightbox-nav').forEach(b => { b.style.display = total > 1 ? '' : 'none'; });
}
function openImageLightbox(src){
  const lb  = document.getElementById('imageLightbox');
  const img = document.getElementById('imageLightboxImg');
  if (!lb || !img) return;
  const items = getLightboxItems();
  const idx = items.findIndex(it => it.src === src);
  showLightboxItem(idx >= 0 ? items[idx] : { src: src, label: '' }, Math.max(idx, 0), idx >= 0 ? items.length : 1);
  lb.classList.add('open');
  lb.setAttribute('aria-hidden', 'false');
  parLog('info', `Preview opened: ${idx >= 0 && items[idx].label ? items[idx].label : 'image'} (${Math.max(idx, 0) + 1}/${items.length || 1})`);
}
function stepImageLightbox(delta){
  const lb = document.getElementById('imageLightbox');
  if (!lb || !lb.classList.contains('open')) return;
  const items = getLightboxItems();
  if (items.length < 2) return;
  let idx = items.findIndex(it => it.src === lightboxSrc);
  if (idx < 0) idx = Math.min(lightboxIndex, items.length - 1);
  idx = (idx + delta + items.length) % items.length;
  showLightboxItem(items[idx], idx, items.length);
  parLog('info', `Preview: ${items[idx].label || 'image'} (${idx + 1}/${items.length})`);
  // Warm the neighbours so the next arrow press is instant.
  [1, -1].forEach(d => { const n = items[(idx + d + items.length) % items.length]; if (n) { const pre = new Image(); pre.src = n.src; } });
}
function closeImageLightbox(){
  const lb = document.getElementById('imageLightbox');
  if (!lb) return;
  lb.classList.remove('open');
  lb.setAttribute('aria-hidden', 'true');
  hideView3dViewer();
  lightboxSrc = '';
  resetLightboxZoom();
  const img = document.getElementById('imageLightboxImg');
  if (img) img.src = '';
}
/* Mouse wheel zooms the preview toward the cursor (1x-8x); drag pans while zoomed; double-click resets. */
let lbZoom = { s: 1, x: 0, y: 0 };
let lightboxDragged = false;
function applyLightboxZoom(){
  const img = document.getElementById('imageLightboxImg');
  if (!img) return;
  img.style.transform = (lbZoom.s === 1 && !lbZoom.x && !lbZoom.y) ? '' : `translate(${lbZoom.x}px, ${lbZoom.y}px) scale(${lbZoom.s})`;
  img.classList.toggle('zoomed', lbZoom.s > 1);
}
function resetLightboxZoom(){ lbZoom = { s: 1, x: 0, y: 0 }; applyLightboxZoom(); }
function zoomLightboxAt(clientX, clientY, factor){
  const lb = document.getElementById('imageLightbox');
  if (!lb) return;
  const r  = lb.getBoundingClientRect();
  const cx = r.left + r.width / 2, cy = r.top + r.height / 2;   // the image is centred in the lightbox
  const s0 = lbZoom.s;
  const s1 = Math.min(8, Math.max(1, s0 * factor));
  if (s1 === s0) return;
  if (s1 === 1) lbZoom = { s: 1, x: 0, y: 0 };
  else {
    const k = s1 / s0;
    lbZoom = { s: s1, x: (clientX - cx) - k * (clientX - cx - lbZoom.x), y: (clientY - cy) - k * (clientY - cy - lbZoom.y) };
  }
  applyLightboxZoom();
}
function closeReportDetailModal(){
  const overlay = document.getElementById('reportDetailOverlay');
  if (!overlay) return;
  overlay.classList.remove('open');
  overlay.setAttribute('aria-hidden', 'true');
  closeImageLightbox();
  imageLoadToken++;
  fileInfoLoadToken++;
  resetWireframe();
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
    # TEMP: now resolves fileinfo.py (run through Python) instead of fileinfo.exe.
    # Variable/function names are unchanged so it is easy to switch back later.
    $cacheDir   = Join-Path $env:LOCALAPPDATA 'PAR-App\fileinfo'
    $localExe   = Join-Path $cacheDir 'fileinfo.py'
    $remoteExe  = 'P:\1_Coordinators\PIA\fileinfo\fileinfo.py'
    if (-not (Test-Path -LiteralPath $remoteExe -PathType Leaf)) {
        # Also accept the script sitting next to the old exe location.
        $alt = 'P:\1_Coordinators\PIA\fileinfo.py'
        $remoteExe = if (Test-Path -LiteralPath $alt -PathType Leaf) { $alt } else { $null }
    }
    if (-not $remoteExe) {
        # Share unreachable / script missing - fall back to any already-cached
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
        # Copy failed (offline, permissions, etc.) - use whatever's cached, if anything.
    }
    if (Test-Path -LiteralPath $localExe -PathType Leaf) { return $localExe }
    return $null
}
# Finds a working Python interpreter for fileinfo.py. Candidates come from PATH,
# the py launcher, and common per-user / system install folders. Each candidate
# is actually run: it must start and be able to import scipy + numpy. If none
# have the packages, the first one that merely runs is returned (the error from
# the missing package then shows up in the File Info output instead of a
# generic "Python not found"). Microsoft Store stubs fail the run test and are
# skipped automatically; a real Store-installed Python is accepted.
function Get-PythonExeLocal {
    # Native stderr (warnings, Store-stub messages) must not become terminating
    # errors here, even though the script-level preference is 'Stop'.
    $ErrorActionPreference = 'Continue'
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($name in 'python', 'python3', 'py') {
        foreach ($cmd in @(Get-Command $name -CommandType Application -ErrorAction SilentlyContinue)) {
            if ($cmd.Source) { $candidates.Add($cmd.Source) }
        }
    }
    $globs = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python3*\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\python3.exe'),
        (Join-Path $env:ProgramFiles 'Python3*\python.exe'),
        'C:\Python3*\python.exe',
        'C:\ProgramData\anaconda3\python.exe',
        'C:\ProgramData\miniconda3\python.exe',
        (Join-Path $env:USERPROFILE 'anaconda3\python.exe'),
        (Join-Path $env:USERPROFILE 'miniconda3\python.exe'),
        (Join-Path $env:WINDIR 'py.exe')
    )
    foreach ($g in $globs) {
        foreach ($f in @(Get-ChildItem -Path $g -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) {
            $candidates.Add($f.FullName)
        }
    }
    # Preference order: scipy+numpy+matplotlib (fileinfo + wireframe both work)
    # > scipy+numpy (fileinfo only) > any Python 3 that runs.
    $noMpl = $null
    $firstRunnable = $null
    foreach ($exe in ($candidates | Select-Object -Unique)) {
        try {
            $out = (& $exe -c "import scipy, numpy, matplotlib; print('PAR_OK')" 2>&1 | Out-String)
            if ($LASTEXITCODE -eq 0 -and $out -match 'PAR_OK') { return $exe }
            if (-not $noMpl) {
                $out = (& $exe -c "import scipy, numpy; print('PAR_OK')" 2>&1 | Out-String)
                if ($LASTEXITCODE -eq 0 -and $out -match 'PAR_OK') { $noMpl = $exe; continue }
            }
            if (-not $firstRunnable) {
                $ver = (& $exe --version 2>&1 | Out-String)
                if ($LASTEXITCODE -eq 0 -and $ver -match 'Python 3') { $firstRunnable = $exe }
            }
        }
        catch { }
    }
    if ($noMpl) { return $noMpl }
    return $firstRunnable
}
# Same share-to-local-cache idea as Get-FileInfoExeLocal, for any helper script
# kept next to fileinfo.py on the PIA share (e.g. roof_wireframe.py).
function Get-PiaScriptLocal {
    param([Parameter(Mandatory)][string]$FileName)
    $cacheDir = Join-Path $env:LOCALAPPDATA 'PAR-App\fileinfo'
    $local    = Join-Path $cacheDir $FileName
    $remote   = $null
    foreach ($p in @("P:\1_Coordinators\PIA\fileinfo\$FileName", "P:\1_Coordinators\PIA\$FileName")) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { $remote = $p; break }
    }
    if ($remote) {
        try {
            $needsCopy = (-not (Test-Path -LiteralPath $local -PathType Leaf)) -or
                         ((Get-Item -LiteralPath $remote).LastWriteTime -gt (Get-Item -LiteralPath $local).LastWriteTime)
            if ($needsCopy) {
                New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
                Copy-Item -LiteralPath $remote -Destination $local -Force
            }
        }
        catch { }
    }
    if (Test-Path -LiteralPath $local -PathType Leaf) { return $local }
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
    Write-ParLog "Couldn't start the local server on ${prefix}: $($_.Exception.Message)" 'ERROR' 'server'
    [System.Windows.MessageBox]::Show(
        "Couldn't start the local server on ${prefix}:`n$($_.Exception.Message)",
        'PAR — startup failed', 'OK', 'Error') | Out-Null
    exit 1
}
Write-ParLog "Local server listening on $prefix" 'OK' 'server'
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
$PythonExeLocal   = Get-PythonExeLocal
if ($FileInfoExeLocal) { Write-ParLog "fileinfo script: $FileInfoExeLocal" 'INFO' 'startup' }
else { Write-ParLog 'fileinfo script NOT found (P:\1_Coordinators\PIA\fileinfo\fileinfo.py) - EVM Data will be unavailable' 'WARN' 'startup' }
if ($PythonExeLocal) { Write-ParLog "python: $PythonExeLocal" 'INFO' 'startup' }
else { Write-ParLog 'Python 3 NOT found - EVM Data and wireframes will be unavailable' 'WARN' 'startup' }
$WireframePyText = @'
#!/usr/bin/env python3
"""Generate a top-down roof wireframe image from an .evm file (a renamed MATLAB .mat file).

Usage:
    python roof_wireframe.py job.evm
    python roof_wireframe.py job.evm -o roof.png --no-pitch --dpi 200
    python roof_wireframe.py job.evm -o overlay.png --overlay O_1234_01.jpg
    python roof_wireframe.py job.evm -v        # extra (debug) logging
    python roof_wireframe.py job.evm -q        # warnings/errors only
    python roof_wireframe.py job.evm --json3d -o job_3d.json   # 3D geometry for the PAR "3D View" tile

Progress is logged to the terminal (stdout) with timestamps.

--json3d writes the 3D geometry (points + typed segments + a pitch label per facet,
Z reversed so the roof sits upright) as JSON instead of a PNG. Unlike the top-down
image it keeps the edges of facets with an infinite pitch (but gives them no label); PAR renders it as a rotatable 3D view.

--overlay draws the wireframe on top of the given top-down photo. The model
units are image pixels (Units == 'pixels', ImageData[0] has a ~identity
transform), so model x/y are used directly as photo pixel coordinates. If the
photo was exported at a different resolution than the tool's working image, use
--scale (e.g. 2 if the photo is twice as large).

Requires: numpy, scipy, matplotlib
"""
import argparse
import json
import logging
import sys
import time

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import scipy.io as sio
from matplotlib.path import Path

log = logging.getLogger("roof_wireframe")

# Edge classification comes from each segment's LegacyUserTypeOverride code
# (same codes as SegmentLabels.Style). Mapping inferred from the file's geometry.
SEG_NAMES = {0: "Unspecified", 19: "Parapet", 18: "Flashing", 17: "StepFlashing", 16: "Rake",
             15: "Eave", 14: "Valley", 13: "Ridge", 12: "Hip", 11: "Other",
             10: "Hidden", 64: "Inside Corner", 65: "Outside Corner",
             66: "Obtuse Inside Corner", 67: "Obtuse Outside Corner", 68: "Top Wall", 69: "Bottom Wall",
             70: "Material Horizontal Boundary", 71: "Material Vertical Boundary",
             72: "Material Oblique Boundary", 73: "Material Top", 74: "Material Bottom",
             75: "Material Inside Corner", 76: "Material Outside Corner",
             77: "Material Obtuse Inside Corner", 78: "Material Obtuse Outside Corner",
             100: "Isoline"}
SEG_COLORS = {0: "#808080", 19: "#7a0fe3", 18: "#c88c28", 17: "#a06000", 16: "#1a991a",
              15: "#000000", 14: "#0000ff", 13: "#ff0000", 12: "#ff00ff",
              11: "#ff99c7", 10: "#ffff00",   # Hidden
              64: "#00ffff", 65: "#a80000",   # Inside Corner / Outside Corner
              66: "#00ff00", 67: "#ff00ff",   # Obtuse Inside Corner / Obtuse Outside Corner
              68: "#0000cc", 69: "#006666",   # Top Wall / Bottom Wall (wall edges)
              70: "#00aaee", 71: "#c55500", 72: "#aa00ee",   # Material Horizontal / Vertical / Oblique Boundary
              73: "#0000cc", 74: "#009944",   # Material Top / Material Bottom
              75: "#00ffff", 76: "#a80000",   # Material Inside Corner / Outside Corner
              77: "#00ff00", 78: "#e200aa",   # Material Obtuse Inside Corner / Obtuse Outside Corner
              100: "#666600"}   # Isoline

# Dashed vs solid per edge type; unspecified gray segments use dotted lines.
DASHED = {"StepFlashing", "Rake", "Valley", "Hip"}

def line_style(code):
    if code == UNSPECIFIED_CODE:
        return ":"
    return "--" if SEG_NAMES[code] in DASHED else "-"
UNSPECIFIED_CODE = 0  # no/unrecognised edge type: drawn dotted gray (kept distinct from "Other", code 11)

# Material shading of facets in the 3D view (Facets[].MaterialID -> colour, drawn at MATERIAL_ALPHAS opacity).
MATERIAL_NAMES = {1: "None", 2: "Siding", 3: "Masonry"}
MATERIAL_COLORS = {1: "#bfb28c", 2: "#bfbf95", 3: "#70aca2"}
# Opacity per material (opacity = 1 - transparency): all three are 75% transparent.
MATERIAL_ALPHAS = {1: 0.25, 2: 0.25, 3: 0.25}
# Facets with the Roof flag (512) get this tint on top of the material shading.
ROOF_COLOR = "#a8f5a8"
ROOF_ALPHA = 0.25  # 75% transparent
# Hole facets (flag 32): gray lines, plus a gray tint (75% transparent) over the shading.
HOLE_COLOR = "#808080"
HOLE_ALPHA = 0.25
# Floor facets (flag 2048) get no shading and no pitch label.
FLOOR_FLAG = 2048
# Facets with the Surface flag (8192) get this tint on top of the material shading.
SURFACE_COLOR = "#f224e8"
SURFACE_ALPHA = 0.25  # 75% transparent

# Pitch labels shrink to fit their facet, starting at a compact size.
PITCH_FONT_MAX = 5.0
PITCH_FONT_MIN = 1.5
PITCH_FONT_STEP = 0.25
PITCH_FIT_MARGIN_PT = 0.25  # small clearance around the text (points)
PITCH_MAX_CANDIDATES = 30   # centre positions tried per facet

# Overlay look (drawn over the photo).
OVERLAY_LINE_WIDTH = 1.6


def segment_code(s):
    """Edge-type code of a segment (a key of SEG_NAMES; UNSPECIFIED_CODE if unknown)."""
    code = s.LegacyUserTypeOverride
    code = int(code) if np.isscalar(code) and np.isfinite(code) else UNSPECIFIED_CODE
    if code not in SEG_NAMES or code == UNSPECIFIED_CODE:
        # no usable override: corner/wall edges are still recognisable from the segment's own Type
        t = getattr(s, "Type", None)
        if np.isscalar(t) and np.isfinite(t) and int(t) in (64, 65, 66, 67, 68, 69):
            return int(t)
        return UNSPECIFIED_CODE
    return code


def load_geometry(path, omit_infinite=True):
    """Return (points Nx3 array, list of (segment_type, [i, j]) with 0-based indices)."""
    # .evm files are renamed .mat files; open as a file object so the extension doesn't matter
    log.info("Loading %s", path)
    t0 = time.perf_counter()
    with open(path, "rb") as fh:
        mat = sio.loadmat(fh, struct_as_record=False, squeeze_me=True)
    if "ThisStructure" not in mat:
        sys.exit("No 'ThisStructure' variable found in the .evm file.")
    ts = mat["ThisStructure"]
    pts = np.array([[p.x, p.y, p.z] for p in np.atleast_1d(ts.Points)], dtype=float)
    segs = []
    for s in np.atleast_1d(ts.Segments):
        idx = np.atleast_1d(s.Contains).astype(int) - 1  # MATLAB is 1-based
        if len(idx) != 2:
            segs.append((UNSPECIFIED_CODE, None))  # placeholder keeps facet segment indices aligned
            continue
        segs.append((segment_code(s), idx))
    facets = []
    facet_types = []  # Facets[].Type bit flags (Roof=512, Wall=1024, Material=16384, ...), parallel to facets
    facet_materials = []  # Facets[].MaterialID (1 None, 2 Siding, 3 Masonry), parallel to facets
    for f in np.atleast_1d(ts.Facets):
        seg_ids = np.atleast_1d(f.Contains).astype(int) - 1  # segment indices (1-based in file)
        pitch = f.Pitch if np.isscalar(f.Pitch) else np.nan
        facets.append((seg_ids, float(pitch)))
        ft = np.asarray(getattr(f, "Type", 0)).ravel()
        facet_types.append(int(ft[0]) if ft.size and np.isfinite(ft[0]) else 0)
        fm = np.asarray(getattr(f, "MaterialID", 0)).ravel()
        facet_materials.append(int(fm[0]) if fm.size and np.isfinite(fm[0]) else 0)
    if omit_infinite:  # the 3D view keeps infinite-pitch facets
        segs = omit_infinite_pitch_facet_segments(segs, facets)
    n_seg = sum(1 for _, ix in segs if ix is not None)
    log.info("Loaded %d points, %d segments, %d facets in %.2fs",
             len(pts), n_seg, len(facets), time.perf_counter() - t0)
    return pts, segs, facets, facet_types, facet_materials


def omit_infinite_pitch_facet_segments(segs, facets):
    """Hide edges used only by facets whose pitch is infinite, preserving shared edges."""
    infinite_ids = set()
    other_ids = set()
    for seg_ids, pitch in facets:
        target = infinite_ids if np.isinf(pitch) else other_ids
        target.update(int(k) for k in seg_ids if 0 <= int(k) < len(segs))
    omitted_ids = infinite_ids - other_ids
    if omitted_ids:
        segs = [
            (stype, None if i in omitted_ids else ix)
            for i, (stype, ix) in enumerate(segs)
        ]
        log.info("Omitted %d segments belonging only to infinite-pitch facets", len(omitted_ids))
    return segs


def facet_polygon(seg_ids, segs_xy):
    """Chain a facet's segments into an ordered vertex loop (list of point indices)."""
    edges = [tuple(segs_xy[k]) for k in seg_ids if 0 <= k < len(segs_xy) and len(segs_xy[k]) == 2]
    if not edges:
        return []
    loop = list(edges[0])
    remaining = edges[1:]
    while remaining:
        for e in remaining:
            if e[0] == loop[-1]:
                loop.append(e[1]); remaining.remove(e); break
            if e[1] == loop[-1]:
                loop.append(e[0]); remaining.remove(e); break
        else:
            break  # open/broken chain
    if len(loop) > 1 and loop[0] == loop[-1]:
        loop.pop()
    return loop


def label_candidates(poly, n=60, max_candidates=PITCH_MAX_CANDIDATES):
    """Points inside the polygon, best (furthest from the edges) first.

    Returns an (k, 2) array. The first row is the point furthest from every edge
    (as far as a coarse grid search finds); the rest are other well-inside points
    so a wide label can slide along an elongated facet.
    """
    path = Path(poly)
    lo, hi = poly.min(0), poly.max(0)
    gx, gy = np.meshgrid(np.linspace(lo[0], hi[0], n), np.linspace(lo[1], hi[1], n))
    grid = np.c_[gx.ravel(), gy.ravel()]
    grid = grid[path.contains_points(grid)]
    if len(grid) == 0:
        return poly.mean(0)[None, :]
    a, b = poly, np.roll(poly, -1, axis=0)
    ab = b - a
    denom = np.maximum((ab ** 2).sum(1), 1e-12)
    ap = grid[:, None, :] - a[None, :, :]                       # (G, E, 2)
    t = np.clip((ap * ab[None]).sum(2) / denom[None], 0, 1)     # (G, E)
    nearest = a[None] + t[..., None] * ab[None]
    d = np.linalg.norm(grid[:, None, :] - nearest, axis=2).min(1)
    order = np.argsort(-d)
    order = order[d[order] >= 0.5 * d[order[0]]]
    if len(order) > max_candidates:
        order = order[np.unique(np.r_[0, np.linspace(0, len(order) - 1, max_candidates).astype(int)])]
    return grid[order]


def label_point(poly):
    """A point inside the polygon, as far from its edges as a coarse grid search finds."""
    return label_candidates(poly)[0]


def box_fits(path, poly, cx, cy, hw, hh, samples=10):
    """True if the axis-aligned box centred on (cx, cy) lies fully inside the polygon."""
    xs = np.linspace(cx - hw, cx + hw, samples)
    ys = np.linspace(cy - hh, cy + hh, samples)
    ring = np.r_[np.c_[xs, np.full_like(xs, cy - hh)], np.c_[xs, np.full_like(xs, cy + hh)],
                 np.c_[np.full_like(ys, cx - hw), ys], np.c_[np.full_like(ys, cx + hw), ys]]
    if not path.contains_points(ring).all():
        return False
    # a polygon corner poking into the box means a notch/line would be covered
    poking = (np.abs(poly[:, 0] - cx) < hw) & (np.abs(poly[:, 1] - cy) < hh)
    return not poking.any()


def fit_pitch_label(poly, text, size_units, max_fontsize=PITCH_FONT_MAX):
    """Pick (x, y, fontsize, fitted) for a pitch label.

    Tries the default font size first and only steps down when the label can't be
    placed fully inside the facet. size_units(text, fontsize) -> (width, height)
    of the label (including its background box) in data units.
    """
    path = Path(poly)
    cands = label_candidates(poly)
    sizes = np.arange(max_fontsize, PITCH_FONT_MIN - 1e-9, -PITCH_FONT_STEP)
    for fs in sizes:
        w, h = size_units(text, float(fs))
        for cx, cy in cands:
            if box_fits(path, poly, cx, cy, w / 2, h / 2):
                return float(cx), float(cy), float(fs), True
    cx, cy = cands[0]
    return float(cx), float(cy), float(sizes[-1]), False


def fmt_pitch(p):
    p = round(float(p), 1)
    return f"{p:g}"


def draw_pitch_labels(fig, ax, pts, segs, facets, max_fontsize=PITCH_FONT_MAX, facet_types=None):
    """Draw each facet's pitch, shrinking only when it won't fit."""
    renderer = fig.canvas.get_renderer()
    p0 = ax.transData.transform((0.0, 0.0))
    p1 = ax.transData.transform((1.0, 0.0))
    pt_per_unit = abs(p1[0] - p0[0]) * 72.0 / fig.dpi  # points per data unit (aspect is equal)
    can_fit = bool(np.isfinite(pt_per_unit) and pt_per_unit > 0)
    if not can_fit:
        log.warning("Could not work out the drawing scale; pitch labels use the default size")

    cache = {}

    def size_units(text, fs):
        key = (text, fs)
        if key not in cache:
            t = ax.text(0, 0, text, fontsize=fs, fontweight="bold", fontfamily="Arial")
            bb = t.get_window_extent(renderer)
            t.remove()
            margin = PITCH_FIT_MARGIN_PT
            cache[key] = ((bb.width * 72.0 / fig.dpi + margin) / pt_per_unit,
                          (bb.height * 72.0 / fig.dpi + margin) / pt_per_unit)
        return cache[key]

    segs_xy = [tuple(ix) if ix is not None else () for _, ix in segs]
    drawn = shrunk = tight = skipped = 0
    for n, (seg_ids, pv) in enumerate(facets, start=1):
        if facet_types is not None and (facet_types[n - 1] & FLOOR_FLAG):  # Floor facets get no pitch label
            skipped += 1
            continue
        if not np.isfinite(pv):  # nan or +/-inf pitch: nothing sensible to show
            skipped += 1
            continue
        facet_line_ids = [
            int(k) for k in seg_ids
            if 0 <= int(k) < len(segs) and segs[int(k)][1] is not None
        ]
        if pv == 0 and facet_line_ids and all(segs[k][0] == UNSPECIFIED_CODE for k in facet_line_ids):
            log.debug("Facet %d: zero pitch hidden because all outline lines are gray", n)
            skipped += 1
            continue
        loop = facet_polygon(seg_ids, segs_xy)
        if len(loop) < 3 or np.isnan(pts[loop]).any():
            log.debug("Facet %d: no usable outline, pitch label skipped", n)
            skipped += 1
            continue
        poly = pts[loop][:, :2]
        text = fmt_pitch(pv)
        if can_fit:
            x, y, fs, fitted = fit_pitch_label(poly, text, size_units, max_fontsize)
        else:
            x, y = label_point(poly)
            fs, fitted = max_fontsize, True
        if fs < max_fontsize:
            shrunk += 1
            log.info("Facet %d: pitch %s shrunk %.1f -> %.1f pt to fit", n, text, max_fontsize, fs)
        if not fitted:
            tight += 1
            log.warning("Facet %d: pitch %s still does not fit at %.1f pt (facet is very small)", n, text, fs)
        ax.text(x, y, text, ha="center", va="center", fontsize=fs,
                fontweight="bold", fontfamily="Arial", color="#0a4d8c", zorder=4)
        drawn += 1
    log.info("Pitch labels: %d drawn, %d shrunk, %d too small even at minimum, %d skipped",
             drawn, shrunk, tight, skipped)


def plot_top_down(pts, segs, facets, out_path, pitch=True, dpi=300, match_image=None, facet_types=None):
    ok = ~np.isnan(pts).any(axis=1)
    if match_image:
        import matplotlib.image as mpimg

        h, w = mpimg.imread(match_image).shape[:2]
        k = min(3.0, 4200 / max(w, h))
        pitch_max_fontsize = PITCH_FONT_MAX * max(1.0, min(3.0, max(w * k, h * k) / 1400))
        figsize = (w * k / dpi, h * k / dpi)
    else:
        pitch_max_fontsize = PITCH_FONT_MAX
        figsize = (9, 9)
    fig, ax = plt.subplots(figsize=figsize, dpi=dpi, facecolor="white")
    used = {}

    for stype, ix in segs:
        if ix is None:
            continue
        i, j = ix
        if not (ok[i] and ok[j]):
            continue
        used[stype] = used.get(stype, 0) + 1
        ax.plot([pts[i, 0], pts[j, 0]], [pts[i, 1], pts[j, 1]],
                line_style(stype), color=SEG_COLORS[stype], lw=0.5,
                alpha=0.5 if stype == UNSPECIFIED_CODE else 1.0)
    log.info("Drew %d segments (%s)", sum(used.values()),
             ", ".join(f"{SEG_NAMES[c]}={n}" for c, n in sorted(used.items())) or "none")

    ax.set_aspect("equal")
    ax.invert_yaxis()  # image-style coordinates: y grows downward
    ax.axis("off")  # no axes, ticks, grid or title - just the wireframe
    fig.subplots_adjust(left=0.03, right=0.97, bottom=0.03, top=0.97)  # keeps image square

    if pitch:
        fig.canvas.draw()  # settle limits/aspect so the data -> point scale is known
        draw_pitch_labels(fig, ax, pts, segs, facets, max_fontsize=pitch_max_fontsize, facet_types=facet_types)
    else:
        log.info("Pitch labels hidden (--no-pitch)")

    fig.savefig(out_path, dpi=dpi)
    plt.close(fig)


def export_3d(pts, segs, facets, out_path, facet_types=None, facet_materials=None):
    """Write the 3D geometry as JSON: {"P": [[x, y, z]...], "S": [[i, j, code]...], ...}.

    Only points used by a drawn segment are kept (segments are re-indexed). Z is
    reversed so the model is upright. Segment codes/colours are the same as the
    top-down wireframe, so the 3D view matches it. Infinite-pitch facets keep their edges.
    "F" holds one pitch label per facet: {"p": text, "l": [x, y, z]} with the label
    placed inside the facet, on its plane (facets with no finite pitch - nan or
    infinite - get no label).
    """
    ok = ~np.isnan(pts).any(axis=1)
    ftypes = list(facet_types) if facet_types is not None else [0] * len(facets)
    fmats = list(facet_materials) if facet_materials is not None else [0] * len(facets)
    seg_ftypes = {}  # segment index -> set of the facet types that use it (the viewer's type toggles)
    for (seg_ids, _), ft in zip(facets, ftypes):
        for k in seg_ids:
            seg_ftypes.setdefault(int(k), set()).add(int(ft))
    kept = [(n, stype, ix) for n, (stype, ix) in enumerate(segs)
            if ix is not None and ok[ix[0]] and ok[ix[1]]]
    used = sorted({int(k) for _, _, ix in kept for k in ix})
    remap = {old: new for new, old in enumerate(used)}
    P = pts[used].copy()
    P[:, 2] *= -1  # reverse Z

    segs_xy = [tuple(ix) if ix is not None else () for _, ix in segs]
    F = []
    for fi, (seg_ids, pv) in enumerate(facets):
        loop = facet_polygon(seg_ids, segs_xy)
        if len(loop) < 3 or np.isnan(pts[loop]).any() or not np.isfinite(pv) or (ftypes[fi] & FLOOR_FLAG):
            continue  # no usable outline, or nan/inf pitch: nothing to label
        poly3 = pts[loop]
        x, y = label_point(poly3[:, :2])
        try:  # z on the facet's own plane (least squares); fall back to the mean height
            a = np.c_[poly3[:, 0], poly3[:, 1], np.ones(len(poly3))]
            cf = np.linalg.lstsq(a, poly3[:, 2], rcond=None)[0]
            z = float(cf[0] * x + cf[1] * y + cf[2])
        except Exception:
            z = float(poly3[:, 2].mean())
        F.append({"p": fmt_pitch(pv), "t": ftypes[fi],
                  "l": [round(float(x), 2), round(float(y), 2), round(-z + 0.0, 2)]})
    A = []  # shaded facet outlines: [materialID, facetType, [point indices]]
    for fi, (seg_ids, _) in enumerate(facets):
        loop = facet_polygon(seg_ids, segs_xy)
        if len(loop) < 3 or any(int(k) not in remap for k in loop):
            continue
        A.append([fmats[fi], ftypes[fi], [remap[int(k)] for k in loop]])
    data = {
        "A": A,
        "mat": {str(k): v for k, v in MATERIAL_COLORS.items()},
        "matNames": {str(k): v for k, v in MATERIAL_NAMES.items()},
        "matAlphas": {str(k): v for k, v in MATERIAL_ALPHAS.items()},
        "hole": HOLE_COLOR,
        "holeAlpha": HOLE_ALPHA,
        "roof": ROOF_COLOR,
        "roofAlpha": ROOF_ALPHA,
        "surf": SURFACE_COLOR,
        "surfAlpha": SURFACE_ALPHA,
        "P": (np.round(P, 2) + 0.0).tolist(),  # + 0.0 turns -0.0 into 0.0
        "S": [[remap[int(ix[0])], remap[int(ix[1])], int(stype), sorted(seg_ftypes.get(n, []))]
              for n, stype, ix in kept],
        "F": F,
        "colors": {str(k): v for k, v in SEG_COLORS.items()},
        "names": {str(k): v for k, v in SEG_NAMES.items()},
    }
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, separators=(",", ":"))
    log.info("Wrote 3D geometry: %d points, %d segments, %d facet labels -> %s",
             len(P), len(data["S"]), len(F), out_path)


def plot_overlay(pts, segs, img_path, out_path, scale=1.0, max_px=4200):
    """Draw the wireframe on top of the top-down photo (model x/y == photo pixels)."""
    import matplotlib.image as mpimg

    img = mpimg.imread(img_path)
    h, w = img.shape[:2]
    k = min(3.0, max_px / max(w, h))
    log.info("Overlay on %s (%dx%d px, output scale %.2f, model scale %.2f)", img_path, w, h, k, scale)
    dpi = 100
    fig = plt.figure(figsize=(w * k / dpi, h * k / dpi), dpi=dpi, facecolor="black")
    ax = fig.add_axes([0, 0, 1, 1])
    if img.ndim == 2:
        ax.imshow(img, cmap="gray", extent=(0, w, h, 0), interpolation="bilinear")
    else:
        ax.imshow(img, extent=(0, w, h, 0), interpolation="bilinear")

    xy = pts[:, :2] * scale
    ok = ~np.isnan(xy).any(axis=1)
    if ok.any():
        lo, hi = xy[ok].min(0), xy[ok].max(0)
        if hi[0] > w * 1.02 or hi[1] > h * 1.02 or lo.min() < -0.02 * max(w, h):
            log.warning("Wireframe extent x %.0f..%.0f, y %.0f..%.0f does not fit the %dx%d photo - try --scale",
                        lo[0], hi[0], lo[1], hi[1], w, h)

    drawn = 0
    for stype, ix in segs:
        if ix is None:
            continue
        i, j = ix
        if not (ok[i] and ok[j]):
            continue
        ax.plot([xy[i, 0], xy[j, 0]], [xy[i, 1], xy[j, 1]], line_style(stype),
                color=SEG_COLORS[stype], lw=OVERLAY_LINE_WIDTH,
                alpha=0.5 if stype == UNSPECIFIED_CODE else 1.0,
                zorder=3)
        drawn += 1
    log.info("Drew %d segments on the photo (line width %.1f)", drawn, OVERLAY_LINE_WIDTH)
    ax.set_xlim(0, w)
    ax.set_ylim(h, 0)
    ax.axis("off")
    fig.savefig(out_path, dpi=dpi)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("evm_file", help="Input .evm file")
    ap.add_argument("-o", "--output", default=None,
                    help="Output PNG (default: <evm_file>_topdown.png)")
    ap.add_argument("--no-pitch", action="store_true", help="Hide per-facet pitch labels")
    ap.add_argument("--dpi", type=int, default=300)
    ap.add_argument("-v", "--verbose", action="store_true", help="Debug-level logging")
    ap.add_argument("-q", "--quiet", action="store_true", help="Only log warnings and errors")
    ap.add_argument("--overlay", default=None, metavar="IMAGE",
                    help="Draw the wireframe on top of this top-down photo instead")
    ap.add_argument("--scale", type=float, default=1.0,
                    help="Multiply model x/y by this to match the photo's resolution (overlay only)")
    ap.add_argument("--match-image", default=None, metavar="IMAGE",
                    help="Match the plain wireframe canvas dimensions to this image")
    ap.add_argument("--json3d", action="store_true",
                    help="Write the 3D geometry as JSON (for the interactive 3D view) instead of a PNG")
    args = ap.parse_args()

    # Log to stdout (flushed per line) so the lines stay in order with the final
    # "Saved ..." message when a parent process captures the output.
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(asctime)s.%(msecs)03d %(levelname)-7s %(message)s", "%H:%M:%S"))
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.WARNING if args.quiet else logging.INFO,
                        handlers=[handler])

    out = args.output or args.evm_file.rsplit(".", 1)[0] + ("_3d.json" if args.json3d else "_topdown.png")
    mode = "3d" if args.json3d else "overlay" if args.overlay else "wireframe"
    log.info("Rendering %s for %s -> %s", mode, args.evm_file, out)
    t0 = time.perf_counter()
    try:
        pts, segs, facets, facet_types, facet_materials = load_geometry(args.evm_file, omit_infinite=not args.json3d)
        if args.json3d:
            export_3d(pts, segs, facets, out, facet_types, facet_materials)
        elif args.overlay:
            plot_overlay(pts, segs, args.overlay, out, scale=args.scale)
        else:
            plot_top_down(pts, segs, facets, out,
                          pitch=not args.no_pitch, dpi=args.dpi,
                          match_image=args.match_image, facet_types=facet_types)
    except Exception:
        log.exception("Failed to render %s", mode)
        sys.exit(1)
    log.info("Finished %s in %.2fs", mode, time.perf_counter() - t0)
    print(f"Saved {out}", flush=True)


if __name__ == "__main__":
    main()
'@
# Prefer the copy on the PIA share (so it can be updated without redeploying
# PAR); if there isn't one, write the copy embedded in this file to the cache.
$WireframeScriptLocal = Get-PiaScriptLocal -FileName 'roof_wireframe.py'
if (-not $WireframeScriptLocal) {
    try {
        $embDir = Join-Path $env:LOCALAPPDATA 'PAR-App\fileinfo'
        New-Item -ItemType Directory -Force -Path $embDir | Out-Null
        $embPath = Join-Path $embDir 'roof_wireframe.embedded.py'
        [System.IO.File]::WriteAllText($embPath, $WireframePyText, (New-Object System.Text.UTF8Encoding($false)))
        $WireframeScriptLocal = $embPath
    }
    catch { }
}
if ($WireframeScriptLocal) { Write-ParLog "wireframe script: $WireframeScriptLocal" 'INFO' 'startup' }
else { Write-ParLog 'roof_wireframe.py not available - Overlay (2D)/Wireframes (3D) tiles will show an error' 'WARN' 'startup' }
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
    @{ Name = 'PythonExeLocal'   ; Value = $PythonExeLocal }
    @{ Name = 'WireframeScriptLocal' ; Value = $WireframeScriptLocal }
    @{ Name = 'FileInfoExeLock'  ; Value = $FileInfoExeLock }
    @{ Name = 'ParLogEnabled'    ; Value = $ParLogEnabled }
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

    # Same logger as the main script (pooled runspaces don't share functions).
    function Write-ParLog {
        param(
            [Parameter(Mandatory, Position = 0)][string]$Message,
            [Parameter(Position = 1)][ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO',
            [Parameter(Position = 2)][string]$Source = 'http'
        )
        if (-not $ParLogEnabled) { return }
        try {
            $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'DEBUG' { 'DarkGray' } default { 'Cyan' } }
            Write-Host ("[{0}] [{1,-5}] [{2}] {3}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Level, $Source, $Message) -ForegroundColor $color
        }
        catch { }
    }

    # Short, readable description of a request for the log (file names, not raw UNC paths).
    function Get-RequestDescription($ctx) {
        $p = $ctx.Request.Url.AbsolutePath
        $q = $ctx.Request.QueryString
        switch ($p) {
            '/api/images'     { return "images: report=$($q['reportId']) location=$($q['location'])$(if ($q['folderName']) { ' folder=' + $q['folderName'] })" }
            '/api/file-info'  { return "file-info: report=$($q['reportId']) state=$($q['state']) source=$($q['source'])" }
            '/api/wireframe'  { $mode = if ($q['view3d'] -eq '1') { '3d' } elseif ($q['overlay'] -eq '1') { 'overlay' } else { 'wireframe' }; return "wireframe ($mode): $((("$($q['evm'])") -split '[\\/]')[-1])" }
            '/api/image-file' { return "image-file: $((("$($q['path'])") -split '[\\/]')[-1])" }
            default           { return "$($ctx.Request.HttpMethod) $p" }
        }
    }

    function Write-JsonResponse($ctx, $obj, [int]$statusCode = 200) {
        try {
            if ($statusCode -ge 400 -or (($obj -is [System.Collections.IDictionary]) -and $obj.Contains('found') -and -not $obj['found'])) {
                $why = if ($obj['error']) { $obj['error'] } elseif ($obj['message']) { $obj['message'] } else { '(no detail)' }
                Write-ParLog "$why" 'WARN' 'http'
            }
        }
        catch { }
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
        $imageLabels = @()
        $topDownUrl = $null
        Write-ParLog "report $reportId -> folder '$($folder.Name)' (found by $searchMethod)" 'INFO' 'images'
        if (Test-Path -LiteralPath $imagesDir) {
            try {
                # Direction order for elevation shots: Overview, North, East, West, South.
                $ElevationOrder = @{ 'O' = 0; 'N' = 1; 'E' = 2; 'W' = 3; 'S' = 4 }
                $allImages = @(Get-ChildItem -LiteralPath $imagesDir -File -ErrorAction Stop |
                         Where-Object { $ImageExtensions -contains $_.Extension.ToLowerInvariant() })
                # The top-down overview shot is named O_****_**.jpg. Pick the
                # newest one explicitly (so it can't be pushed out by newer
                # elevation shots) and show it first, then up to 4 others.
                $topDownFile = $allImages |
                         Where-Object { $_.Name -match '^O_[^_]+_[^_]+\.jpe?g$' } |
                         Sort-Object LastWriteTime -Descending |
                         Select-Object -First 1
                $otherFiles = @($allImages |
                         Where-Object { $_.Name -notmatch '^O_[^_]+_[^_]+\.jpe?g$' } |
                         Sort-Object LastWriteTime -Descending |
                         Select-Object -First $(if ($topDownFile) { 4 } else { 5 }) |
                         Sort-Object @{ Expression = {
                             $prefix = $_.BaseName.Substring(0,1).ToUpperInvariant()
                             if ($ElevationOrder.ContainsKey($prefix)) { $ElevationOrder[$prefix] } else { 99 }
                         } })
                $files = @(@($topDownFile) + $otherFiles | Where-Object { $_ })
                $imageUrls = @($files | ForEach-Object { '/api/image-file?path=' + [Uri]::EscapeDataString($_.FullName) })
                if ($topDownFile) { $topDownUrl = '/api/image-file?path=' + [Uri]::EscapeDataString($topDownFile.FullName) }
                # Label for each photo, same order as $imageUrls: O_ = Ortho (top-down), N/E/W/S = elevations.
                $ElevationLabels = @{ 'O' = 'Ortho (top)'; 'N' = 'North'; 'E' = 'East'; 'W' = 'West'; 'S' = 'South' }
                $imageLabels = @($files | ForEach-Object {
                    $lead = if ($_.BaseName) { $_.BaseName.Substring(0, 1).ToUpperInvariant() } else { '' }
                    if ($ElevationLabels.ContainsKey($lead)) { $ElevationLabels[$lead] } else { '' }
                })
                Write-ParLog ("{0} image(s): {1}" -f $files.Count, ((@($files | ForEach-Object { $_.Name })) -join ', ')) 'INFO' 'images'
            }
            catch { Write-ParLog "couldn't list $imagesDir : $($_.Exception.Message)" 'WARN' 'images' }
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
            imageLabels = $imageLabels
            topDown     = $topDownUrl
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

    function Handle-Wireframe($ctx) {
        # Renders a PNG from the given .evm via roof_wireframe.py:
        #   (default)     plain top-down wireframe
        #   overlay=1     wireframe drawn on the report's top-down photo
        #                 (Images\O_****_**.jpg next to the Rollback folder)
        #   view3d=1      3D geometry as JSON (not a PNG) for the rotatable Wireframes (3D) tile
        #                 (includes infinite-pitch facet edges; a pitch label per finite-pitch facet)
        # Only .evm files under the known archive roots are accepted (same
        # allow-list as Handle-ImageFile). Results are cached per file version.
        $reqPath = $ctx.Request.QueryString['evm']
        $overlay = ($ctx.Request.QueryString['overlay'] -eq '1')
        $view3d  = ($ctx.Request.QueryString['view3d'] -eq '1')
        if ($view3d) { $overlay = $false }
        if ([string]::IsNullOrWhiteSpace($reqPath)) {
            Write-JsonResponse $ctx @{ found = $false; error = 'Missing evm path' } 400
            return
        }
        try { $full = [System.IO.Path]::GetFullPath($reqPath) }
        catch { Write-JsonResponse $ctx @{ found = $false; error = 'Invalid evm path' } 400; return }
        $withinKnownRoot = $false
        foreach ($root in $ArchiveRootsFull) {
            if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { $withinKnownRoot = $true; break }
        }
        if (-not $withinKnownRoot -or [System.IO.Path]::GetExtension($full).ToLowerInvariant() -ne '.evm') {
            Write-JsonResponse $ctx @{ found = $false; error = 'Path not allowed' } 403
            return
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            Write-JsonResponse $ctx @{ found = $false; error = 'EVM file not found' } 404
            return
        }
        if (-not $WireframeScriptLocal -or -not (Test-Path -LiteralPath $WireframeScriptLocal -PathType Leaf)) {
            Write-JsonResponse $ctx @{ found = $false; error = 'roof_wireframe.py not found (put it next to fileinfo.py on the PIA share)' } 500
            return
        }
        if (-not $PythonExeLocal) {
            Write-JsonResponse $ctx @{ found = $false; error = 'Python 3 not found (needs numpy, scipy, matplotlib)' } 500
            return
        }
        # <archive folder>\Rollback\<n>.0.evm  ->  <archive folder>\Images\O_****_**.jpg
        $folderDir = Split-Path -Path (Split-Path -Path $full -Parent) -Parent
        $imagesDir = Join-Path $folderDir 'Images'
        $topDownFile = $null
        if (-not $view3d -and (Test-Path -LiteralPath $imagesDir)) {
            $topDownFile = Get-ChildItem -LiteralPath $imagesDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^O_[^_]+_[^_]+\.jpe?g$' } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
        }
        if ($overlay -and -not $topDownFile) {
            Write-JsonResponse $ctx @{ found = $false; code = 'no-topdown'; error = 'No top-down image (O_****_**.jpg) found' } 404
            return
        }
        $ticks = (Get-Item -LiteralPath $full).LastWriteTimeUtc.Ticks
        $imageKey = if ($topDownFile) { "|$($topDownFile.FullName)|$($topDownFile.LastWriteTimeUtc.Ticks)" } else { '' }
        $wfKey = if ($view3d) { "wf3d-v6:$full|$ticks" } elseif ($overlay) { "wfo-v5:$full|$ticks$imageKey" } else { "wf-v5:$full|$ticks$imageKey" }
        $png = $null
        $cachedPng = $null
        if ($FolderCache.TryGetValue($wfKey, [ref]$cachedPng) -and $cachedPng -is [byte[]]) {
            Write-ParLog ("served from cache ({0:N0} KB)" -f ($cachedPng.Length / 1KB)) 'DEBUG' 'wireframe'
            $png = $cachedPng
        }
        else {
            $id       = [guid]::NewGuid().ToString('N')
            $localEvm = Join-Path $env:TEMP "parwf_$id.evm"
            $localImg = Join-Path $env:TEMP "parwf_$id.jpg"
            $outPng   = Join-Path $env:TEMP ("parwf_$id" + $(if ($view3d) { '.json' } else { '.png' }))   # JSON for the 3D view
            try {
                Copy-Item -LiteralPath $full -Destination $localEvm -Force
                $pyArgs = @($WireframeScriptLocal, $localEvm, '-o', $outPng, '--dpi', '300')
                if ($view3d) { $pyArgs = @($WireframeScriptLocal, $localEvm, '-o', $outPng, '--json3d') }
                elseif ($topDownFile) {
                    Copy-Item -LiteralPath $topDownFile.FullName -Destination $localImg -Force
                    $pyArgs += @('--match-image', $localImg)
                }
                if ($overlay -and -not $view3d) {
                    $pyArgs += @('--overlay', $localImg)
                }
                $wfSw = [System.Diagnostics.Stopwatch]::StartNew()
                Write-ParLog ("running {0} ({1})" -f [System.IO.Path]::GetFileName($WireframeScriptLocal), $(if ($view3d) { '3D geometry' } elseif ($overlay) { 'overlay on ' + $topDownFile.Name } else { 'plain wireframe' })) 'DEBUG' 'wireframe'
                $log = & $PythonExeLocal @pyArgs 2>&1 | Out-String
                foreach ($pyLine in ($log -split "\r?\n")) {
                    if (-not $pyLine.Trim()) { continue }
                    $pyLevel = if ($pyLine -match '\b(ERROR|CRITICAL|Traceback)\b') { 'ERROR' } elseif ($pyLine -match '\bWARNING\b') { 'WARN' } else { 'DEBUG' }
                    Write-ParLog $pyLine.TrimEnd() $pyLevel 'wireframe/py'
                }
                if (-not (Test-Path -LiteralPath $outPng -PathType Leaf) -and $log -match "No module named '?matplotlib") {
                    # matplotlib missing: try a per-user pip install once per PAR session, then retry.
                    [System.Threading.Monitor]::Enter($FolderCache)
                    try {
                        if (-not $FolderCache.ContainsKey('mpl-install-tried')) {
                            $FolderCache['mpl-install-tried'] = $true
                            $null = & $PythonExeLocal -m pip install --user --disable-pip-version-check matplotlib 2>&1 | Out-String
                        }
                    }
                    finally { [System.Threading.Monitor]::Exit($FolderCache) }
                    $log = & $PythonExeLocal @pyArgs 2>&1 | Out-String
                }
                if (-not (Test-Path -LiteralPath $outPng -PathType Leaf)) {
                    $lines  = @(($log -split "\r?\n") | Where-Object { $_.Trim() })
                    $last   = if ($lines.Count) { $lines[-1].Trim() } else { 'no output from python' }
                    $detail = $log.Trim()
                    if ($detail.Length -gt 600) { $detail = $detail.Substring($detail.Length - 600) }
                    Write-JsonResponse $ctx @{ found = $false; error = $last; detail = $detail } 500
                    return
                }
                $png = [System.IO.File]::ReadAllBytes($outPng)
                Write-ParLog ("rendered {0:N0} KB in {1} ms" -f ($png.Length / 1KB), $wfSw.ElapsedMilliseconds) 'OK' 'wireframe'
            }
            catch {
                Write-JsonResponse $ctx @{ found = $false; error = "wireframe failed: $($_.Exception.Message)" } 500
                return
            }
            finally {
                Remove-Item -LiteralPath $localEvm, $localImg, $outPng -Force -ErrorAction SilentlyContinue
            }
            $FolderCache[$wfKey] = $png
        }
        $ctx.Response.ContentType     = if ($view3d) { 'application/json; charset=utf-8' } else { 'image/png' }
        $ctx.Response.ContentLength64 = $png.Length
        $ctx.Response.OutputStream.Write($png, 0, $png.Length)
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
        Write-ParLog "report $reportId -> $($folder.Name)\Rollback\$($evmFiles[0].Name)" 'INFO' 'file-info'

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
            Write-ParLog "served from cache (rollback $rollbackVersion)" 'DEBUG' 'file-info'
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
        if (-not $PythonExeLocal) {
            Write-JsonResponse $ctx @{ found = $false; error = 'Python 3 not found on this machine. Install it (python.org, tick Add to PATH) then run: pip install scipy numpy' } 500
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
            $output = & $PythonExeLocal $fileInfoExe $localEvm 2>&1 | Out-String
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
        if ($output -match '"status":\s*"ERROR"') { Write-ParLog "fileinfo reported an error: $output" 'WARN' 'file-info' }
        else { Write-ParLog "parsed rollback $rollbackVersion (copy $copyMs ms, python $execMs ms)" 'OK' 'file-info' }
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

    $reqSw   = [System.Diagnostics.Stopwatch]::StartNew()
    $logPath = $ctx.Request.Url.AbsolutePath
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
        elseif ($path -eq '/api/wireframe') {
            Handle-Wireframe $ctx
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
    catch { Write-ParLog "unhandled error for $logPath : $($_.Exception.Message)" 'ERROR' 'http' }
    finally {
        try {
            if ($logPath -like '/api/*') {
                $status = $ctx.Response.StatusCode
                $lvl = if ($status -ge 500) { 'ERROR' } elseif ($status -ge 400) { 'WARN' } else { 'INFO' }
                Write-ParLog ("{0} -> {1} ({2} ms)" -f (Get-RequestDescription $ctx), $status, $reqSw.ElapsedMilliseconds) $lvl 'http'
            }
        }
        catch { }
        $ctx.Response.OutputStream.Close()
    }
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
    Write-ParLog 'Window closed - shutting down the local server' 'INFO' 'PAR'
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
    Write-ParLog "Couldn't create the WebView2 environment: $($_.Exception.Message)" 'ERROR' 'webview2'
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
        Write-ParLog "WebView2 ready - opening $prefix" 'OK' 'webview2'
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
            Write-ParLog "opening in default browser: $($wvArgs.Uri)" 'INFO' 'webview2'
            try { Start-Process $wvArgs.Uri } catch { }
        })
        # Page -> terminal log bridge: the page calls parLog()/console.error()/console.warn(),
        # which post {level,message} here so UI actions and JS errors show up in this window.
        $webView.CoreWebView2.add_WebMessageReceived({
            param($wmSender, $wmArgs)
            try {
                $raw = $wmArgs.TryGetWebMessageAsString()
                if (-not $raw) { return }
                $m = $raw | ConvertFrom-Json
                $lvl = switch ("$($m.level)") { 'error' { 'ERROR' } 'warn' { 'WARN' } 'ok' { 'OK' } default { 'INFO' } }
                Write-ParLog "$($m.message)" $lvl 'page'
            }
            catch { }
        })
    }
    else {
        Write-ParLog "WebView2 failed to initialize: $($e.InitializationException.Message)" 'ERROR' 'webview2'
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