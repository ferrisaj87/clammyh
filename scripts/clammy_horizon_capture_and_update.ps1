<#
.SYNOPSIS
  ClammyHorizon AH refresh: reads saved JWT (from Chrome extension) and runs update_ah_prices.ps1.

.DESCRIPTION
  Logs and shared data go under Game\config\addons\ClammyHorizon\data\. Lock file horizon_helper.lock
  is created by the game before spawn and removed in finally when finished; the addon polls so the
  client does not block on os.execute.

  Default flow: reads the token saved by the Chrome extension (horizon_bearer.txt). If the token is
  missing or expired, instructs the user to visit horizonxi.com while logged in so the extension can
  capture a fresh one.

  **-UseSavedBearer** (/clammyh reloadah token): read JWT from horizon_bearer.txt only, no prompts.

  **-BrowserAssist**: open horizonxi.com in the user's default browser and ask them to paste the JWT
  manually (fallback if the Chrome extension is not installed).

.EXAMPLE
    .\clammy_horizon_capture_and_update.ps1

.EXAMPLE
    .\clammy_horizon_capture_and_update.ps1 -UseSavedBearer

.EXAMPLE
    .\clammy_horizon_capture_and_update.ps1 -BrowserAssist
    # Manual fallback: opens horizonxi.com in your browser; paste the JWT in the helper window.

.EXAMPLE
    .\clammy_horizon_capture_and_update.ps1 -NoKillPreviousHelpers
#>
[CmdletBinding()]
param(
  [string]$StartUrl = 'https://horizonxi.com/items/crab_shell',
  [switch]$CaptureOnly,
  # Omit stale PowerShell helpers running this same script (default); use -NoKillPreviousHelpers to allow parallel runs.
  [switch]$NoKillPreviousHelpers,
  # No prompts: use JWT already in horizon_bearer.txt only. Same as /clammyh reloadah token.
  [switch]$UseSavedBearer,
  # Manual fallback: open horizonxi.com in your default browser, paste JWT in this window.
  [switch]$BrowserAssist
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ClammyLogsDir = [System.IO.Path]::GetFullPath((Join-Path $ScriptRoot '..\..\..\config\addons\ClammyHorizon\data'))
$BearerPath = Join-Path $ClammyLogsDir 'horizon_bearer.txt'

# If the Chrome extension has already saved a newer token, promote it into the canonical path.
$ExtBearerPath = Join-Path $env:APPDATA 'Clammy\horizon_bearer.txt'
if ((Test-Path -LiteralPath $ExtBearerPath) -and (-not (Test-Path -LiteralPath $BearerPath) -or
    ((Get-Item -LiteralPath $ExtBearerPath).LastWriteTimeUtc -gt (Get-Item -LiteralPath $BearerPath).LastWriteTimeUtc))) {
  $null = New-Item -ItemType Directory -Path $ClammyLogsDir -Force -ErrorAction SilentlyContinue
  Copy-Item -LiteralPath $ExtBearerPath -Destination $BearerPath -Force -ErrorAction SilentlyContinue
}
$MainLog = Join-Path $ClammyLogsDir 'horizon_helper.log'
$ExitMarker = Join-Path $ClammyLogsDir 'last_helper_exitcode.txt'
$LockPath = Join-Path $ClammyLogsDir 'horizon_helper.lock'
$HadError = $false
$ExitCode = 0

function Stop-PreviousClammyHorizonHelpers {
  <#
  .SYNOPSIS
    Stops other PowerShell processes that are running this same script file (stale helper windows).
  #>
  param(
    [Parameter(Mandatory = $true)][string]$ThisPid,
    [string]$ScriptFileName = 'clammy_horizon_capture_and_update.ps1'
  )
  try {
    $candidates = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
          ($null -ne $_) -and
          ($_.Name -match '^(powershell|pwsh)\.exe$') -and
          ($_.CommandLine -and ($_.CommandLine -like "*${ScriptFileName}*")) -and
          ($_.ProcessId -ne [int]$ThisPid)
        })
    if ($candidates.Count -eq 0) {
      Write-Host 'Clammy: no other clammy_horizon_capture_and_update.ps1 helper windows found.' -ForegroundColor DarkGray
      return
    }
    foreach ($c in $candidates) {
      $id = $c.ProcessId
      try {
        Write-Host "Clammy: stopping previous Horizon helper (PowerShell PID $id)" -ForegroundColor Yellow
        Stop-Process -Id $id -Force -ErrorAction Stop
      } catch {
        Write-Host "Clammy: could not stop PID ${id}: $($_.Exception.Message)" -ForegroundColor DarkYellow
      }
    }
  } catch {
    Write-Host "Clammy: could not scan for previous helpers: $($_.Exception.Message)" -ForegroundColor DarkYellow
  }
}

