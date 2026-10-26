# Test oracle for the Ghostty Win32 IPC pipe: sends one request frame
# (u32 LE length + JSON) and reads one response frame. The ops `state`,
# `action`, `dpi` and `color-scheme` are answered only by a Ghostty started
# with GHOSTTY_WIN32_TEST_IPC=1 (Start-E2eGhostty does that by default).
# Keep this file ASCII only (Windows PowerShell 5.1 reads a BOM-less file as
# ANSI). Mouse helpers are not here: they live in MouseInput.psm1.

Set-StrictMode -Version Latest

$script:ProtocolVersion = 1

# The server compares deadline_ms with kernel32!GetTickCount64, so the same
# clock is used here ([Environment]::TickCount64 is .NET Core only).
if (-not ('GhosttyIpc.Clock' -as [type])) {
    Add-Type -Namespace GhosttyIpc -Name Clock -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
"@
}

# Mirrors protocol.sanitizeClass: [A-Za-z0-9._-] kept, the rest '_', at most 80.
# The server sanitizes UTF-8 bytes, so only an ASCII class maps the same way:
# keep test classes ASCII.
function ConvertTo-GhosttyPipeClass([string]$Class) {
    if ($Class.Length -gt 80) { $Class = $Class.Substring(0, 80) }
    [regex]::Replace($Class, '[^A-Za-z0-9._-]', '_')
}

# The pipe name without the \\.\pipe\ prefix:
# ghostty-<sid>-<session>-<u|a>-<class>.
function Get-GhosttyPipeName {
    param(
        [Parameter(Mandatory)][string]$Class,
        [switch]$Elevated
    )
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $session = (Get-Process -Id $PID).SessionId
    $marker = if ($Elevated) { 'a' } else { 'u' }
    'ghostty-{0}-{1}-{2}-{3}' -f $sid, $session, $marker, (ConvertTo-GhosttyPipeClass $Class)
}

function Read-PipeExact([IO.Stream]$Stream, [int]$Count) {
    $buf = New-Object 'byte[]' $Count
    $got = 0
    while ($got -lt $Count) {
        $n = $Stream.Read($buf, $got, $Count - $got)
        if ($n -le 0) { throw 'ghostty ipc: pipe closed before the response was complete' }
        $got += $n
    }
    , $buf
}

# Sends `$Request` (a hashtable: op, args, core_surface, surface, window,
# action, dpi, scheme, ...) and returns the parsed response with the members
# v, code, stdout, stderr and data. `v` and `deadline_ms` are filled in here:
# the server must not act on a request older than the timeout.
function Invoke-GhosttyIpc {
    param(
        [Parameter(Mandatory)][string]$Class,
        [Parameter(Mandatory)][hashtable]$Request,
        [int]$TimeoutMs = 5000,
        [switch]$Elevated
    )
    $req = @{} + $Request
    $req['v'] = $script:ProtocolVersion
    $req['deadline_ms'] = [int64][GhosttyIpc.Clock]::GetTickCount64() + $TimeoutMs
    $json = $req | ConvertTo-Json -Compress -Depth 8
    $payload = [Text.Encoding]::UTF8.GetBytes($json)

    $name = Get-GhosttyPipeName -Class $Class -Elevated:$Elevated
    $pipe = New-Object IO.Pipes.NamedPipeClientStream '.', $name, ([IO.Pipes.PipeDirection]::InOut), ([IO.Pipes.PipeOptions]::None)
    try {
        $pipe.Connect($TimeoutMs)
        $frame = New-Object 'byte[]' (4 + $payload.Length)
        [BitConverter]::GetBytes([uint32]$payload.Length).CopyTo($frame, 0)
        $payload.CopyTo($frame, 4)
        $pipe.Write($frame, 0, $frame.Length)
        $pipe.Flush()

        $head = Read-PipeExact $pipe 4
        $len = [BitConverter]::ToUInt32($head, 0)
        $body = Read-PipeExact $pipe ([int]$len)
        [Text.Encoding]::UTF8.GetString($body) | ConvertFrom-Json
    } finally {
        $pipe.Dispose()
    }
}

# The `state` document, or throws with the server's answer.
function Get-GhosttyState {
    param([Parameter(Mandatory)][string]$Class)
    $r = Invoke-GhosttyIpc -Class $Class -Request @{ op = 'state' }
    if ($r.code -ne 0) { throw "ghostty ipc state: code $($r.code): $($r.stderr)" }
    $r.data
}

# Runs a binding action (for example 'text:echo hi\r'); `-Surface 0` is the
# focused surface. Returns the `performed` flag.
function Invoke-GhosttyAction {
    param(
        [Parameter(Mandatory)][string]$Class,
        [Parameter(Mandatory)][string]$Action,
        [int]$Surface = 0
    )
    $r = Invoke-GhosttyIpc -Class $Class -Request @{ op = 'action'; action = $Action; surface = $Surface }
    if ($r.code -ne 0) { throw "ghostty ipc action '$Action': code $($r.code): $($r.stderr)" }
    [bool]$r.data.performed
}

# Polls `state` until `$Predicate` (called with the state as $_) returns
# true; returns that state, or throws after `$TimeoutSec`.
function Wait-GhosttyState {
    param(
        [Parameter(Mandatory)][string]$Class,
        [Parameter(Mandatory)][scriptblock]$Predicate,
        [double]$TimeoutSec = 10,
        [int]$PollMs = 100
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $last = $null
    $lastErr = $null
    while ($true) {
        try {
            $last = Get-GhosttyState -Class $Class
            $ok = $last | ForEach-Object $Predicate
            if ($ok) { return $last }
        } catch {
            $lastErr = $_.Exception.Message
        }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
            $dump = if ($last) { $last | ConvertTo-Json -Compress -Depth 10 } else { "no state ($lastErr)" }
            throw "ghostty ipc: condition not met within $TimeoutSec s: {$Predicate}; last state: $dump"
        }
        Start-Sleep -Milliseconds $PollMs
    }
}

Export-ModuleMember -Function Get-GhosttyPipeName, Invoke-GhosttyIpc, Get-GhosttyState, Invoke-GhosttyAction, Wait-GhosttyState
