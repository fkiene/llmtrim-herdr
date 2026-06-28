#!/usr/bin/env pwsh
# check-routing.ps1 - pane.agent_detected hook.
#
# Verify routing is actually live (proxy env present AND daemon responding), not
# merely that setup ran. Warn at most once per workspace, and self-heal: the
# warning clears once routing is confirmed, so a later relaunch stops nagging.

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

$Confirmed = Join-Path $State "routing_confirmed.$Ws.$HostName"
$Warned    = Join-Path $State "routing_warned.$Ws.$HostName"

# Early exit: routing already confirmed for this workspace+host.
if (Test-Path $Confirmed) { exit 0 }

function Invoke-Notify {
    param([string]$Title, [string]$Body)
    try {
        $params = [ordered]@{ title = $Title; body = $Body }
        $null = Invoke-HerdrRpc -Method 'notification.show' `
            -ParamsJson ($params | ConvertTo-Json -Compress)
    } catch {}
}

function Invoke-WarnOnce {
    param([string]$Title, [string]$Body)
    # One warning per workspace until routing is confirmed; clear when confirmed.
    if (Test-Path $Warned) { return }
    Invoke-Notify -Title $Title -Body $Body
    try { Set-Content -Path $Warned -Value '' -NoNewline -ErrorAction SilentlyContinue } catch {}
}

# Check proxy env (case-insensitive Windows convention: prefer upper, fall back lower).
$proxy = if ($null -ne $env:HTTPS_PROXY -and $env:HTTPS_PROXY -ne '') {
    $env:HTTPS_PROXY
} elseif ($null -ne $env:https_proxy -and $env:https_proxy -ne '') {
    $env:https_proxy
} else { '' }

if ($proxy -eq '') {
    Invoke-WarnOnce -Title 'llmtrim: relaunch herdr' `
        -Body 'Routing is configured but herdr started before it. Relaunch herdr once to route agents through the proxy.'
    exit 0
}

# Proxy env present: confirm the daemon is actually up (frozen contract: status
# --json always exits 0; read .daemon, treating a missing object as not running).
$llmtrimCmd = Get-Command llmtrim -ErrorAction SilentlyContinue
$running = $false
if ($null -ne $llmtrimCmd) {
    try {
        $llmtrim = $llmtrimCmd.Source
        $js = & $llmtrim status --json 2>$null
        if ($null -ne $js -and $js -ne '') {
            $parsed = $js | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($null -ne $parsed -and $null -ne $parsed.daemon) {
                $running = [bool]$parsed.daemon.running
            }
        }
    } catch {}
}

if ($running) {
    try { Set-Content -Path $Confirmed -Value '' -NoNewline -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item $Warned -Force -ErrorAction SilentlyContinue } catch {}
    exit 0
}

Invoke-WarnOnce -Title 'llmtrim: daemon down' `
    -Body 'The proxy environment is set but the llmtrim daemon is not responding. Run: llmtrim start'
exit 0
