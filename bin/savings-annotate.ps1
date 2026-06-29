#!/usr/bin/env pwsh
# savings-annotate.ps1 - per-workspace live token-savings poller (Windows twin).
#
# Behaviorally identical to savings-annotate.sh. Talks to herdr via the Windows
# named pipe (Invoke-HerdrRpc from herdr-rpc.ps1). JSON is built with
# ConvertTo-Json so values are always properly escaped.
#
# Lifecycle:
#   Start: bootstrap.ps1 spawns this via Start-Process pwsh and records
#          $proc.Id in the pid file. Do NOT write the pid file here.
#   Stop:  stop-annotate.ps1 (workspace.closed) kills by pid file.
#   Reap:  bootstrap.ps1 checks Get-Process -Id $oldPid | .Name -eq 'pwsh'
#          before killing a stale instance. Do NOT Start-Process or launch
#          another binary -- this process must remain a pwsh process so the
#          Name check succeeds.
#
# Every iteration is wrapped in try/catch so a parse error, RPC failure, or
# transient llmtrim hiccup never kills the loop (Invoke-HerdrRpc now throws on
# error rather than calling exit, so the catch here is essential).

. (Join-Path $PSScriptRoot 'herdr-rpc.ps1')

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$PollSeconds = 20
# ttl_ms must exceed PollSeconds * 1000; 5 s of headroom keeps the badge from
# vanishing between polls under transient slowness.
$TtlMs = 25000

# ---------------------------------------------------------------------------
# Resolve llmtrim once (PATH-hijack guard)
# ---------------------------------------------------------------------------

$llmtrimCmd = Get-Command llmtrim -ErrorAction SilentlyContinue
if ($null -eq $llmtrimCmd) {
    # llmtrim absent -- bootstrap already notified the user; exit cleanly.
    exit 0
}
$llmtrim = $llmtrimCmd.Source

# ---------------------------------------------------------------------------
# Pane ID
#
# Inherited from bootstrap's hook environment ($env:HERDR_PANE_ID = the focused
# pane when workspace.created fired). It can become stale if that pane closes;
# every RPC call is in a try/catch so a stale id is harmless.
# ---------------------------------------------------------------------------

$PaneId = if ($null -ne $env:HERDR_PANE_ID -and $env:HERDR_PANE_ID -ne '') {
    $env:HERDR_PANE_ID
} else { '' }

# ---------------------------------------------------------------------------
# Control-character stripper
# ---------------------------------------------------------------------------

function Remove-ControlChars {
    param([string]$Text)
    # Strip C0 control characters (U+0000-U+001F except U+0009 tab, keep printable).
    [regex]::Replace($Text, '[\x00-\x08\x0b-\x1f\x7f]', '')
}

# ---------------------------------------------------------------------------
# Badge builder
#
# Three cases:
#   (1) daemon absent / stopped  ->  "llmtrim: off"
#   (2) daemon up, cost null     ->  "llmtrim -NN%"   (gross saved_pct; not
#                                    labelled "net" -- that would be dishonest)
#   (3) daemon up, cost present  ->  "llmtrim -NN% net"  (round_trip_pct,
#                                    the honest net-of-cache figure)
#
# The cross-cutting "honest savings" rule forbids showing round_trip_pct when
# cost is null and forbids labelling input.saved_pct as "net".
# ---------------------------------------------------------------------------

function Get-Badge {
    param([string]$StatusJson)

    # Parse JSON; on failure return a safe sentinel rather than crashing.
    try {
        $d = $StatusJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return 'llmtrim: --'
    }

    # Case (1): daemon absent or not running.
    $daemon = $d.daemon
    if ($null -eq $daemon) {
        return 'llmtrim: off'
    }

    $running = $false
    if ($null -ne $daemon.running) {
        $running = [bool]$daemon.running
    } elseif ($null -ne $daemon.health) {
        # health == "stopped" or "degraded" -> not usefully running
        $running = ($daemon.health -ne 'stopped' -and $daemon.health -ne 'degraded')
    }

    if (-not $running) {
        return 'llmtrim: off'
    }

    # Case (3): cost present with round_trip_pct -> honest net-of-cache figure.
    # Only claim a reduction when it rounds to a positive whole percent: "-0%"
    # would assert savings of zero, which the honest-figure rule forbids.
    $cost = $d.cost
    if ($null -ne $cost) {
        $pct = $cost.round_trip_pct
        if ($null -ne $pct) {
            $val = [int][Math]::Round([double]$pct)
            if ($val -gt 0) {
                $badge = "llmtrim -${val}% net"
                $badge = Remove-ControlChars -Text $badge
                return $badge.Substring(0, [Math]::Min(80, $badge.Length))
            }
        }
    }

    # Case (2): cost null -- show gross saved_pct without "net" label.
    $inp   = $d.input
    $saved = if ($null -ne $inp) { $inp.saved_pct } else { $null }
    $val   = if ($null -ne $saved) { [int][Math]::Round([double]$saved) } else { 0 }

    if ($val -gt 0) {
        $badge = "llmtrim -${val}%"
    } else {
        $badge = 'llmtrim: --'
    }

    $badge = Remove-ControlChars -Text $badge
    return $badge.Substring(0, [Math]::Min(80, $badge.Length))
}

