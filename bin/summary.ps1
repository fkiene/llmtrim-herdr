#!/usr/bin/env pwsh
# summary.ps1 - action: fire a notification.show with the current session savings.
#
# Windows twin of summary.sh. Parses `llmtrim status --json` with the same
# honest-savings logic as savings-annotate.ps1 (off / net / gross / --), then
# calls notification.show. Actions may exit non-zero on failure; errors are
# written to the error stream.

. (Join-Path $PSScriptRoot 'herdr-rpc.ps1')

# Resolve llmtrim once (PATH-hijack guard).
$llmtrimCmd = Get-Command llmtrim -ErrorAction SilentlyContinue
if ($null -eq $llmtrimCmd) {
    Write-Error 'llmtrim: binary not found in PATH'
    exit 1
}
$llmtrim = $llmtrimCmd.Source

# status --json always exits 0; branch on JSON content, never on exit code.
$rawJson = (& $llmtrim status --json 2>$null) -join "`n"
if ([string]::IsNullOrEmpty($rawJson)) { $rawJson = '{}' }

# Parse with the same honest-savings logic as savings-annotate.ps1.
$Title = 'llmtrim savings'
$Body  = 'Session: --'

try {
    $d = $rawJson | ConvertFrom-Json -ErrorAction Stop

    # Case (1): daemon absent or not running.
    $daemon = $d.daemon
    if ($null -eq $daemon) {
        $Body = 'Proxy is not running.'
    } else {
        $running = $false
        if ($null -ne $daemon.running) {
            $running = [bool]$daemon.running
        } elseif ($null -ne $daemon.health) {
            $running = ($daemon.health -ne 'stopped' -and $daemon.health -ne 'degraded')
        }

        if (-not $running) {
            $Body = 'Proxy is not running.'
        } else {
            # Case (3): cost present with round_trip_pct -> honest net-of-cache figure.
            $cost = $d.cost
            $emitted = $false
            if ($null -ne $cost) {
                $pct = $cost.round_trip_pct
                if ($null -ne $pct) {
                    $val = [int][Math]::Round([double]$pct)
                    if ($val -gt 0) {
                        $netUsd = $cost.net_saved_usd
                        if ($null -ne $netUsd) {
                            $Body = "Session: -${val}% net  (net saved `${0:F2})" -f [double]$netUsd
                        } else {
                            $Body = "Session: -${val}% net"
                        }
                        $emitted = $true
                    }
                }
            }

            if (-not $emitted) {
                # Case (2): cost null -- show gross saved_pct without "net" label.
                $inp   = $d.input
                $saved = if ($null -ne $inp) { $inp.saved_pct } else { $null }
                $val   = if ($null -ne $saved) { [int][Math]::Round([double]$saved) } else { 0 }

                if ($val -gt 0) {
                    $Body = "Session: -${val}%  (gross input)"
                } else {
                    $Body = 'Session: --'
                }
            }
        }
    }
} catch {
    # Parse failure: leave $Body as the safe sentinel "Session: --".
}

$notifParams = [ordered]@{ title = $Title; body = $Body }
$null = Invoke-HerdrRpc -Method 'notification.show' `
    -ParamsJson ($notifParams | ConvertTo-Json -Compress)
