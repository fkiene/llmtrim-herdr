#!/usr/bin/env pwsh
# open-dashboard.ps1 - action: open (or focus) the llmtrim live savings dashboard.
#
# Windows twin of open-dashboard.sh. Calls plugin.pane.open via the herdr RPC
# helper to surface the "dashboard" pane (id "dashboard", running
# `llmtrim status --watch`). Actions may exit non-zero on failure; errors are
# written to the error stream.

. (Join-Path $PSScriptRoot 'herdr-rpc.ps1')

$paneParams = [ordered]@{
    plugin_id  = 'llmtrim.proxy'
    entrypoint = 'dashboard'
}

Invoke-HerdrRpc -Method 'plugin.pane.open' `
    -ParamsJson ($paneParams | ConvertTo-Json -Compress)
