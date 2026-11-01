# e2e: milestone=M8 timeout=150 order=1200
# visibility-hidden: a window that is not on screen tells core its surfaces
# are not visible (mode 2033 report, render pause). Git Bash panes enable
# mode 2033 and log the reports they read. Pass/fail is on the test IPC field
# `core_visible`; the `vis.log` checks are reported as SKIP when the console
# drops mode 2033 (then run with `windows-conpty = bundled`).
#  1. start: `;1n` logged, core_visible = true.
#  2. toggle_visibility: within 1 s core_visible = false and `;2n` logged.
#  3. toggle_visibility again: `;1n`, core_visible = true.
#  4. the quick terminal shown, then hidden (animation done): its surface
#     has core_visible = false and its reader read `;2n`.
#  5. new_tab: the inactive tab's reader read `;2n`; goto_tab:1: `;1n`.
#  6. minimize (ShowWindowAsync SW_MINIMIZE): `;2n`; restore: `;1n`.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

if (-not ('GhosttyE2e.Vis' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Vis -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int cmd);
'@
}
$script:SW_MINIMIZE = 6
$script:SW_RESTORE = 9
$script:LogsOk = $true

# Quote-free in Git Bash: enable 2033 and append every 9-byte report.
function Get-ReaderLine([string]$Name) {
    'printf ''\e[?2033h''; while read -rsn9 -t 30 r; do printf ''%q\n'' "$r" >> "$TEMP/vis-' + $Name + '.log"; done'
}

function Get-LogPath([string]$Name) { Join-Path $script:Sbx.Tmp ("vis-$Name.log") }

function Read-VisLog([string]$Name) {
    $p = Get-LogPath $Name
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    @(Get-Content -LiteralPath $p -ErrorAction SilentlyContinue | Where-Object { $_ })
}

function Start-Reader($Hwnd, [string]$Name) {
    Remove-Item -LiteralPath (Get-LogPath $Name) -ErrorAction SilentlyContinue
    Send-Line $Hwnd (Get-ReaderLine $Name)
}

# Waits for the log of `$Name` to end in `$Code` (1 visible, 2 not visible).
# A console that drops 2033 turns the log checks into SKIP, not a failure.
function Assert-VisLog([string]$Name, [int]$Code, [string]$What, [double]$TimeoutSec = 4) {
    if (-not $script:LogsOk) { return }
    $want = '999;{0}n' -f $Code
    $ok = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
        $l = @(Read-VisLog $Name)
        $l.Count -gt 0 -and $l[$l.Count - 1] -like "*$want"
    }
    if (-not $ok) { throw "vis-$Name.log does not end in ';$($Code)n' ($What): $((Read-VisLog $Name) -join ' | ')" }
}

function Get-AppState($G) {
    $st = Get-GhosttyState -Class $G.Class
    if ($st.PSObject.Properties['data']) { $st.data } else { $st }
}

function Get-QuickWindowId($G) {
    $q = (Get-AppState $G).m3.quick
    if ($q) { $q.window }
}

# The surfaces (core_visible, visible) of the tab at `$Index` of the first
# normal window.
function Get-TabSurfaces($G, [int]$Index) {
    $qid = Get-QuickWindowId $G
    $win = @((Get-AppState $G).windows | Where-Object { $_.id -ne $qid })[0]
    @(@($win.tabs)[$Index].surfaces)
}

function Wait-CoreVisible($G, [int]$TabIndex, [bool]$Want, [string]$What, [double]$TimeoutSec = 1.5) {
    $ok = Wait-Until -TimeoutSec $TimeoutSec -PollMs 50 -Condition {
        $s = @(Get-TabSurfaces $G $TabIndex)
        $s.Count -gt 0 -and ([bool]$s[0].core_visible) -eq $Want
    }
    if (-not $ok) {
        throw "core_visible did not become $Want ($What): $((Get-TabSurfaces $G $TabIndex) | ConvertTo-Json -Compress -Depth 4)"
    }
}

function Invoke-QuickToggle($G) {
    $p = Start-Launch $G.Class @('+toggle-quick-terminal')
    if (-not $p.WaitForExit(5000)) { throw 'the +toggle-quick-terminal launch did not finish in 5 s' }
    if ($p.ExitCode -ne 0) { throw "+toggle-quick-terminal --class=$($G.Class) exited $($p.ExitCode)" }
}

