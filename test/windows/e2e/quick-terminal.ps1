# e2e: milestone=M3 timeout=180 order=590
# quick-terminal: `+toggle-quick-terminal` shows a topmost tool window at the top
# of the primary work area (no taskbar button) with its surface focused;
# toggling again hides it and the shell stays alive; quick-terminal-autohide
# hides it when another window of the desktop is activated;
# quick-terminal-position = bottom puts it at the bottom edge; the quick
# terminal counts for quit-after-last-window-closed only while shown.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms

Add-Type -Namespace GhosttyE2e -Name Quick -MemberDefinition @'
[DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
'@

$script:WM_CLOSE = 0x10
$script:GWL_EXSTYLE = -20
$script:WS_EX_TOOLWINDOW = 0x80

function ConvertTo-HwndText([IntPtr]$Hwnd) { '0x{0:x}' -f $Hwnd.ToInt64() }

# Ends an instance through the `quit` action; the harness kills what is left.
function Stop-Ghostty($G) {
    try { [void](Invoke-GhosttyAction -Class $G.Class -Action 'quit') } catch { }
    [void](Wait-ProcessExit $G 5)
}

function Get-Quick($G) { (Get-GhosttyState -Class $G.Class).m3.quick }

function Invoke-QuickToggle($G) {
    $p = Start-Launch $G.Class @('+toggle-quick-terminal')
    if (-not $p.WaitForExit(5000)) { throw 'the +toggle-quick-terminal launch did not finish in 5 s' }
}

function Wait-Quick($G, [string]$What, [scriptblock]$Predicate, [double]$TimeoutSec = 4) {
    $q = Wait-Until -TimeoutSec $TimeoutSec -PollMs 50 -Condition {
        $q = Get-Quick $G
        if ($q -and (& $Predicate $q)) { $q }
    }
    if (-not $q) { throw "timeout waiting for: $What; quick: $((Get-Quick $G) | ConvertTo-Json -Compress -Depth 6)" }
    $q
}

function Get-QuickHwnd($Q) { [IntPtr][Convert]::ToInt64(([string]$Q.hwnd).Substring(2), 16) }

Invoke-E2eScenario 'quick-terminal' {
    $base = Get-Content -LiteralPath (Get-ConfigPath 'gitbash-de') -Raw -Encoding UTF8
    $g = Start-E2eGhostty -ConfigText ($base + "`nquick-terminal-animation-duration = 0.1`nquick-terminal-autohide = false`n")
    Wait-BashReady $g

    $work = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea

    # 1. Show: at the top of the primary work area, on top, no taskbar button.
    Invoke-QuickToggle $g
    $q = Wait-Quick $g 'the quick terminal is shown and settled' { param($q) $q.shown -and $q.visible -and -not $q.animating }
    if ($q.rect.y -ne $work.Y -or $q.rect.w -ne $work.Width) { throw "not at the top of the work area $($work): $($q.rect | ConvertTo-Json -Compress)" }
    $qh = Get-QuickHwnd $q
    $ex = [int64][GhosttyE2e.Quick]::GetWindowLongPtr($qh, $script:GWL_EXSTYLE)
    if (($ex -band $script:WS_EX_TOOLWINDOW) -eq 0) { throw 'the quick window is not a tool window (it would have a taskbar button)' }
    if (-not (Wait-Until -TimeoutSec 3 -PollMs 50 -Condition { [GhosttyHarness.Native]::GetForegroundWindow() -eq $qh })) {
        throw "the quick window is not in the foreground: $(Get-WindowDescription ([GhosttyHarness.Native]::GetForegroundWindow()))"
    }

    # The surface is focused: typing reaches its shell.
    $file = Join-Path $env:TEMP 'gt-quick-1.txt'
    Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
    Send-Line $qh 'echo quick-ok > "$TEMP/gt-quick-1.txt"'
    Assert-ShellText $file "quick-ok`n" 'echo through the quick terminal'

    # 2. Hide: gone from the screen, shell still alive.
    $before = @(Get-ProcessTree $g.Pid).Count
    Invoke-QuickToggle $g
    [void](Wait-Quick $g 'the quick terminal is hidden' { param($q) -not $q.shown -and -not $q.visible -and -not $q.animating })
    Invoke-QuickToggle $g
    [void](Wait-Quick $g 'the quick terminal is shown again' { param($q) $q.shown -and $q.visible -and -not $q.animating })
    $after = @(Get-ProcessTree $g.Pid).Count
    if ($after -ne $before) { throw "the process tree changed across a toggle: $before -> $after" }
    $file2 = Join-Path $env:TEMP 'gt-quick-2.txt'
    Remove-Item -LiteralPath $file2 -ErrorAction SilentlyContinue
    Send-Line $qh 'echo quick-again > "$TEMP/gt-quick-2.txt"'
    Assert-ShellText $file2 "quick-again`n" 'echo after the second show'
    Invoke-QuickToggle $g
    [void](Wait-Quick $g 'hidden before the config changes' { param($q) -not $q.shown -and -not $q.visible })
    Stop-Ghostty $g

    # 3. Autohide: activating another window of the desktop hides it.
    $g = Start-E2eGhostty -ConfigText ($base + "`nquick-terminal-animation-duration = 0.05`nquick-terminal-autohide = true`n")
    Wait-BashReady $g
    Invoke-QuickToggle $g
    [void](Wait-Quick $g 'shown (autohide)' { param($q) $q.shown -and $q.visible -and -not $q.animating })
    $form = New-Object Windows.Forms.Form
    $form.Text = 'ghostty-e2e-foreign'
    try {
        $form.Show()
        [Windows.Forms.Application]::DoEvents()
        if (-not (Set-ForegroundSafe -Hwnd $form.Handle)) { throw 'E2E-SKIP: could not take the foreground' }
        [void](Wait-Quick $g 'hidden by autohide' { param($q) -not $q.shown -and -not $q.visible } 4)
    } finally {
        $form.Close()
        $form.Dispose()
    }
    Stop-Ghostty $g

    # 4. Position: bottom.
    $g = Start-E2eGhostty -ConfigText ($base + "`nquick-terminal-animation-duration = 0.05`nquick-terminal-autohide = false`nquick-terminal-position = bottom`n")
    Wait-BashReady $g
    Invoke-QuickToggle $g
    $q = Wait-Quick $g 'shown at the bottom' { param($q) $q.shown -and $q.visible -and -not $q.animating }
    if (($q.rect.y + $q.rect.h) -ne $work.Bottom) { throw "not at the bottom of the work area $($work): $($q.rect | ConvertTo-Json -Compress)" }
    Stop-Ghostty $g

    # 5. A shown quick terminal counts as a window: closing the last normal
    # window keeps the process; hiding the quick terminal then ends it.
    $g = Start-E2eGhostty -ConfigText ($base + "`nquick-terminal-animation-duration = 0.05`nquick-terminal-autohide = false`nquit-after-last-window-closed = true`n")
    Wait-BashReady $g
    Invoke-QuickToggle $g
    $q = Wait-Quick $g 'shown (quit)' { param($q) $q.shown -and $q.visible -and -not $q.animating }
    $normal = @((Get-GhosttyState -Class $g.Class).windows | Where-Object { $_.id -ne $q.window })
    if ($normal.Count -ne 1) { throw "expected one normal window, got $($normal.Count)" }
    [void][GhosttyE2e.Win]::PostMessageW([IntPtr][Convert]::ToInt64(([string]$normal[0].hwnd).Substring(2), 16), $script:WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    Start-Sleep -Seconds 2
    $g.Process.Refresh()
    if ($g.Process.HasExited) { throw 'the process ended although the quick terminal was shown' }
    Invoke-QuickToggle $g
    if (-not (Wait-ProcessExit $g 5).Exited) { throw 'hiding the quick terminal with no normal window left did not end the process' }
}
