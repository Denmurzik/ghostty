# e2e: milestone=M1 timeout=150 order=170
# close-while-streaming: closing the window while the child floods the
# terminal does not hang; the process exits within 3 s and leaves nothing.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'close-while-streaming' {
    $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'stream') -NoDump:(-not $env:GHOSTTY_E2E_DUMP)
    if (-not (Wait-ChildNamed $g @('cmd.exe') 15)) { throw 'the streaming cmd.exe never started' }

    # Let the stream get going. The frame dump is off: reading every
    # frame back would add its own cost to the timings measured here
    # (set GHOSTTY_E2E_DUMP=1 to turn it on).
    Start-Sleep -Milliseconds 2000
    Start-Sleep -Milliseconds 1500
    if ($g.Process.HasExited) { throw 'the stream ended before the window could be closed (scenario too short)' }

    $snapshot = @(Get-ProcessTree $g.Pid)
    Write-E2eInfo "tree before close: $(Format-Procs $snapshot)"
    Save-Evidence 'streaming' $g -Window
    [void]$g.Process.CloseMainWindow()
    $exit = Wait-ProcessExit $g 15
    Write-E2eInfo "ghostty exited after $($exit.Ms) ms (exited: $($exit.Exited))"
    if (-not $exit.Exited) { throw 'ghostty still running 15 s after the window was closed while streaming' }
    if ($exit.Ms -gt 3000) { throw "ghostty needed $($exit.Ms) ms to exit after the window was closed while streaming (limit 3000 ms)" }
    Assert-NoSurvivors $snapshot $g.Pid 3
}
