# e2e: milestone=M1 timeout=150 order=100
# ctrl-c: Ctrl+C interrupts a running console program and the shell stays
# usable.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'ctrl-c' {
    $g = Start-BashE2e
    Send-Line $g.Hwnd 'ping -t 127.0.0.1 > "$TEMP/gt-ping.txt"'
    $ping = Wait-ChildNamed $g @('ping.exe') 15
    if (-not $ping) { throw "ping.exe never started; tree: $(Format-Procs (Get-ProcessTree $g.Pid))" }
    Start-Sleep -Milliseconds 1500

    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+c'
    $gone = Wait-Until -TimeoutSec 5 -PollMs 100 -Condition {
        -not (@(Get-ProcessTree $g.Pid | Where-Object { $_.Name -eq 'ping.exe' }).Count)
    }
    if (-not $gone) { throw 'ping.exe still running 5 s after Ctrl+C' }

    Send-Line $g.Hwnd 'echo ctrl-c-ok > "$TEMP/gt-ctrlc.txt"'
    if (-not (Wait-File (Join-Path $g.Sandbox.Tmp 'gt-ctrlc.txt') 10)) {
        throw 'the shell did not run the next command after Ctrl+C'
    }
    Write-E2eInfo 'ping interrupted, shell alive'
}
