#!/usr/bin/env pwsh
# stop-annotate.ps1 - workspace.closed hook. Stops the per-workspace savings poller.

$State = if ($null -ne $env:HERDR_PLUGIN_STATE_DIR -and $env:HERDR_PLUGIN_STATE_DIR -ne '') {
    $env:HERDR_PLUGIN_STATE_DIR
} else {
    [System.IO.Path]::GetTempPath()
}
$Ws = if ($null -ne $env:HERDR_WORKSPACE_ID -and $env:HERDR_WORKSPACE_ID -ne '') {
    $env:HERDR_WORKSPACE_ID
} else { 'default' }
$Ws = $Ws -replace '[^A-Za-z0-9._-]', ''
if ($Ws -eq '') { $Ws = 'default' }

$PidF = Join-Path $State "$Ws.poller.pid"

if (-not (Test-Path $PidF)) { exit 0 }

try {
    $pid_ = [int](Get-Content $PidF -Raw -ErrorAction SilentlyContinue)
    # Only stop it if it is still a pwsh process (guard against PID reuse).
    $proc = if ($pid_ -gt 0) { Get-Process -Id $pid_ -ErrorAction SilentlyContinue } else { $null }
    if ($null -ne $proc -and $proc.Name -eq 'pwsh') {
        Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue
    }
} catch {}

try { Remove-Item $PidF -Force -ErrorAction SilentlyContinue } catch {}
exit 0
