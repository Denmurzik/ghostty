# e2e: milestone=M5 timeout=150 order=970
# profiles-menu: a right click on the "+" of the tab strip opens the profile
# menu (a #32768 window of the process); the accelerator of "Command Prompt"
# opens a third tab whose shell is cmd.exe. The palette entry "New Tab:
# Windows PowerShell" opens a fourth tab with powershell.exe. state.m5.profiles
# lists the expected ids. No WSL item is ever chosen. Keep this file ASCII only
# (Windows PowerShell 5.1 reads a BOM-less script as ANSI).
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'profiles-menu' {
    $g = Start-E2eGhostty -ConfigText "confirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = always`n"
    if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "no frame dump at $($g.Dump)" }
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)

    function Get-Win {
        $d = Get-GhosttyState -Class $g.Class
        @($d.windows)[0]
    }
    function Wait-Win([string]$What, [scriptblock]$Predicate, [double]$TimeoutSec = 10) {
        $w = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
            $w = Get-Win
            if ($w -and (& $Predicate $w)) { $w }
        }
        if (-not $w) { throw "timeout waiting for: $What; state: $(Get-Win | ConvertTo-Json -Depth 8 -Compress)" }
        $w
    }
    function Get-Centre($R) { , @([int](($R[0] + $R[2]) / 2), [int](($R[1] + $R[3]) / 2)) }
    function Get-Popup([string]$Class) {
        @([GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, $Class) | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) })
    }
    function Wait-Popup([string]$Class, [bool]$Present, [string]$What, [double]$TimeoutSec = 4) {
        $ok = Wait-Until -TimeoutSec $TimeoutSec -PollMs 50 -Condition { (@(Get-Popup $Class).Count -gt 0) -eq $Present }
        if (-not $ok) { throw "$What : the $Class window is $(if ($Present) { 'missing' } else { 'still there' })" }
    }
    function Count-Shells([string]$Name) {
        @(Get-ProcessTree $g.Pid | Where-Object { $_.Name.ToLowerInvariant() -eq $Name }).Count
    }

    # 1. Two tabs, right click on "+".
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
    $w = Wait-Win 'two tabs' { param($w) @($w.tabs).Count -eq 2 -and $w.strip.new_tab }
    $before = Count-Shells 'cmd.exe'
    $c = Get-Centre @($w.strip.new_tab)
    Send-MouseClick -Hwnd $g.Hwnd -X $c[0] -Y $c[1] -Button right
    Wait-Popup '#32768' $true 'right click on the + button'
    $shotDir = Get-EvidenceDir
    if ($shotDir) { Save-WindowShot $g.Hwnd -Margin 120 (Join-Path $shotDir 'profiles-menu.png') }

    # The list is loaded by now; WSL items are listed but never chosen here.
    $ids = @((Get-IpcData (Get-GhosttyState -Class $g.Class)).m5.profiles.ids)
    foreach ($want in 'default', 'powershell', 'cmd') {
        if ($ids -notcontains $want) { throw "profile '$want' is missing from state.m5.profiles.ids: $($ids -join ',')" }
    }
    if ($ids[0] -ne 'default') { throw "the first profile is '$($ids[0])', expected 'default'" }

    # "&Command Prompt": the accelerator letter alone picks the item.
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'c' -Panel
    Wait-Popup '#32768' $false 'the accelerator closes the menu'
    [void](Wait-Win 'a third tab' { param($w) @($w.tabs).Count -eq 3 })
    if (-not (Wait-Until -TimeoutSec 15 -PollMs 200 -Condition { (Count-Shells 'cmd.exe') -gt $before })) {
        throw "no new cmd.exe under ghostty after the Command Prompt item: $(Format-Procs (Get-ProcessTree $g.Pid))"
    }

    # 2. The palette entry.
    $beforePs = Count-Shells 'powershell.exe'
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_command_palette')
    $open = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition {
        $p = (Get-IpcData (Get-GhosttyState -Class $g.Class)).m3.palette
        $p.open -and $p.focused
    }
    if (-not $open) { throw 'the palette did not open' }
    Invoke-SendInput -Hwnd $g.Hwnd -Text 'New Tab: Windows PowerShell' -Panel
    $first = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition {
        $p = (Get-IpcData (Get-GhosttyState -Class $g.Class)).m3.palette
        if ($p.first -eq 'New Tab: Windows PowerShell') { $p.first }
    }
    if (-not $first) { throw 'the palette does not list "New Tab: Windows PowerShell" first' }
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter' -Panel
    [void](Wait-Win 'a fourth tab' { param($w) @($w.tabs).Count -eq 4 })
    if (-not (Wait-Until -TimeoutSec 15 -PollMs 200 -Condition { (Count-Shells 'powershell.exe') -gt $beforePs })) {
        throw "no new powershell.exe under ghostty after the palette entry: $(Format-Procs (Get-ProcessTree $g.Pid))"
    }
}
