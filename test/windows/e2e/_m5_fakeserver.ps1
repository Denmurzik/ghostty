# M5 e2e helper: a fake release server on 127.0.0.1 (a free port), served from
# a runspace. Dot-source it from a scenario. Keep this file ASCII only.
#
#   $srv = Start-FakeRelease -Body <file> [-Status <code>] [-Silent]
#   $srv.Url                       http://127.0.0.1:<port>/repos/x/releases
#   Set-FakeRelease $srv -Body <file> -Status 403 | -Silent
#   $srv.Requests                  one line per request: request line, UA, Accept
#   Get-FakeAccepted $srv          count of accepted connections (-Silent too)
#   Stop-FakeRelease $srv
#
# -Silent accepts the connection and never answers (the request is still
# logged); the held sockets are closed by Stop-FakeRelease.

function Start-FakeRelease {
    param(
        [Parameter(Mandatory)][string]$Body,
        [int]$Status = 200,
        [switch]$Silent
    )
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port

    $ctl = [hashtable]::Synchronized(@{
            Stop     = $false
            Body     = $Body
            Status   = $Status
            Silent   = [bool]$Silent
            Accepted = 0
        })
    $requests = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
            param($listener, $ctl, $requests)
            $held = New-Object System.Collections.Generic.List[object]
            try {
                while (-not $ctl.Stop) {
                    if (-not $listener.Pending()) { Start-Sleep -Milliseconds 20; continue }
                    $client = $listener.AcceptTcpClient()
                    $ctl.Accepted = $ctl.Accepted + 1
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 2000
                    # The request head, up to the blank line.
                    $head = New-Object System.Text.StringBuilder
                    $buf = New-Object 'byte[]' 1024
                    try {
                        while ($head.Length -lt 8192 -and -not $head.ToString().Contains("`r`n`r`n")) {
                            $n = $stream.Read($buf, 0, $buf.Length)
                            if ($n -le 0) { break }
                            [void]$head.Append([Text.Encoding]::ASCII.GetString($buf, 0, $n))
                        }
                    } catch { }
                    $text = $head.ToString()
                    $line = ($text -split "`r`n")[0]
                    $ua = ([regex]::Match($text, '(?im)^user-agent:\s*(.*)$')).Groups[1].Value.Trim()
                    $accept = ([regex]::Match($text, '(?im)^accept:\s*(.*)$')).Groups[1].Value.Trim()
                    $requests.Enqueue("$line | UA=$ua | Accept=$accept")
                    if ($ctl.Silent) { $held.Add($client); continue }
                    try {
                        $bytes = [IO.File]::ReadAllBytes($ctl.Body)
                        $reason = if ($ctl.Status -eq 200) { 'OK' } else { 'Error' }
                        $hdr = "HTTP/1.1 $($ctl.Status) $reason`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
                        $h = [Text.Encoding]::ASCII.GetBytes($hdr)
                        $stream.Write($h, 0, $h.Length)
                        $stream.Write($bytes, 0, $bytes.Length)
                        $stream.Flush()
                    } catch { }
                    $client.Close()
                }
            } finally {
                foreach ($c in $held) { try { $c.Close() } catch { } }
                try { $listener.Stop() } catch { }
            }
        }).AddArgument($listener).AddArgument($ctl).AddArgument($requests)
    $handle = $ps.BeginInvoke()

    [pscustomobject]@{
        Port     = $port
        Url      = "http://127.0.0.1:$port/repos/Denmurzik/ghostty/releases?per_page=20"
        Ctl      = $ctl
        Requests = $requests
        Ps       = $ps
        Runspace = $rs
        Handle   = $handle
    }
}

function Set-FakeRelease {
    param(
        [Parameter(Mandatory)]$Server,
        [string]$Body,
        [int]$Status = 200,
        [switch]$Silent
    )
    if ($Body) { $Server.Ctl.Body = $Body }
    $Server.Ctl.Status = $Status
    $Server.Ctl.Silent = [bool]$Silent
}

function Get-FakeAccepted($Server) { [int]$Server.Ctl.Accepted }

function Stop-FakeRelease {
    param([Parameter(Mandatory)]$Server)
    $Server.Ctl.Stop = $true
    try { [void]$Server.Handle.AsyncWaitHandle.WaitOne(3000) } catch { }
    try { $Server.Ps.Dispose() } catch { }
    try { $Server.Runspace.Dispose() } catch { }
}