$null = New-Item -ItemType Directory -Path $ClammyLogsDir -Force -ErrorAction SilentlyContinue

if (-not $NoKillPreviousHelpers) {
  Write-Host 'Clammy: closing any previous Horizon helper PowerShell windows (same script only). Use -NoKillPreviousHelpers to skip.' -ForegroundColor DarkGray
  Stop-PreviousClammyHorizonHelpers -ThisPid $PID
} else {
  Write-Host 'Clammy: -NoKillPreviousHelpers -- not stopping other helper processes.' -ForegroundColor DarkGray
}

Remove-Item -LiteralPath $MainLog -Force -ErrorAction SilentlyContinue
try {
  Start-Transcript -LiteralPath $MainLog -ErrorAction Stop | Out-Null
} catch {
  Write-Host "Clammy: could not start transcript (still running): $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ("======== {0} {1} run {2} ========" -f $ScriptRoot, $StartUrl, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray

function Stop-ClammyTranscript {
  try {
    Stop-Transcript -ErrorAction Stop | Out-Null
  } catch {
    # not started or already stopped
  }
}

function Pause-IfFail {
  if ($HadError) {
    Write-Host ""
    Write-Host "Clammy: helper failed. Full log saved to:" -ForegroundColor Yellow
    Write-Host "  $MainLog" -ForegroundColor Yellow
  }
  Write-Host ""
  Write-Host "Press any key to close this window..." -ForegroundColor DarkGray
  try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Read-Host "Press Enter to close" }
}

function Read-ClammySavedBearerToken {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  $lines = Get-Content -LiteralPath $Path -ErrorAction Stop
  foreach ($line in $lines) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) {
      continue
    }
    if ($t -match '^(?i)Bearer\s+(.+)$') {
      return $Matches[1].Trim()
    }
    return $t
  }
  return $null
}

function Invoke-ClammyUpdateFromSavedBearer {
  param([Parameter(Mandatory = $true)][string]$BearerPath, [Parameter(Mandatory = $true)][string]$ScriptRoot, [switch]$CaptureOnly)
  Write-Host ''
  Write-Host 'Clammy: -UseSavedBearer -- no browser. Using JWT from:' -ForegroundColor Cyan
  Write-Host "  $BearerPath" -ForegroundColor Gray
  Write-Host '  (Horizon: F12 -> Network -> filter api -> api.horizonxi.com request -> Headers -> authorization.)' -ForegroundColor DarkGray
  $tok = Read-ClammySavedBearerToken -Path $BearerPath
  if ([string]::IsNullOrWhiteSpace($tok)) {
    throw "Token file missing or empty. Edit (Notepad): $BearerPath -- one line: the JWT or Bearer eyJ..."
  }
  if ($tok.Length -lt 40) {
    throw 'Token looks too short. Paste the full JWT (starts with eyJ).'
  }
  if ($tok -notmatch '^eyJ[A-Za-z0-9_-]+\.') {
    throw 'Token does not look like a JWT (should start with eyJ).'
  }
  $env:HORIZONXI_TOKEN = $tok
  if ($CaptureOnly) {
    Write-Host 'Clammy: token OK (-CaptureOnly -- skipped update_ah_prices.ps1).' -ForegroundColor Green
    return
  }
  Write-Host 'Clammy: running update_ah_prices.ps1 ...' -ForegroundColor Cyan
  & (Join-Path $ScriptRoot 'update_ah_prices.ps1')
  Write-Host 'Clammy: done. Return to FFXI; Clammy should print success after apply.' -ForegroundColor Green
}

