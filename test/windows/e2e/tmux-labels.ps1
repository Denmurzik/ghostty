# e2e: milestone=M4 timeout=240 order=740
# tmux-labels: pane border labels. With Claude's options (`pane-border-status
# top` on the window, `pane-border-format "#[fg=<colour>,bold] #{pane_title}
# #[default]"` on each pane) every pane shows a coloured pill with its title
# inside its own rectangle; `pane-border-status off` removes them, `select-pane
# -T` updates the text, and a tab torn off into a new window takes them along.
# Needs the tmux commands of Task 12 (set-option, split-window, select-pane).
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_tmux.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

Add-Type -AssemblyName System.Windows.Forms
if (-not ('GhosttyE2e.LabelRects' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name LabelRects -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
public static int[] Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return new int[] { r.L, r.T, r.R, r.B }; }
"@
}

Invoke-E2eScenario 'tmux-labels' {
    $g = Start-BashE2e
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)

    function Get-State { Get-GhosttyState -Class $g.Class }
    function Get-Labels { @((Get-State).tmux.labels) }
    function Get-VisibleLabels { @(Get-Labels | Where-Object { $_.visible }) }
    function Get-Hwnd($W) { [IntPtr][Convert]::ToInt64(([string]$W.hwnd), 16) }
    function Test-Inside($Inner, $Outer) {
        $Inner[0] -ge $Outer[0] -and $Inner[1] -ge $Outer[1] -and $Inner[2] -le $Outer[2] -and $Inner[3] -le $Outer[3]
    }
    function Assert-LabelsInPanes([string[]]$Texts) {
        $vis = @(Get-VisibleLabels)
        if ($vis.Count -ne $Texts.Count) { throw "expected $($Texts.Count) visible labels, state has $($vis.Count): $((Get-Labels | ConvertTo-Json -Compress -Depth 5))" }
        foreach ($t in $Texts) {
            $l = @($vis | Where-Object { $_.text -ceq $t })[0]
            if (-not $l) { throw "no visible label with text '$t'" }
            if (-not (Test-Inside @($l.rect) @($l.pane_rect))) { throw "label '$t' rect $(@($l.rect) -join ',') is not inside its pane $(@($l.pane_rect) -join ',')" }
        }
    }

    # --- two panes with Claude's options ---
    $first = @(Get-TmuxPanes $g)[0]
    $win = "@$($first.tab)"
    $r = Invoke-Tmux $g @('set-option', '-w', '-t', $win, 'pane-border-status', 'top')
    if ($r.Code -ne 0) { throw "set-option -w: exit $($r.Code) $($r.Stderr)" }
    $r = Invoke-Tmux $g @('split-window', '-h', '-t', $first.pane, '-P', '-F', '#{pane_id}', '--', 'cat')
    if ($r.Code -ne 0) { throw "split-window: exit $($r.Code) $($r.Stderr)" }
    $second = $r.Stdout.Trim()
    if ($second -notmatch '^%\d+$') { throw "split-window printed '$second'" }

    $format = '#[fg=FG,bold] #{pane_title} #[default]'
    foreach ($p in @(@($first.pane, 'red', 'alpha'), @($second, 'colour208', 'beta'))) {
        $r = Invoke-Tmux $g @('set-option', '-p', '-t', $p[0], 'pane-border-format', $format.Replace('FG', $p[1]))
        if ($r.Code -ne 0) { throw "set-option -p format: exit $($r.Code) $($r.Stderr)" }
        $r = Invoke-Tmux $g @('select-pane', '-t', $p[0], '-T', $p[2])
        if ($r.Code -ne 0) { throw "select-pane -T: exit $($r.Code) $($r.Stderr)" }
    }
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 150 -Condition { @(Get-VisibleLabels).Count -eq 2 })) {
        throw "labels did not appear: $((Get-Labels | ConvertTo-Json -Compress -Depth 5))"
    }
    Assert-LabelsInPanes @('alpha', 'beta')
    $inks = @(Get-VisibleLabels | Sort-Object text | ForEach-Object { $_.ink })
    if ($inks[0] -eq $null -or $inks[1] -eq $null -or $inks[0] -eq $inks[1]) { throw "label colours are not distinct: $($inks -join ' ')" }
    Save-Evidence -Tag 'tmux-labels' -G $g -Window

    # --- status off: no labels ---
    $r = Invoke-Tmux $g @('set-option', '-w', '-t', $win, 'pane-border-status', 'off')
    if ($r.Code -ne 0) { throw "status off: exit $($r.Code) $($r.Stderr)" }
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 150 -Condition { @(Get-VisibleLabels).Count -eq 0 })) { throw 'labels are still visible with pane-border-status off' }
    $r = Invoke-Tmux $g @('set-option', '-w', '-t', $win, 'pane-border-status', 'top')
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 150 -Condition { @(Get-VisibleLabels).Count -eq 2 })) { throw 'labels did not come back with pane-border-status top' }

    # --- select-pane -T updates the text ---
    $r = Invoke-Tmux $g @('select-pane', '-t', $second, '-T', 'beta2')
    if ($r.Code -ne 0) { throw "select-pane -T beta2: exit $($r.Code) $($r.Stderr)" }
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 150 -Condition { @(Get-VisibleLabels | Where-Object { $_.text -ceq 'beta2' }).Count -eq 1 })) {
        throw "the label text did not change to beta2: $((Get-Labels | ConvertTo-Json -Compress -Depth 5))"
    }
    Assert-LabelsInPanes @('alpha', 'beta2')

    # --- tear the labelled tab off into a new window ---
    function Get-Wins { @((Get-State).windows) }
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 150 -Condition { @((Get-Wins)[0].tabs).Count -eq 2 })) { throw 'the second tab did not open' }
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
    $wins = @(Get-Wins)
    $aId = $wins[0].id
    Start-Sleep -Milliseconds 300
    $rc = [GhosttyE2e.LabelRects]::Rect($g.Hwnd)
    $tab = @($wins[0].strip.tabs)[0]
    $cx = [int](($tab[0] + $tab[2]) / 2); $cy = [int](($tab[1] + $tab[3]) / 2)
    Send-MouseMove -Hwnd $g.Hwnd -X $cx -Y $cy
    Start-Sleep -Milliseconds 60
    Send-MouseDown
    try {
        Start-Sleep -Milliseconds 60
        $sp = Convert-ClientToScreen $g.Hwnd $cx $cy
        Send-MouseMove -ScreenX $sp.X -ScreenY ($rc[3] + 250) -Steps 25
        Start-Sleep -Milliseconds 300
    } finally {
        Send-MouseUp
    }
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { @(Get-Wins).Count -eq 2 })) { throw 'the tear-off did not open a second window' }
    $new = @(Get-Wins | Where-Object { $_.id -ne $aId })[0]
    $newRect = [GhosttyE2e.LabelRects]::Rect((Get-Hwnd $new))
    $ok = Wait-Until -TimeoutSec 6 -PollMs 150 -Condition {
        $vis = @(Get-VisibleLabels)
        $vis.Count -eq 2 -and @($vis | Where-Object { -not (Test-Inside @($_.pane_rect) $newRect) -or -not (Test-Inside @($_.rect) @($_.pane_rect)) }).Count -eq 0
    }
    if (-not $ok) { throw "the labels did not follow the tab into the new window $($newRect -join ','): $((Get-Labels | ConvertTo-Json -Compress -Depth 5))" }
    Save-Evidence -Tag 'tmux-labels-torn-off' -G $g -Window -Hwnd (Get-Hwnd $new)
    Write-E2eInfo 'labels ok: shown, status off, retitled, torn off'

    $errors = @(Get-LogErrors $g)
    if ($errors.Count) { throw "ghostty.log has $($errors.Count) error line(s), first: $($errors[0])" }
}
