#!/usr/bin/env pwsh
# bootstrap.ps1 - workspace.created hook.
#
# Idempotent. Wires routing (llmtrim setup), starts the daemon, discloses once
# (re-fires only when setup actually changed the CA), and launches the
# per-workspace savings poller. Never blocks herdr: every failure path exits 0.

. (Join-Path $PSScriptRoot 'herdr-rpc.ps1')

$State = if ($null -ne $env:HERDR_PLUGIN_STATE_DIR -and $env:HERDR_PLUGIN_STATE_DIR -ne '') {
    $env:HERDR_PLUGIN_STATE_DIR
} else {
    [System.IO.Path]::GetTempPath()
}
$HostName = if ($null -ne $env:COMPUTERNAME -and $env:COMPUTERNAME -ne '') {
    $env:COMPUTERNAME
} else {
    [System.Net.Dns]::GetHostName()
}
$Ws = if ($null -ne $env:HERDR_WORKSPACE_ID -and $env:HERDR_WORKSPACE_ID -ne '') {
    $env:HERDR_WORKSPACE_ID
} else { 'default' }

# Strip anything that could traverse out of $State when used in a filename.
$HostName = $HostName -replace '[^A-Za-z0-9._-]', ''
if ($HostName -eq '') { $HostName = 'unknown' }
$Ws = $Ws -replace '[^A-Za-z0-9._-]', ''
if ($Ws -eq '') { $Ws = 'default' }

try { $null = New-Item -ItemType Directory -Path $State -Force -ErrorAction SilentlyContinue } catch {}

function Invoke-Notify {
    param([string]$Title, [string]$Body)
    try {
        $params = [ordered]@{ title = $Title; body = $Body }
        $null = Invoke-HerdrRpc -Method 'notification.show' `
            -ParamsJson ($params | ConvertTo-Json -Compress)
    } catch {}
}

# Resolve llmtrim once (PATH-hijack guard); if absent, point the user at install.
$llmtrimCmd = Get-Command llmtrim -ErrorAction SilentlyContinue
if ($null -eq $llmtrimCmd) {
    Invoke-Notify -Title 'llmtrim not found' `
        -Body 'Install llmtrim and relaunch herdr to enable token-cost compression.'
    exit 0
}
$llmtrim = $llmtrimCmd.Source

$CaDir = if ($null -ne $env:LLMTRIM_HOME -and $env:LLMTRIM_HOME -ne '') {
    $env:LLMTRIM_HOME
} else {
    Join-Path $HOME '.llmtrim'
}
$Ca = Join-Path $CaDir 'ca.pem'
$Sentinel = Join-Path $State "disclosure_shown.$HostName"

function Get-CaFingerprint {
    if (Test-Path $Ca -PathType Leaf) {
        try { (Get-FileHash $Ca -Algorithm SHA256).Hash } catch { 'none' }
    } else { 'none' }
}

# Idempotent wiring + daemon start. Capture the CA fingerprint across setup so a
# regenerated CA (real, security-relevant change) re-fires the disclosure.
$before = Get-CaFingerprint
try { & $llmtrim setup 2>$null | Out-Null } catch {}
try { & $llmtrim start 2>$null | Out-Null } catch {}
$after = Get-CaFingerprint

$sentinelContent = if (Test-Path $Sentinel) {
    (Get-Content $Sentinel -Raw -ErrorAction SilentlyContinue) -replace '\s'
} else { $null }

if (-not (Test-Path $Sentinel) -or $sentinelContent -ne $after) {
    try {
        $paneParams = [ordered]@{ plugin_id = 'llmtrim.proxy'; entrypoint = 'welcome' }
        $null = Invoke-HerdrRpc -Method 'plugin.pane.open' `
            -ParamsJson ($paneParams | ConvertTo-Json -Compress)
    } catch {}
    Invoke-Notify -Title 'llmtrim is active' `
        -Body 'Agent HTTPS now routes through a local proxy that reads traffic in plaintext to compress it. Details and undo are in the llmtrim setup pane.'
    try { Set-Content -Path $Sentinel -Value $after -NoNewline -ErrorAction SilentlyContinue } catch {}
}

# Per-workspace savings poller: reap any stale one, then fork a fresh poller with
# stdio fully detached (Start-Process spawns a new process that does not inherit
# the hook's piped stdout/stderr, so the hook's reader threads are not blocked).
$PidF = Join-Path $State "$Ws.poller.pid"
if (Test-Path $PidF) {
    try {
        $oldPid = [int](Get-Content $PidF -Raw -ErrorAction SilentlyContinue)
        # Only stop it if it is still a pwsh process (guard against PID reuse).
        $oldProc = if ($oldPid -gt 0) { Get-Process -Id $oldPid -ErrorAction SilentlyContinue } else { $null }
        if ($null -ne $oldProc -and $oldProc.Name -eq 'pwsh') {
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    try { Remove-Item $PidF -Force -ErrorAction SilentlyContinue } catch {}
}

$PollerPath = Join-Path $PSScriptRoot 'savings-annotate.ps1'
if (Test-Path $PollerPath -PathType Leaf) {
    try {
        $proc = Start-Process pwsh `
            -ArgumentList '-NoProfile', '-File', $PollerPath `
            -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
        if ($null -ne $proc) {
            try { Set-Content -Path $PidF -Value $proc.Id -NoNewline -ErrorAction SilentlyContinue } catch {}
        }
    } catch {}
}

exit 0