# ---------------------------------------------------------------------------
# Herdr liveness
#
# Twin of _herdr_alive in savings-annotate.sh. The poller is detached from the
# bootstrap hook that spawned it, so it cannot use a parent process to know when
# herdr is gone. stop-annotate.ps1 reaps it on workspace.closed, but if herdr
# crashes that hook never fires and the poller orphans forever (a core pinned per
# stale poller). The herdr control endpoint ($env:HERDR_SOCKET_PATH, a named pipe
# on Windows) is the one liveness signal that survives lost pid files: when herdr
# dies the pipe stops accepting connections. We probe it each iteration and exit
# after a short grace window so a brief herdr restart doesn't kill a live poller.
# ---------------------------------------------------------------------------

$DeadProbesBeforeExit = 3

function Test-HerdrAlive {
    # No socket in the environment -> not running under herdr (e.g. a manual test
    # run). Don't self-reap: there's nothing to be orphaned from.
    if ([string]::IsNullOrEmpty($env:HERDR_SOCKET_PATH)) { return $true }

    # Same pipe-name derivation as Invoke-HerdrRpc: \\.\pipe\<name>, a filesystem
    # path, or a bare name.
    $raw = $env:HERDR_SOCKET_PATH
    $pipeName = if ($raw -match '^\\\\\.\\pipe\\(.+)') {
        $Matches[1]
    } elseif ($raw -match '^[A-Za-z]:\\|^/') {
        [System.IO.Path]::GetFileName($raw)
    } else {
        $raw
    }

    $client = New-Object System.IO.Pipes.NamedPipeClientStream(
        '.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $client.Connect(2000)
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Main poll loop
# ---------------------------------------------------------------------------

$deadProbes = 0
while ($true) {
    # Self-reap once herdr is unreachable for the grace window. A transient failure
    # (herdr restart) resets the counter; sustained failure means herdr is gone and
    # no supervisor remains to stop us.
    if (Test-HerdrAlive) {
        $deadProbes = 0
    } else {
        $deadProbes++
        if ($deadProbes -ge $DeadProbesBeforeExit) { exit 0 }
    }

    try {
        # Run llmtrim status --json. status always exits 0; branch on the JSON
        # content, never on $LASTEXITCODE.
        # -join: `& cmd` yields a string[] when output is multi-line (pretty JSON
        # or a stray warning line); re-join with newlines so ConvertFrom-Json sees
        # valid JSON instead of a space-collapsed scalar.
        $rawJson = (& $llmtrim status --json 2>$null) -join "`n"
        if ([string]::IsNullOrEmpty($rawJson)) { $rawJson = '{}' }

        $badge = Get-Badge -StatusJson $rawJson

        if ($PaneId -ne '') {
            # Build params as an ordered hashtable so ConvertTo-Json produces
            # deterministic field order (readability) and no interpolation is
            # involved (cross-cutting no-interpolation rule).
            $params = [ordered]@{
                pane_id       = $PaneId
                source        = 'llmtrim'
                custom_status = $badge
                ttl_ms        = $TtlMs
            }
            $null = Invoke-HerdrRpc -Method 'pane.report_metadata' `
                -ParamsJson ($params | ConvertTo-Json -Compress)
        }
    } catch {
        # Best-effort: swallow the error and continue. Invoke-HerdrRpc throws
        # on RPC errors; catching here keeps the loop alive.
    }

    Start-Sleep -Seconds $PollSeconds
}
