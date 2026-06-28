<#
.SYNOPSIS
  Windows named-pipe twin of herdr-rpc.sh - JSON-over-pipe client for herdr.

.DESCRIPTION
  On Windows the herdr plugin socket is a named pipe (interprocess
  GenericNamespaced -> \\.\pipe\<name>); $env:HERDR_SOCKET_PATH carries the
  namespaced name. The server reads one newline-terminated JSON request and
  replies with newline-delimited JSON (src/api/server.rs). Behaviorally identical
  to herdr-rpc.sh: prints the response "result" as JSON on success, writes
  "herdr-rpc: ..." to the error stream and exits non-zero otherwise.

  Dot-source to use Invoke-HerdrRpc, or run directly:
    pwsh bin/herdr-rpc.ps1 <method> <params-json>
#>

function Invoke-HerdrRpc {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [string]$ParamsJson = '{}'
    )

    # NOTE: this function may be dot-sourced into a hook. PowerShell's `exit`
    # inside a dot-sourced function terminates the WHOLE process and is not caught
    # by the caller's try/catch - which would defeat a hook's "always exit 0" rule.
    # So fail with `throw` (catchable) here; the CLI wrapper below maps it to exit.
    if ([string]::IsNullOrEmpty($env:HERDR_SOCKET_PATH)) {
        throw 'herdr-rpc: HERDR_SOCKET_PATH is unset (not running under herdr?)'
    }

    try {
        $params = $ParamsJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "herdr-rpc: invalid params JSON: $_"
    }

    $req = [ordered]@{
        id     = [guid]::NewGuid().ToString('N')
        method = $Method
        params = $params
    }
    $requestLine = $req | ConvertTo-Json -Compress -Depth 32

    # Derive the bare pipe name for NamedPipeClientStream('.', name). interprocess
    # GenericNamespaced may surface HERDR_SOCKET_PATH as a full UNC pipe path, a
    # bare name, or (defensively) a filesystem-looking path. Handle all three.
    $raw = $env:HERDR_SOCKET_PATH
    $pipeName = if ($raw -match '^\\\\\.\\pipe\\(.+)') {
        $Matches[1]                          # \\.\pipe\<name> -> bare name
    } elseif ($raw -match '^[A-Za-z]:\\|^/') {
        [System.IO.Path]::GetFileName($raw)  # filesystem path -> last segment
    } else {
        $raw                                 # already a bare pipe name
    }

    $client = New-Object System.IO.Pipes.NamedPipeClientStream(
        '.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $client.Connect(5000)
    } catch {
        throw "herdr-rpc: pipe connect failed: $_"
    }

    try {
        # UTF-8 WITHOUT a BOM: [System.Text.Encoding]::UTF8 emits a 3-byte BOM that
        # would prefix the first request and break the server's JSON parse.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $writer = New-Object System.IO.StreamWriter($client, $utf8NoBom)
        $writer.AutoFlush = $true
        $reader = New-Object System.IO.StreamReader($client, $utf8NoBom)

        # Explicit LF terminator (not WriteLine's CRLF) to match the server framing.
        $writer.Write($requestLine + "`n")
        # Bound the read: NamedPipeClientStream.ReadTimeout throws on a sync pipe,
        # so wait on the async read instead. A herdr that stalls mid-response must
        # not freeze the caller (the sh twin bounds this via socket.settimeout).
        $readTask = $reader.ReadLineAsync()
        if (-not $readTask.Wait(5000)) {
            throw 'herdr-rpc: read timed out'
        }
        $responseLine = $readTask.Result
    } finally {
        $client.Dispose()
    }

    if ([string]::IsNullOrEmpty($responseLine)) {
        throw 'herdr-rpc: empty response from herdr'
    }

    $resp = $responseLine | ConvertFrom-Json
    if ($null -ne $resp.error) {
        throw "herdr-rpc: rpc error $($resp.error.code): $($resp.error.message)"
    }

    # -InputObject (not pipe) so a single-element array result keeps its [ ] wrapper
    # instead of being unwrapped to a scalar (parity with the .sh json.dumps output).
    ConvertTo-Json -InputObject $resp.result -Compress -Depth 32
}

# Run directly (not dot-sourced) -> CLI mode. Here (and only here) a failure maps
# to a non-zero exit; dot-sourced callers catch the throw and stay on exit 0.
if ($MyInvocation.InvocationName -ne '.' -and $args.Count -ge 1) {
    $params = if ($args.Count -ge 2) { $args[1] } else { '{}' }
    try {
        Invoke-HerdrRpc -Method $args[0] -ParamsJson $params
    } catch {
        Write-Error $_
        exit 1
    }
}
