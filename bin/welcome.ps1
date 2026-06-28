#!/usr/bin/env pwsh
# welcome.ps1 - content for the first-run welcome / disclosure pane. Prints the
# disclosure, then holds the pane open until the user closes it.

$CaDir = if ($null -ne $env:LLMTRIM_HOME -and $env:LLMTRIM_HOME -ne '') {
    $env:LLMTRIM_HOME
} else {
    Join-Path $HOME '.llmtrim'
}

Write-Host @"
  llmtrim - active in this herdr

  What it does
    llmtrim runs a local proxy. Your agents' HTTPS traffic is routed through it
    (via HTTPS_PROXY) and compressed to cut token cost. The live savings badge
    on each agent pane and the "llmtrim - live savings" dashboard show the effect.

  What you are trusting
    - The proxy terminates TLS locally, so it reads all agent traffic in
      PLAINTEXT, including API keys and tokens. It runs only on your machine.
    - A local certificate authority was generated. Its private key lives at
        $CaDir\ca.key
      Guard it like an SSH private key: anyone with it can MITM your TLS.
    - Trust is ENV-LEVEL only. 'llmtrim setup' set SSL_CERT_FILE and
      NODE_EXTRA_CA_CERTS (pointing at $CaDir\ca.pem) in your shell profile -
      look for the '# >>> llmtrim >>>' block in your PowerShell `$PROFILE.
      Your OS trust store and browsers are NOT touched.

  Undo
    llmtrim uninstall            # remove the proxy, CA, and profile changes
    herdr plugin uninstall llmtrim.proxy

  You can close this pane now (q, or close it the usual way).
"@

# Hold the pane open. herdr reaps the pane process when the pane is closed.
while ($true) { Start-Sleep -Seconds 86400 }
