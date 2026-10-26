# e2e: milestone=M1 timeout=120 order=140
# close-tree: closing the window while a program runs kills the whole tree:
# no ping.exe, bash.exe, conhost.exe or OpenConsole.exe survives.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'close-tree' {
    $g = Start-BashE2e
    Send-Line $g.Hwnd 'ping -n 60 127.0.0.1 > "$TEMP/gt-ping.txt"'
    if (-not (Wait-ChildNamed $g @('ping.exe') 15)) { throw 'ping.exe never started' }
    Start-Sleep -Milliseconds 800

    $snapshot = @(Get-ProcessTree $g.Pid)
    Write-E2eInfo "tree before close: $(Format-Procs $snapshot)"
    $names = @($snapshot | ForEach-Object { $_.Name.ToLowerInvariant() })
    if ($names -notcontains 'bash.exe' -or $names -notcontains 'ping.exe') { throw "unexpected tree before close: $(Format-Procs $snapshot)" }

    [void]$g.Process.CloseMainWindow()
    $exit = Wait-ProcessExit $g 3
    Write-E2eInfo "ghostty exited after $($exit.Ms) ms"
    if (-not $exit.Exited) { throw 'ghostty still running 3 s after the window was closed' }
    Assert-NoSurvivors $snapshot $g.Pid 3
}
