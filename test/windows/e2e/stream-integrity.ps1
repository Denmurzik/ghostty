# stream-integrity: Git Bash `cat`s a file of numbered, CRC-checked lines
# (50 MB by default, GHOSTTY_E2E_STREAM_MB to change it); the terminal must
# then hold every line, unchanged and in order. What the terminal holds is
# read back with write_screen_file (bound in configs/stream-integrity), not
# from pixels. Reports the throughput of the `cat` as well.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_stream.ps1')

# The newest write_screen_file dump in the sandbox TEMP, once Ghostty has
# closed it (a read share that denies writers fails while it writes).
function Wait-ScreenDump($G, [double]$TimeoutSec) {
    Wait-Until -TimeoutSec $TimeoutSec -PollMs 250 -Condition {
        $f = Get-ChildItem -LiteralPath $G.Sandbox.Tmp -Recurse -Filter 'screen.txt' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc | Select-Object -Last 1
        if (-not $f -or $f.Length -eq 0) { return $null }
        try {
            $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'Read')
            $fs.Dispose()
            $f.FullName
        } catch [IO.IOException] {
            $null
        }
    }
}

Invoke-E2eScenario 'stream-integrity' {
    $mb = if ($env:GHOSTTY_E2E_STREAM_MB) { [double]$env:GHOSTTY_E2E_STREAM_MB } else { 50 }
    $endMarker = 'stream-done-42'

    $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'stream-integrity') -NoDump
    Wait-BashReady $g

    $stream = New-CheckedStream (Join-Path $g.Sandbox.Tmp 'gt-stream.txt') $mb
    Write-E2eInfo "stream: $($stream.Lines) lines, $($stream.Bytes) bytes"

    # The end marker is computed by the shell, so the typed command line
    # never contains it.
    $done = Join-Path $g.Sandbox.Tmp 'gt-stream-done.txt'
    Send-Line $g.Hwnd 'cat "$TEMP/gt-stream.txt"; echo stream-done-$((6*7)); echo done > "$TEMP/gt-stream-done.txt"'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if (-not (Wait-File $done 600)) { throw "cat of $mb MB did not finish within 600 s" }
    $sec = $sw.Elapsed.TotalSeconds
    Write-E2eInfo ("throughput: {0:N1} MB in {1:N1} s = {2:N1} MB/s (until the shell ran the next command)" -f
        ($stream.Bytes / 1MB), $sec, ($stream.Bytes / 1MB / $sec))

    # The shell is done, but the terminal may still be parsing the last
    # reads: dump again until the end marker made it into the dump.
    $result = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        Get-ChildItem -LiteralPath $g.Sandbox.Tmp -Recurse -Filter 'screen.txt' -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
        $dumpSw = [Diagnostics.Stopwatch]::StartNew()
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+shift+f12'
        $dump = Wait-ScreenDump $g 180
        if (-not $dump) { throw 'write_screen_file produced no dump within 180 s' }
        Write-E2eInfo ("screen dump {0:N1} MB after {1:N1} s" -f ((Get-Item -LiteralPath $dump).Length / 1MB), $dumpSw.Elapsed.TotalSeconds)
        $result = Test-CheckedStream $dump $stream.Lines $endMarker
        if ($result.SawEnd) { break }
        Start-Sleep -Seconds 2
    }

    Write-E2eInfo ("checked: {0} of {1} lines match, {2} missing, {3} changed, {4} extra, end marker {5}" -f
        $result.Matched, $result.Expected, $result.Missing, $result.Changed, $result.Extra,
        $(if ($result.SawEnd) { 'seen' } else { 'not seen' }))
    foreach ($p in $result.Problems) { Write-E2eInfo $p }
    # What the window shows at the end, to compare its last lines with the
    # dump by eye (the scenario checks the terminal, not the renderer).
    Save-Evidence 'final' $g -Window
    $dir = Get-EvidenceDir
    if ($dir) { Get-Content -LiteralPath $dump -Tail 40 | Set-Content -LiteralPath (Join-Path $dir 'stream-integrity-dump-tail.txt') }

    $clean = $result.SawEnd -and $result.Matched -eq $stream.Lines -and
        $result.Missing -eq 0 -and $result.Changed -eq 0 -and $result.Extra -eq 0
    if (-not $clean) {
        $dir = Get-EvidenceDir
        if ($dir) { Copy-Item -LiteralPath $dump -Destination (Join-Path $dir 'stream-integrity-screen.txt') -Force }
        throw ("the terminal does not hold the stream intact: {0} missing, {1} changed, {2} extra lines, end marker {3}" -f
            $result.Missing, $result.Changed, $result.Extra, $(if ($result.SawEnd) { 'seen' } else { 'not seen' }))
    }
}