function Test-ClammyBearerJwt {
  param([string]$Tok)
  if ([string]::IsNullOrWhiteSpace($Tok)) { return $false }
  if ($Tok.Length -lt 40) { return $false }
  return ($Tok -match '^eyJ[A-Za-z0-9_-]+\.')
}

function Get-ClammyJwtExp {
  param([string]$Token)
  try {
    $parts = $Token.Split('.')
    if ($parts.Count -ne 3) { return $null }
    $b64 = $parts[1].Replace('-', '+').Replace('_', '/')
    $mod = $b64.Length % 4
    if ($mod -ne 0) { $b64 += '=' * (4 - $mod) }
    $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    $obj = $json | ConvertFrom-Json
    return $obj.exp
  } catch { return $null }
}

function Test-ClammyBearerNotExpired {
  param([string]$Token, [int]$GraceSeconds = 300)
  if (-not (Test-ClammyBearerJwt -Tok $Token)) { return $false }
  $exp = Get-ClammyJwtExp -Token $Token
  if ($null -eq $exp) { return $false }
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  return ($exp - $now) -gt $GraceSeconds
}

function Save-ClammyBearerToken {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Token)
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  Set-Content -LiteralPath $Path -Value $Token.Trim() -Encoding utf8 -Force
}

function Get-ClammyHorizonItemUrlsToOpen {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptRoot,
    [Parameter(Mandatory = $true)][string]$StartUrl,
    [int]$MaxTabs = 3
  )
  $seen = @{}
  $urls = [System.Collections.Generic.List[string]]::new()
  foreach ($u in @($StartUrl)) {
    if ([string]::IsNullOrWhiteSpace($u)) { continue }
    if (-not $seen.ContainsKey($u)) {
      $urls.Add($u)
      $seen[$u] = $true
    }
  }
  $src = Join-Path $ScriptRoot 'item_sources.json'
  if ((Test-Path -LiteralPath $src) -and ($urls.Count -lt $MaxTabs)) {
    try {
      $list = @(Get-Content -LiteralPath $src -Raw | ConvertFrom-Json)
      foreach ($e in $list) {
        if ($urls.Count -ge $MaxTabs) { break }
        if ($null -eq $e -or ($null -eq $e.PSObject.Properties['slug'])) { continue }
        $slug = [string]$e.slug
        if ([string]::IsNullOrWhiteSpace($slug)) { continue }
        $u = "https://horizonxi.com/items/$slug"
        if (-not $seen.ContainsKey($u)) {
          $urls.Add($u)
          $seen[$u] = $true
        }
      }
    }
    catch {
      Write-Warning "Could not read item_sources.json for browser URLs: $($_.Exception.Message)"
    }
  }
  return @($urls)
}

function Open-ClammyHorizonInDefaultBrowser {
  param([Parameter(Mandatory = $true)][string[]]$Urls)
  Write-Host ''
  Write-Host 'Clammy: opening Horizon item page(s) in your default browser (your normal Chrome/Edge profile -- log in if asked):' -ForegroundColor Cyan
  foreach ($u in $Urls) {
    Write-Host "  $u" -ForegroundColor Gray
    Start-Process -FilePath $u | Out-Null
    Start-Sleep -Milliseconds 450
  }
}

function Request-ClammyBearerInteractive {
  param([Parameter(Mandatory = $true)][string]$BearerPath)
  Write-Host ''
  Write-Host 'Clammy: copy your session token from the browser:' -ForegroundColor Yellow
  Write-Host '  F12 -> Network -> filter api or auction-detail -> click a request -> Headers -> authorization' -ForegroundColor Gray
  Write-Host '  Paste the long eyJ... string (or full Bearer eyJ... line) below, then Enter.' -ForegroundColor Gray
  Write-Host ''
  Write-Host 'Paste JWT:' -ForegroundColor Cyan
  $raw = Read-Host
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw 'No token pasted. Run /clammyh reloadah again after copying authorization from DevTools.'
  }
  $tok = $raw.Trim()
  if ($tok -match '^(?i)Bearer\s+(.+)$') {
    $tok = $Matches[1].Trim()
  }
  if (-not (Test-ClammyBearerJwt -Tok $tok)) {
    throw 'Pasted value does not look like a JWT (expected eyJ...). Copy authorization from an api.horizonxi.com request.'
  }
  Save-ClammyBearerToken -Path $BearerPath -Token $tok
  Write-Host ('Clammy: saved token to {0}' -f $BearerPath) -ForegroundColor DarkGray
  return $tok
}

