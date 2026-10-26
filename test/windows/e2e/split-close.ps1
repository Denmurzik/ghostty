# e2e: milestone=M2 timeout=120 order=240
# split-close: `exit` in the focused split of three closes just that pane:
# two surfaces are left, the focus is on a live one, and the shell of the
# closed pane left no cmd.exe / conhost behind after 3 s.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')

Invoke-E2eScenario 'split-close' {
    $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'cmd')
    if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }

    Wait-SurfaceCount $g 1 | Out-Null
    Invoke-SplitAction $g 'new_split:right'
    Invoke-SplitAction $g 'new_split:down'
    $st = Wait-SurfaceCount $g 3
    $focused = @(Get-SurfaceBoxes $st | Where-Object { $_.Focused })
    if ($focused.Count -ne 1) { throw 'expected one focused pane before the close' }
    $closed = $focused[0]

    # Wait for all three shells.
    $shells = Wait-Until -TimeoutSec 15 -PollMs 250 -Condition {
        $t = @(Get-ProcessTree $g.Pid | Where-Object { $_.Name -ieq 'cmd.exe' })
        if ($t.Count -ge 3) { $t }
    }
    if (-not $shells) { throw 'three cmd.exe shells never started' }
    Start-Sleep -Milliseconds 1000
    $snapshot = @(Get-ProcessTree $g.Pid)
    Write-E2eInfo "tree before exit: $(Format-Procs $snapshot)"

    # Into the focused pane (no surface id = the focused one).
    Invoke-SplitAction $g 'text:exit\r'
    $st = Wait-SurfaceCount $g 2 10
    $boxes = Get-SurfaceBoxes $st
    if ($boxes | Where-Object { $_.Id -eq $closed.Id }) { throw "closed pane $($closed.Id) is still in the state" }
    $live = @($boxes | Where-Object { $_.Focused })
    if ($live.Count -ne 1) { throw "expected one focused pane after the close, found $($live.Count)" }
    foreach ($x in $boxes) { if (-not $x.Visible) { throw "surface $($x.Id) is not visible" } }
    Assert-NoOverlap $boxes

    Start-Sleep -Seconds 3
    $now = @(Get-ProcessTree $g.Pid)
    Write-E2eInfo "tree after exit: $(Format-Procs $now)"
    foreach ($name in 'cmd.exe', 'conhost.exe', 'OpenConsole.exe') {
        $was = @($snapshot | Where-Object { $_.Name -ieq $name }).Count
        $is = @($now | Where-Object { $_.Name -ieq $name }).Count
        if ($was -gt 0 -and $is -ne $was - 1) { throw "$name count went $was -> $is, expected $($was - 1)" }
    }
    $nowPids = @($now | ForEach-Object { $_.ProcessId })
    $gone = @($snapshot | Where-Object { $_.Name -ieq 'cmd.exe' -and $nowPids -notcontains $_.ProcessId })
    if ($gone.Count -ne 1) { throw "expected exactly one cmd.exe to end, $($gone.Count) did" }

    $errors = @(Get-LogErrors $g)
    if ($errors.Count) { throw "error lines in ghostty.log: $($errors -join ' | ')" }
}
