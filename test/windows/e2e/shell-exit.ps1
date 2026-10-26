# e2e: milestone=M1 timeout=120 order=150
# shell-exit: `exit` in the shell closes the window and the process within
# 3 s, with no orphan conhost.exe / OpenConsole.exe.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'shell-exit' {
    $g = Start-BashE2e
    $snapshot = @(Get-ProcessTree $g.Pid)
    Write-E2eInfo "tree before exit: $(Format-Procs $snapshot)"

    Send-Line $g.Hwnd 'exit'
    $exit = Wait-ProcessExit $g 15
    Write-E2eInfo "ghostty exited $($exit.Ms) ms after Enter (exited: $($exit.Exited))"
    if (-not $exit.Exited) { throw 'ghostty still running 15 s after the shell exited' }
    if ($exit.Ms -gt 3000) { throw "ghostty needed $($exit.Ms) ms to exit after the shell exited (limit 3000 ms)" }
    Assert-NoSurvivors $snapshot $g.Pid 3
}
