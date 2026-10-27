# e2e: milestone=M1 timeout=120 order=140
# close-tree: closing the window ends the shell and the console clients
# attached to its pseudo console (bash.exe, ping.exe, the surface's
# OpenConsole.exe / conhost.exe) like Windows Terminal does. A program with a
# console of its own (`start cmd`) survives and is stopped by the scenario.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'close-tree' {
    $g = Start-BashE2e
    $survivor = 0
    try {
        Send-Line $g.Hwnd 'ping -n 60 127.0.0.1 > "$TEMP/gt-ping.txt" &'
        if (-not (Wait-ChildNamed $g @('ping.exe') 15)) { throw 'ping.exe never started' }
        Start-Sleep -Milliseconds 800
        $survivor = Start-SurvivorConsole $g
        $keep = @(Get-SurvivorIds $survivor)
        Write-E2eInfo "survivor console: $($keep -join ', ')"

        $snapshot = @(Get-ProcessTree $g.Pid)
        Write-E2eInfo "tree before close: $(Format-Procs $snapshot)"
        $names = @($snapshot | ForEach-Object { $_.Name.ToLowerInvariant() })
        if ($names -notcontains 'bash.exe' -or $names -notcontains 'ping.exe') { throw "unexpected tree before close: $(Format-Procs $snapshot)" }

        [void]$g.Process.CloseMainWindow()
        $exit = Wait-ProcessExit $g 3
        Write-E2eInfo "ghostty exited after $($exit.Ms) ms"
        if (-not $exit.Exited) { throw 'ghostty still running 3 s after the window was closed' }
        Assert-NoSurvivors $snapshot $g.Pid 8 -Except $keep -HostsMayLinger
        if (-not (Test-ProcessAlive $survivor)) { throw "the survivor console ($survivor) ended with the window" }
        # Once it ends, the pseudo console's host must go too.
        Stop-Survivor $survivor
        $survivor = 0
        Assert-NoSurvivors $snapshot $g.Pid 8
    } finally {
        Stop-Survivor $survivor
    }
}
