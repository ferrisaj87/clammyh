<#
.SYNOPSIS
  Registers the Clammy native messaging host for Google Chrome.
  Run this ONCE after loading the extension in Chrome.

.DESCRIPTION
  1. Finds node.exe on PATH.
  2. Writes the wrapper .bat that Chrome will launch as the native host.
  3. Writes the native messaging manifest JSON (includes your extension ID).
  4. Adds the registry key so Chrome can find the manifest.

.EXAMPLE
  .\install.ps1
  # You'll be prompted to paste your Chrome extension ID.

.EXAMPLE
  .\install.ps1 -ExtensionId "abcdefghijklmnopabcdefghijklmnop"
#>
[CmdletBinding()]
param(
  [string]$ExtensionId = ''
)

$ErrorActionPreference = 'Stop'
$HostName   = 'com.clammyhorizon.tokenhost'
$HostScript = Join-Path $PSScriptRoot 'clammy_token_host.js'

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host ' ============================================================' -ForegroundColor Cyan
Write-Host '  Clammy HorizonXI -- Native Messaging Host Installer' -ForegroundColor Yellow
Write-Host ' ============================================================' -ForegroundColor Cyan
Write-Host ''

# ── 1. Find node.exe ──────────────────────────────────────────────────────────
$nodeExe = $null
try { $nodeExe = (Get-Command node.exe -ErrorAction Stop).Source } catch {}
if (-not $nodeExe) {
  Write-Host 'ERROR: node.exe not found on PATH.' -ForegroundColor Red
  Write-Host '  Install Node.js LTS from https://nodejs.org then re-run this script.' -ForegroundColor Red
  Read-Host 'Press Enter to exit'
  exit 1
}
Write-Host "Node.js found: $nodeExe" -ForegroundColor Green

# ── 2. Extension ID ───────────────────────────────────────────────────────────
if (-not $ExtensionId) {
  Write-Host ''
  Write-Host 'You need your Chrome extension ID.' -ForegroundColor Yellow
  Write-Host '  1. Open Chrome and go to: chrome://extensions' -ForegroundColor Gray
  Write-Host '  2. Enable "Developer mode" (toggle, top-right).' -ForegroundColor Gray
  Write-Host '  3. Click "Load unpacked" and select the chrome-extension folder:' -ForegroundColor Gray
  Write-Host "     $(Split-Path $PSScriptRoot -Parent)" -ForegroundColor Cyan
  Write-Host '  4. Copy the ID shown under "Clammy HorizonXI Token".' -ForegroundColor Gray
  Write-Host ''
  $ExtensionId = (Read-Host 'Paste extension ID').Trim()
}

if ($ExtensionId -notmatch '^[a-z]{32}$') {
  Write-Host "ERROR: '$ExtensionId' does not look like a Chrome extension ID (32 lowercase letters)." -ForegroundColor Red
  Read-Host 'Press Enter to exit'
  exit 1
}
Write-Host "Extension ID: $ExtensionId" -ForegroundColor Green

# ── 3. Write wrapper .bat ─────────────────────────────────────────────────────
$batPath = Join-Path $PSScriptRoot 'clammy_token_host.bat'
$batContent = "@echo off`r`n`"$nodeExe`" `"$HostScript`" %*`r`n"
Set-Content -LiteralPath $batPath -Value $batContent -Encoding ascii -Force
Write-Host "Wrapper: $batPath" -ForegroundColor Green

# ── 4. Write host manifest JSON ───────────────────────────────────────────────
$manifestPath = Join-Path $PSScriptRoot 'com.clammyhorizon.tokenhost.json'
$manifest = [ordered]@{
  name            = $HostName
  description     = 'Clammy HorizonXI native messaging host — writes horizon_bearer.txt'
  path            = $batPath.Replace('\', '\\')
  type            = 'stdio'
  allowed_origins = @("chrome-extension://$ExtensionId/")
}
$manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $manifestPath -Encoding utf8 -Force
Write-Host "Manifest: $manifestPath" -ForegroundColor Green

# ── 5. Register in Windows registry (HKCU) ────────────────────────────────────
$regKey = "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$HostName"
if (-not (Test-Path $regKey)) {
  New-Item -Path $regKey -Force | Out-Null
}
Set-ItemProperty -Path $regKey -Name '(default)' -Value $manifestPath -Force
Write-Host "Registry: $regKey" -ForegroundColor Green

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host ' ============================================================' -ForegroundColor Cyan
Write-Host '  Installation complete!' -ForegroundColor Green
Write-Host ' ============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '  What happens now:' -ForegroundColor Gray
Write-Host '  - Restart Chrome (close and reopen).' -ForegroundColor Gray
Write-Host '  - Visit horizonxi.com while logged in.' -ForegroundColor Gray
Write-Host '  - The Clammy extension icon will turn GREEN.' -ForegroundColor Gray
Write-Host '  - horizon_bearer.txt is saved automatically.' -ForegroundColor Gray
Write-Host '  - /clammyh reloadah in-game will use it instantly.' -ForegroundColor Gray
Write-Host ''
Write-Host '  To reinstall or update: run this script again.' -ForegroundColor DarkGray
Write-Host ''
Read-Host 'Press Enter to close'
