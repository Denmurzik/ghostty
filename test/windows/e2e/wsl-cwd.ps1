# e2e: milestone=M7 timeout=150 order=1150
# wsl-cwd: a WSL pane's OSC 7 path (a POSIX path) is kept, and a new split /
# tab of that pane starts `wsl.exe --cd <path>` (R-M7-10). No WSL runs: the
# pane command is a fake wsl.exe (New-FakeExe -Kind osc7), recognised by its
# file name. What the new panes were started with is read from the command
# line of the fake processes (the pane output is not readable by a script).
#   1. the first pane: no `--cd` (nothing to inherit), reports the path;
#      state `pwd` is the POSIX path as is (spaces kept);
#   2. new_split and new_tab: each new fake wsl.exe has the arguments
#      `--cd "<path>"`, and its process directory is not the POSIX path.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\FakeExe.psm1') -Force

Invoke-E2eScenario 'wsl-cwd' {
    $posix = '/home/e2e/my proj'
    # The fake writes file://fake/<value>; a space is percent-encoded like a shell does.
    $uriTail = 'home/e2e/my%20proj'

    $bin = Join-Path $script:Sbx.Tmp 'bin'
    $wsl = Join-Path $bin 'wsl.exe'
    if ($wsl -match '\s') { throw "E2E-SKIP: the sandbox path has a blank ($wsl): direct: splits on blanks" }
    [void](New-FakeExe -Path $wsl -Kind osc7)

    function Get-FakeWsl {
        @(Get-CimInstance -ClassName Win32_Process -Filter "Name='wsl.exe'" |
            Where-Object { $_.ExecutablePath -ieq $wsl })
    }
    function Get-FocusedPwd($G) {
        $d = Get-GhosttyState -Class $G.Class
        foreach ($w in @($d.windows)) {
            foreach ($t in @($w.tabs)) {
                foreach ($s in @($t.surfaces)) { if ($s.focused) { return [string]$s.pwd } }
            }
        }
        ''
    }
    function Wait-Pwd($G, [string]$What) {
        $ok = Wait-Until -TimeoutSec 15 -PollMs 150 -Condition { (Get-FocusedPwd $G) -ceq $posix }
        if (-not $ok) {
            $tail = if (Test-Path -LiteralPath $G.Log) { (Get-Content -LiteralPath $G.Log -Tail 15) -join ' | ' } else { 'no log' }
            throw "$What : pwd is '$(Get-FocusedPwd $G)', expected '$posix'; log: $tail"
        }
    }
    function Wait-FakeCount($G, [int]$Count, [string]$What) {
        $ok = Wait-Until -TimeoutSec 15 -PollMs 200 -Condition { (Get-FakeWsl).Count -ge $Count }
        if (-not $ok) { throw "$What : $((Get-FakeWsl).Count) fake wsl.exe running, expected $Count" }
    }
    function Get-CdProcs { @(Get-FakeWsl | Where-Object { $_.CommandLine -match '--cd' }) }

    $cfg = "command = direct:$wsl`nconfirm-close-surface = false`n"
    $g = Start-E2eGhostty -ConfigText $cfg -Env @{ FAKE_OSC7_PATH = $uriTail }

    # 1. The first pane: no --cd, and the POSIX path is its pwd.
    Wait-FakeCount $g 1 'first pane'
    Wait-Pwd $g 'first pane reports the POSIX path'
    if ((Get-CdProcs).Count -ne 0) { throw 'the first pane got --cd' }
    Save-Evidence -Tag 'wsl-cwd-first' -G $g -Window

    # 2. A split and a tab inherit it through --cd, as one argv element.
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_split:right')
    Wait-FakeCount $g 2 'split'
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
    Wait-FakeCount $g 3 'tab'

    $ok = Wait-Until -TimeoutSec 15 -PollMs 200 -Condition { (Get-CdProcs).Count -ge 2 }
    if (-not $ok) {
        $cmds = (Get-FakeWsl | ForEach-Object { $_.CommandLine }) -join ' || '
        throw "expected 2 panes started with --cd, got: $cmds"
    }
    foreach ($p in Get-CdProcs) {
        # CommandLineToArgvW rule: the path with a blank is quoted.
        if ($p.CommandLine -notmatch '--cd "/home/e2e/my proj"') { throw "unexpected command line: $($p.CommandLine)" }
    }
    Wait-Pwd $g 'the new tab reports the path'
    Save-Evidence -Tag 'wsl-cwd-tab' -G $g -Window
}