function Wait-Quick($G, [string]$What, [scriptblock]$Predicate, [double]$TimeoutSec = 4) {
    $q = Wait-Until -TimeoutSec $TimeoutSec -PollMs 50 -Condition {
        $q = (Get-AppState $G).m3.quick
        if ($q -and (& $Predicate $q)) { $q }
    }
    if (-not $q) { throw "timeout waiting for: $What; quick: $(((Get-AppState $G).m3.quick) | ConvertTo-Json -Compress -Depth 6)" }
    $q
}

Invoke-E2eScenario 'visibility-hidden' {
    $g = Start-BashE2e -ExtraConfig "quick-terminal-animation-duration = 0.1`nquick-terminal-autohide = false"
    $hwnd = $g.Hwnd

    # 1. Start: visible.
    Start-Reader $hwnd 'main'
    Wait-CoreVisible $g 0 $true 'at start'
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { (Read-VisLog 'main').Count -gt 0 })) {
        $script:LogsOk = $false
        Write-E2eInfo 'SKIP: vis.log checks (the console dropped mode 2033; use windows-conpty = bundled)'
    } else {
        Assert-VisLog 'main' 1 'at start'
    }

    # 2. toggle_visibility hides the window: not visible within 1 s.
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_visibility')
    Wait-CoreVisible $g 0 $false 'after toggle_visibility' 1.5
    Assert-VisLog 'main' 2 'after toggle_visibility'

    # 3. ... and shows it again.
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_visibility')
    Wait-CoreVisible $g 0 $true 'after the second toggle_visibility' 2
    Assert-VisLog 'main' 1 'after the second toggle_visibility'
    Write-E2eInfo 'toggle_visibility: core_visible false and back'

    # 4. Quick terminal: shown, then hidden.
    Invoke-QuickToggle $g
    $q = Wait-Quick $g 'the quick terminal is shown and settled' { param($q) $q.shown -and $q.visible -and -not $q.animating }
    $qh = [IntPtr][Convert]::ToInt64(([string]$q.hwnd).Substring(2), 16)
    Start-Reader $qh 'quick'
    Invoke-QuickToggle $g
    [void](Wait-Quick $g 'the quick terminal is hidden' { param($q) -not $q.shown -and -not $q.visible -and -not $q.animating })
    $qid = Get-QuickWindowId $g
    $qwin = @((Get-AppState $g).windows | Where-Object { $_.id -eq $qid })[0]
    $qs = @(@($qwin.tabs)[0].surfaces)
    if ($qs.Count -lt 1 -or [bool]$qs[0].core_visible) {
        throw "the hidden quick terminal's surface is still core_visible: $($qs | ConvertTo-Json -Compress -Depth 4)"
    }
    Assert-VisLog 'quick' 2 'quick terminal hidden'
    Write-E2eInfo 'quick terminal: hidden surface is not core_visible'

    # 5. Tabs: a new tab hides the first one; going back shows it.
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
    Wait-CoreVisible $g 0 $false 'the first tab after new_tab'
    Assert-VisLog 'main' 2 'inactive tab after new_tab'
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'goto_tab:1')
    Wait-CoreVisible $g 0 $true 'the first tab after goto_tab:1'
    Wait-CoreVisible $g 1 $false 'the second tab after goto_tab:1'
    Assert-VisLog 'main' 1 'tab shown again'

    # 6. Minimize and restore.
    $win = @((Get-AppState $g).windows | Where-Object { $_.id -ne $qid })[0]
    $wh = [IntPtr][Convert]::ToInt64(([string]$win.hwnd).Substring(2), 16)
    try {
        [void][GhosttyE2e.Vis]::ShowWindowAsync($wh, $script:SW_MINIMIZE)
        Wait-CoreVisible $g 0 $false 'minimized' 2
        Assert-VisLog 'main' 2 'minimized'
    } finally {
        [void][GhosttyE2e.Vis]::ShowWindowAsync($wh, $script:SW_RESTORE)
    }
    Wait-CoreVisible $g 0 $true 'restored' 3
    Assert-VisLog 'main' 1 'restored'
    Write-E2eInfo 'minimize / restore: core_visible false and back'
}
