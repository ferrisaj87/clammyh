<#
.SYNOPSIS
  Stops stale PowerShell windows running clammy_horizon_capture_and_update.ps1 (used before a fresh /clammyh reloadah).
#>
$ErrorActionPreference = 'SilentlyContinue'
$marker = 'clammy_horizon_capture_and_update.ps1'
Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
  Where-Object {
    ($null -ne $_) -and
    ($_.Name -match '^(powershell|pwsh)\.exe$') -and
    ($_.CommandLine -and ($_.CommandLine -like "*${marker}*"))
  } |
  ForEach-Object {
    $id = $_.ProcessId
    try {
      Write-Host "Clammy: kill-helper stopping PID $id"
      Stop-Process -Id $id -Force -ErrorAction Stop
    } catch {
      Write-Host "Clammy: kill-helper could not stop PID ${id}: $($_.Exception.Message)"
    }
  }
exit 0
