# e2e: milestone=M2 timeout=120 order=450
# tab-close-tree: close_tab:this ends the tab's shell and the console clients
# attached to its pseudo console (ping.exe). The other tab's shell keeps
# working, and a program with a console of its own (`start cmd`) started in
# the closed tab survives and is stopped by the scenario.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'tab-close-tree' {
    # confirm-close-surface = false comes with the config, so closing a tab
    # with a running ping does not ask.
    $g = Start-BashE2e
    $survivor = 0
    try {
        $before = @(Get-ProcessTree $g.Pid)
        $beforeIds = @($before | ForEach-Object { [int]$_.ProcessId })

        # Tab 1 becomes active; wait for its own shell.
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
        $shell = Wait-Until -TimeoutSec 20 -PollMs 200 -Condition {
            Get-ProcessTree $g.Pid | Where-Object { $_.Name -ieq 'bash.exe' -and $beforeIds -notcontains [int]$_.ProcessId } | Select-Object -First 1
        }
        if (-not $shell) { throw 'tab 1 never started a shell' }

        $ready = Join-Path $g.Sandbox.Tmp 'gt-tab1-ready.txt'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $ready)) {
            if ($sw.Elapsed.TotalSeconds -gt 30) { throw 'tab 1 shell did not run a typed line' }
            Send-Line $g.Hwnd 'echo ready > "$TEMP/gt-tab1-ready.txt"'
            [void](Wait-File $ready 4)
        }

        Send-Line $g.Hwnd 'ping -n 60 127.0.0.1 > "$TEMP/gt-ping.txt"'
        $ping = Wait-Until -TimeoutSec 15 -PollMs 200 -Condition {
            Get-ProcessTree $g.Pid | Where-Object { $_.Name -ieq 'ping.exe' -and $beforeIds -notcontains [int]$_.ProcessId } | Select-Object -First 1
        }
        if (-not $ping) { throw 'ping.exe never started in tab 1' }
        Start-Sleep -Milliseconds 800
        $survivor = Start-SurvivorConsole $g
        $keep = @(Get-SurvivorIds $survivor)

        # What belongs to tab 1: everything that was not there before it.
        $snapshot = @(Get-ProcessTree $g.Pid | Where-Object { $beforeIds -notcontains [int]$_.ProcessId })
        Write-E2eInfo "tab 1 tree: $(Format-Procs $snapshot)"
        $names = @($snapshot | ForEach-Object { $_.Name.ToLowerInvariant() })
        if ($names -notcontains 'bash.exe' -or $names -notcontains 'ping.exe') { throw "unexpected tab 1 tree: $(Format-Procs $snapshot)" }

        [void](Invoke-GhosttyAction -Class $g.Class -Action 'close_tab:this')
        Assert-NoSurvivors $snapshot $g.Pid 6 -Except $keep -GhosttyAlive
        if (-not (Test-ProcessAlive $g.Pid)) { throw 'ghostty ended with the closed tab' }
        if (-not (Test-ProcessAlive $survivor)) { throw "the survivor console ($survivor) ended with the tab" }
        $left = @(Get-ProcessTree $g.Pid | Where-Object { $beforeIds -contains [int]$_.ProcessId })
        if ($left.Count -ne $beforeIds.Count) { throw "tab 0 lost processes: $(Format-Procs $left), had $(Format-Procs $before)" }

        # Tab 0 is active again and its shell still runs lines.
        $alive = Join-Path $g.Sandbox.Tmp 'gt-tab0-alive.txt'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $alive)) {
            if ($sw.Elapsed.TotalSeconds -gt 20) { throw 'tab 0 shell stopped answering after tab 1 was closed' }
            Send-Line $g.Hwnd 'echo alive > "$TEMP/gt-tab0-alive.txt"'
            [void](Wait-File $alive 4)
        }
    } finally {
        Stop-Survivor $survivor
    }
}