function Invoke-ClammyBrowserAssist {
  param(
    [Parameter(Mandatory = $true)][string]$BearerPath,
    [Parameter(Mandatory = $true)][string]$ScriptRoot,
    [Parameter(Mandatory = $true)][string]$StartUrl,
    [switch]$CaptureOnly
  )
  $maxTabs = 3
  $rawMax = if ($null -ne $env:CLAMMY_BROWSER_OPEN_TABS) { $env:CLAMMY_BROWSER_OPEN_TABS.Trim() } else { '' }
  if ($rawMax -ne '') {
    $n = 0
    if ([int]::TryParse($rawMax, [ref]$n) -and $n -ge 1 -and $n -le 8) {
      $maxTabs = $n
    }
  }
  $forceNew = ($env:CLAMMY_FORCE_NEW_BEARER -eq '1')
  $tok = $null

  if ($null -eq $tok -and -not $forceNew) {
    # Reuse a previously saved valid token if available
    $tok = Read-ClammySavedBearerToken -Path $BearerPath
    if (Test-ClammyBearerJwt -Tok $tok) {
      Write-Host 'Clammy: reusing JWT already in horizon_bearer.txt (delete file or set CLAMMY_FORCE_NEW_BEARER=1 to replace).' -ForegroundColor Green
    } else {
      $tok = $null
    }
  }

  if ($null -eq $tok) {
    # Fall back: open the site in the user's browser and ask them to paste
    Write-Host '' 
    Write-Host 'Clammy: no saved JWT found.' -ForegroundColor Yellow
    Write-Host '  Log into horizonxi.com in Chrome -- the Chrome extension will capture your token automatically.' -ForegroundColor Gray
    Write-Host '  OR paste your token below (F12 -> Network -> api request -> authorization header).' -ForegroundColor Gray
    $urls = Get-ClammyHorizonItemUrlsToOpen -ScriptRoot $ScriptRoot -StartUrl $StartUrl -MaxTabs $maxTabs
    Open-ClammyHorizonInDefaultBrowser -Urls $urls
    $tok = Request-ClammyBearerInteractive -BearerPath $BearerPath
  }

  $env:HORIZONXI_TOKEN = $tok
  if ($CaptureOnly) {
    Write-Host 'Clammy: token OK (-CaptureOnly -- skipped update_ah_prices.ps1).' -ForegroundColor Green
    return
  }
  Write-Host 'Clammy: running update_ah_prices.ps1 ...' -ForegroundColor Cyan
  & (Join-Path $ScriptRoot 'update_ah_prices.ps1')
  Write-Host 'Clammy: done. Return to FFXI; Clammy should print success after apply.' -ForegroundColor Green
}
try {

  Set-Location -LiteralPath $ScriptRoot
  Write-Host ('Clammy: working dir: {0}' -f $ScriptRoot) -ForegroundColor DarkGray
  Write-Host ('Clammy: logs dir: {0}' -f $ClammyLogsDir) -ForegroundColor DarkGray
  Write-Host ''

  if ($UseSavedBearer) {
    Write-Host ' ======================================================================' -ForegroundColor Cyan
    Write-Host '  ClammyHorizon (token file -- no browser)' -ForegroundColor Yellow
    Write-Host ('  Token file: {0}\horizon_bearer.txt' -f $ClammyLogsDir) -ForegroundColor Gray
    Write-Host ' ======================================================================' -ForegroundColor Cyan
    Write-Host ''
    Invoke-ClammyUpdateFromSavedBearer -BearerPath $BearerPath -ScriptRoot $ScriptRoot -CaptureOnly:$CaptureOnly
  }
  elseif ($BrowserAssist) {
    Write-Host ' ======================================================================' -ForegroundColor Cyan
    Write-Host '  ClammyHorizon (your browser + paste JWT)' -ForegroundColor Yellow
    Write-Host '  Opens horizonxi.com in your default browser, then paste the token here.' -ForegroundColor Gray
    Write-Host ('  Saved token: {0}\horizon_bearer.txt' -f $ClammyLogsDir) -ForegroundColor Gray
    Write-Host ' ======================================================================' -ForegroundColor Cyan
    Invoke-ClammyBrowserAssist -BearerPath $BearerPath -ScriptRoot $ScriptRoot -StartUrl $StartUrl -CaptureOnly:$CaptureOnly
  }
  else {
    # Default: check for a valid saved token (written by the Chrome extension).
    $existingTok = Read-ClammySavedBearerToken -Path $BearerPath
    if (Test-ClammyBearerNotExpired -Token $existingTok) {
      $expUnix = Get-ClammyJwtExp -Token $existingTok
      $expDate = [DateTimeOffset]::FromUnixTimeSeconds([long]$expUnix).ToLocalTime().ToString('ddd MMM d h:mmtt')
      Write-Host ''
      Write-Host ' ======================================================================' -ForegroundColor Cyan
      Write-Host '  ClammyHorizon -- saved token (still valid, no browser needed)' -ForegroundColor Green
      Write-Host ' ======================================================================' -ForegroundColor Cyan
      Write-Host ''
      Write-Host "  Token expires: $expDate" -ForegroundColor Gray
      Write-Host '  Set CLAMMY_FORCE_NEW_BEARER=1 or delete horizon_bearer.txt to force re-capture.' -ForegroundColor DarkGray
      Write-Host ''
      $env:HORIZONXI_TOKEN = ($existingTok -replace '^(?i)Bearer\s+', '')
      if ($CaptureOnly) {
        Write-Host 'Clammy: -CaptureOnly -- token is valid, done.' -ForegroundColor Green
        return
      }
      Write-Host 'Clammy: running update_ah_prices.ps1 ...' -ForegroundColor Cyan
      & (Join-Path $ScriptRoot 'update_ah_prices.ps1')
      Write-Host 'Clammy: done. Return to FFXI; Clammy should print success after apply.' -ForegroundColor Green
      return
    }

    # No valid token found — instruct the user to use the Chrome extension.
    Write-Host ''
    Write-Host ' ======================================================================' -ForegroundColor Yellow
    Write-Host '  ClammyHorizon -- no valid token found' -ForegroundColor Yellow
    Write-Host ' ======================================================================' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  To capture your token automatically:' -ForegroundColor White
    Write-Host '    1. Make sure the ClammyHorizon Chrome extension is installed.' -ForegroundColor White
    Write-Host '       See: chrome-extension\README.md for setup instructions.' -ForegroundColor Gray
    Write-Host '    2. Log in to https://horizonxi.com in Chrome.' -ForegroundColor White
    Write-Host '       The extension captures your token silently in the background.' -ForegroundColor Gray
    Write-Host '    3. Run /clammyh reloadah in-game again.' -ForegroundColor White
    Write-Host ''
    Write-Host '  Or paste a token manually:' -ForegroundColor White
    Write-Host '    Run this script with -BrowserAssist to open the site and paste the JWT.' -ForegroundColor Gray
    Write-Host ''
    throw 'No valid bearer token. Visit horizonxi.com while logged in (Chrome extension) then retry.'
  }

}
catch {
  $HadError = $true
  $ExitCode = 1
  Write-Host ""
  Write-Host "Clammy: ERROR $($_.Exception.Message)" -ForegroundColor Red
  if ($_.ScriptStackTrace) {
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
  }
}
finally {
  Stop-ClammyTranscript
  Add-Content -LiteralPath $MainLog -Encoding utf8 -Value "======== run end HadError=$HadError exit=$ExitCode ========"
  try {
    Set-Content -LiteralPath $ExitMarker -Value ([string]$ExitCode) -Encoding ascii -Force
  } catch {}
  try {
    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
  } catch {}
}

Pause-IfFail
exit $ExitCode
