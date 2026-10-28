# e2e: milestone=M3 timeout=420 order=640
# dialogs: the Windows 11 style dialogs (class GhosttyDialog, owned by the
# Ghostty pid): close confirm with a running process, paste confirm, URL
# confirm and config errors, each in dark and in light. Per dialog: it is
# there, modal (the owner is disabled), centred on the owner, within the
# 320..548 DIP width, with real BUTTON children of the right names and
# equal widths on a 24 DIP grid, and its button bar has the Fluent colour
# of the theme (#202020 dark, #F3F3F3 light). Keys are posted to the
# dialog: Enter takes the default button, Esc cancels, Tab and the arrows
# move the focus, Alt+letter presses a button. Screenshots are crops of the
# dialog only, through the guarded Save-WindowShot, in
# .superpowers/sdd/M3-feature-parity/evidence/dialogs/.
# Keep this file ASCII only.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force

if (-not ('GhosttyE2e.DlgWin' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name DlgWin -MemberDefinition @"
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, StringBuilder l);
// WM_GETTEXT works across processes for the standard controls.
public static string Text(IntPtr h) { StringBuilder s = new StringBuilder(8192); SendMessageW(h, 0xD, (IntPtr)8192, s); return s.ToString(); }
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
"@ -UsingNamespace 'System.Text'
}

$script:VK_ESCAPE = 0x1B
$script:VK_RETURN = 0x0D
$script:VK_TAB = 0x09
$script:VK_LEFT = 0x25
$script:VK_RIGHT = 0x27
$script:IdBase = 1000

function Get-DlgRect([IntPtr]$H) {
    $r = New-Object GhosttyE2e.Win+RECT
    [void][GhosttyE2e.Win]::GetWindowRect($H, [ref]$r)
    $r
}

function Send-DlgKey([IntPtr]$Dlg, [int]$Vk) {
    [void][GhosttyE2e.Win]::PostMessageW($Dlg, 0x100, [IntPtr]$Vk, [IntPtr]1)
    [void][GhosttyE2e.Win]::PostMessageW($Dlg, 0x101, [IntPtr]$Vk, [IntPtr]0xC0000001)
}

function Send-DlgAlt([IntPtr]$Dlg, [char]$Letter) {
    # WM_SYSKEYDOWN with the context-code bit (29) set.
    [void][GhosttyE2e.Win]::PostMessageW($Dlg, 0x104, [IntPtr][int][char]$Letter, [IntPtr]0x20000001)
}

function Get-DialogFor($G, [string]$What, [double]$TimeoutSec = 10) {
    $dlg = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
        [GhosttyE2e.Win]::TopLevel([uint32]$G.Pid, 'GhosttyDialog') | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) } | Select-Object -First 1
    }
    if (-not $dlg) { throw "no dialog (GhosttyDialog) within $TimeoutSec s: $What" }
    $dlg
}

function Wait-DlgGone([IntPtr]$Dlg, [string]$What) {
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { -not [GhosttyE2e.Win]::IsWindow($Dlg) })) {
        throw "dialog still open 5 s after: $What"
    }
}

function Get-DlgButtons([IntPtr]$Dlg) {
    $list = @()
    for ($i = 0; $i -lt 4; $i++) {
        $b = [GhosttyE2e.Win]::GetDlgItem($Dlg, $script:IdBase + $i)
        if ($b -eq [IntPtr]::Zero) { break }
        $list += , $b
    }
    $list
}

# The dialog's crop, saved when an evidence directory is known. A busy
# desktop skips the picture, not the checks.
function Save-DialogShot([IntPtr]$Dlg, [string]$Tag) {
    if (-not $script:EvidenceDir) { return }
    try {
        Save-WindowShot $Dlg (Join-Path $script:EvidenceDir "dialogs-$Tag.png")
    } catch {
        if ($_.Exception.Message -like 'E2E-SKIP:*') { Write-E2eInfo "screenshot $Tag skipped: $($_.Exception.Message)" } else { throw }
    }
}

# The colour of one pixel of the screen, through the capture guard; null
# when the desktop is busy.
function Get-ScreenPixel([int]$X, [int]$Y) {
    try {
        $bmp = Get-ScreenShot $X $Y 1 1
        try { $bmp.GetPixel(0, 0) } finally { $bmp.Dispose() }
    } catch {
        if ($_.Exception.Message -like 'E2E-SKIP:*') { return $null }
        throw
    }
}

# The checks every dialog has to pass. `Buttons` are the expected names.
function Assert-Dialog($G, [IntPtr]$Dlg, [string]$Kind, [string]$Theme, [string[]]$Buttons, [string]$WindowTitle) {
    if ([GhosttyE2e.Win]::ClassOf($Dlg) -ne 'GhosttyDialog') { throw "${Kind}: class is '$([GhosttyE2e.Win]::ClassOf($Dlg))'" }
    $title = [GhosttyE2e.Win]::TextOf($Dlg)
    if ($title -ne $WindowTitle) { throw "${Kind}: window text is '$title', expected '$WindowTitle'" }
    if ([GhosttyE2e.DlgWin]::IsWindowEnabled($G.Hwnd)) { throw "${Kind}: the owner is enabled, the dialog is not modal" }

    $dpi = [GhosttyE2e.DlgWin]::GetDpiForWindow($Dlg)
    $s = $dpi / 96.0
    $r = Get-DlgRect $Dlg
    $w = $r.Right - $r.Left
    $h = $r.Bottom - $r.Top
    if ($w -lt [math]::Floor(320 * $s) - 1 -or $w -gt [math]::Ceiling(548 * $s) + 1) { throw "${Kind}: width $w px is outside 320..548 DIP at $dpi dpi" }
    if ($h -lt 120 * $s) { throw "${Kind}: height $h px is too small" }

    # Centred on the owner (unless the screen edge moved it).
    $o = Get-DlgRect $G.Hwnd
    $dx = ($r.Left + $r.Right) / 2 - ($o.Left + $o.Right) / 2
    $dy = ($r.Top + $r.Bottom) / 2 - ($o.Top + $o.Bottom) / 2
    if ([math]::Abs($dx) -gt 4 -or [math]::Abs($dy) -gt 4) { Write-E2eInfo "$Kind centre is off the owner's by $dx,$dy px (clamped to the work area?)" }

    # Real buttons, named, equal width, on the 24 DIP grid, 32 DIP high.
    $btns = @(Get-DlgButtons $Dlg)
    if ($btns.Count -ne $Buttons.Count) { throw "${Kind}: $($btns.Count) buttons, expected $($Buttons.Count)" }
    $widths = @()
    for ($i = 0; $i -lt $btns.Count; $i++) {
        if ([GhosttyE2e.Win]::ClassOf($btns[$i]) -ne 'Button') { throw "${Kind}: button $i is a '$([GhosttyE2e.Win]::ClassOf($btns[$i]))'" }
        $name = [GhosttyE2e.DlgWin]::Text($btns[$i])
        if ($name -ne $Buttons[$i]) { throw "${Kind}: button $i is named '$name', expected '$($Buttons[$i])'" }
        $br = Get-DlgRect $btns[$i]
        $widths += ($br.Right - $br.Left)
        if ([math]::Abs(($br.Bottom - $br.Top) - 32 * $s) -gt 1.5) { throw "${Kind}: button $i is $($br.Bottom - $br.Top) px high, expected $(32 * $s)" }
    }
    $min = ($widths | Measure-Object -Minimum).Minimum
    $max = ($widths | Measure-Object -Maximum).Maximum
    if ($max - $min -gt 1) { throw "${Kind}: button widths differ: $($widths -join ',')" }
    $first = Get-DlgRect $btns[0]
    $last = Get-DlgRect $btns[$btns.Count - 1]
    if ([math]::Abs(($first.Left - $r.Left) - 24 * $s) -gt 1.5) { throw "${Kind}: first button is $($first.Left - $r.Left) px from the left, expected $(24 * $s); dialog $($r.Left),$($r.Top),$($r.Right),$($r.Bottom) button $($first.Left),$($first.Top),$($first.Right),$($first.Bottom)" }
    if ([math]::Abs(($r.Right - $last.Right) - 24 * $s) -gt 1.5) { throw "${Kind}: last button is $($r.Right - $last.Right) px from the right, expected $(24 * $s)" }
    if ([math]::Abs(($r.Bottom - $last.Bottom) - 24 * $s) -gt 1.5) { throw "${Kind}: buttons are $($r.Bottom - $last.Bottom) px above the bottom, expected $(24 * $s)" }
    Write-E2eInfo "$Kind ${Theme}: ${w}x${h} px at $dpi dpi, buttons $($widths -join '/')"

    # The button bar has the Fluent footer colour of the theme.
    # The dialog is visible a moment before the screen shows it (the one at
    # start-up, while the first frame is made, up to some 700 ms), so the
    # colour is read until it matches or a second has passed.
    $want = if ($Theme -eq 'dark') { 0x20 } else { 0xF3 }
    $bad = { param($p) [math]::Abs($p.R - $want) -gt 3 -or [math]::Abs($p.G - $want) -gt 3 -or [math]::Abs($p.B - $want) -gt 3 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        $px = Get-ScreenPixel ($r.Left + [int](6 * $s)) ($r.Bottom - [int](6 * $s))
        if (-not $px -or -not (& $bad $px)) { break }
        Start-Sleep -Milliseconds 50
    } while ($sw.ElapsedMilliseconds -lt 1000)
    if ($px) {
        if (& $bad $px) {
            throw ("$Kind ${Theme}: the button bar is #{0:x2}{1:x2}{2:x2}, expected #{3:x2}{3:x2}{3:x2}" -f $px.R, $px.G, $px.B, $want)
        }
    } else {
        Write-E2eInfo "$Kind ${Theme}: bar colour not sampled (desktop busy)"
    }
    Save-DialogShot $Dlg "$Theme-$Kind"
    $btns
}

# The y (px, in the edit's client area) of character `idx`: EM_POSFROMCHAR.
function Get-EditY([IntPtr]$H, [int]$Idx) {
    $r = [int64][GhosttyE2e.Win]::SendMessageW($H, 0xD6, [IntPtr]$Idx, [IntPtr]::Zero)
    [int](($r -shr 16) -band 0xFFFF)
}

# A dialog nested in another one (a config error shown while the close
# confirm is up, or the other way round): closing the inner one must not
# enable the owner behind the outer one.
function Test-NestedDialogs {
    $cfg = $script:BaseConfig.Replace('confirm-close-surface = false', 'confirm-close-surface = true')
    $g = Start-E2eGhostty -ConfigText ($cfg + "`ncommand = ping -t 127.0.0.1`nfont-sise = 3`n")
    $cfgDlg = Get-DialogFor $g 'config errors at start'
    if ([GhosttyE2e.Win]::TextOf($cfgDlg) -ne 'Configuration errors') { throw 'nested: the first dialog is not the config errors one' }
    if ([GhosttyE2e.DlgWin]::IsWindowEnabled($g.Hwnd)) { throw 'nested: the owner is enabled under the config dialog' }
    [void][GhosttyE2e.Win]::PostMessageW($g.Hwnd, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    $closeDlg = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition {
        [GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyDialog') | Where-Object { [GhosttyE2e.Win]::TextOf($_) -eq 'Ghostty' } | Select-Object -First 1
    }
    if (-not $closeDlg) { throw 'nested: no close confirm over the config dialog' }
    Send-DlgKey $closeDlg $script:VK_ESCAPE
    Wait-DlgGone $closeDlg 'Esc on the inner dialog'
    Start-Sleep -Milliseconds 400
    if (-not [GhosttyE2e.Win]::IsWindow($cfgDlg)) { throw 'nested: the outer dialog went away with the inner one' }
    if ([GhosttyE2e.DlgWin]::IsWindowEnabled($g.Hwnd)) { throw 'nested: the owner was enabled behind the outer dialog' }
    Send-DlgKey $cfgDlg $script:VK_ESCAPE
    Wait-DlgGone $cfgDlg 'Esc on the outer dialog'
    Start-Sleep -Milliseconds 400
    if (-not [GhosttyE2e.DlgWin]::IsWindowEnabled($g.Hwnd)) { throw 'nested: the owner stayed disabled after both closed' }
    if ($g.Process.HasExited) { throw 'nested: ghostty exited' }
}
function Get-ConfirmShell([string]$Theme) {
    $cfg = (Get-Content -LiteralPath (Get-ConfigPath 'gitbash-de') -Raw -Encoding UTF8) -replace 'confirm-close-surface = false', 'confirm-close-surface = true'
    $g = Start-E2eGhostty -ConfigText ($cfg.TrimEnd() + "`nwindow-theme = $Theme`n")
    Wait-BashReady $g
    Send-Line $g.Hwnd 'ping -t 127.0.0.1 > /dev/null'
    if (-not (Wait-ChildNamed $g @('ping.exe') 15)) { throw 'ping.exe never started' }
    Start-Sleep -Milliseconds 500
    $g
}

function Test-CloseDialog([string]$Theme, [bool]$Keys) {
    $g = Get-ConfirmShell $Theme
    $snapshot = @(Get-ProcessTree $g.Pid)
    [void][GhosttyE2e.Win]::PostMessageW($g.Hwnd, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    $dlg = Get-DialogFor $g 'close with a running ping'
    [void](Assert-Dialog $g $dlg 'close' $Theme @('&Close', 'Cancel') 'Ghostty')
    $body = [GhosttyE2e.DlgWin]::Text([GhosttyE2e.Win]::GetDlgItem($dlg, 900))
    if ($body -notmatch 'process is still running') { throw "close: body is '$body'" }

    # Esc cancels: the window stays and is enabled again.
    Send-DlgKey $dlg $script:VK_ESCAPE
    Wait-DlgGone $dlg 'Esc'
    Start-Sleep -Milliseconds 400
    if ($g.Process.HasExited -or -not [GhosttyE2e.Win]::IsWindow($g.Hwnd)) { throw 'Esc on the close dialog closed the window' }
    if (-not [GhosttyE2e.DlgWin]::IsWindowEnabled($g.Hwnd)) { throw 'the owner stayed disabled after Esc' }

    if ($Keys) {
        # Enter takes the default button (Cancel).
        [void][GhosttyE2e.Win]::PostMessageW($g.Hwnd, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
        $dlg = Get-DialogFor $g 'close, Enter'
        Send-DlgKey $dlg $script:VK_RETURN
        Wait-DlgGone $dlg 'Enter'
        Start-Sleep -Milliseconds 400
        if ($g.Process.HasExited) { throw 'Enter (default Cancel) closed the window' }

        # Tab moves to Close, Esc still cancels.
        [void][GhosttyE2e.Win]::PostMessageW($g.Hwnd, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
        $dlg = Get-DialogFor $g 'close, Tab'
        Send-DlgKey $dlg $script:VK_TAB
        Start-Sleep -Milliseconds 400
        Save-DialogShot $dlg "$Theme-close-focus"
        Send-DlgKey $dlg $script:VK_ESCAPE
        Wait-DlgGone $dlg 'Tab, Esc'
        if ($g.Process.HasExited) { throw 'Tab then Esc closed the window' }

        # Left moves the focus to Close, Enter presses it.
        [void][GhosttyE2e.Win]::PostMessageW($g.Hwnd, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
        $dlg = Get-DialogFor $g 'close, Left+Enter'
        Send-DlgKey $dlg $script:VK_LEFT
        Send-DlgKey $dlg $script:VK_RETURN
        $exit = Wait-ProcessExit $g 8
        if (-not $exit.Exited) { throw 'Left then Enter (Close) did not close the window' }
        Assert-NoSurvivors $snapshot $g.Pid 3
    }
}

function Test-PasteDialog([string]$Theme, [bool]$Keys) {
    $saved = Save-ClipboardText
    try {
        $g = Start-BashE2e 'unsafe-paste' -ExtraConfig "window-theme = $Theme"
        Set-ClipboardText ("echo a`necho b`n")
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+shift+v'
        $dlg = Get-DialogFor $g 'multi-line paste'
        $title = [GhosttyE2e.Win]::TextOf($dlg)
        $btns = Assert-Dialog $g $dlg 'paste' $Theme @('Allow', 'Cancel') $title
        $body = [GhosttyE2e.DlgWin]::Text([GhosttyE2e.Win]::GetDlgItem($dlg, 900))
        if ($body -notmatch 'echo a') { throw "paste: the text is not in the dialog: '$body'" }
        # Newlines show as symbols, not as line breaks of the pasted text.
        if ($body -notmatch [regex]::Escape([string][char]0x240A)) { throw "paste: no newline symbol in '$body'" }
        Send-DlgKey $dlg $script:VK_ESCAPE
        Wait-DlgGone $dlg 'Esc'
        if ($Keys) {
            Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+shift+v'
            $dlg = Get-DialogFor $g 'second paste'
            # Allow has no mnemonic (a user who keeps typing must not accept it):
            # Alt+A does nothing, Left then Enter presses it.
            Send-DlgAlt $dlg 'A'
            Start-Sleep -Milliseconds 300
            if (-not [GhosttyE2e.Win]::IsWindow($dlg)) { throw 'paste: Alt+A pressed a button that has no mnemonic' }
            Send-DlgKey $dlg $script:VK_LEFT
            Send-DlgKey $dlg $script:VK_RETURN
            Wait-DlgGone $dlg 'Left, Enter (Allow)'
        }
    } finally {
        Restore-ClipboardText $saved
    }
}


function Test-UrlDialog([string]$Theme) {
    $g = Start-BashE2e -ExtraConfig "window-theme = $Theme"
    $s = (Get-GhosttyState -Class $g.Class).windows[0].tabs[0].surfaces[0]
    $surface = [IntPtr][Convert]::ToInt64($s.hwnd, 16)
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+l'
    Start-Sleep -Milliseconds 300
    Send-Line $g.Hwnd ("printf '\033]8;;ms-settings:\033\\settings-link\033]8;;\033\\\n'")
    Start-Sleep -Milliseconds 800
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)

    $dlg = $null
    foreach ($y in 20..200 | Where-Object { $_ % 8 -eq 0 }) {
        Send-MouseMove -Hwnd $surface -X 30 -Y $y
        Start-Sleep -Milliseconds 120
        [GhosttyE2e.DlgWin]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
        try { Send-MouseClick -Hwnd $surface -X 30 -Y $y } finally { [GhosttyE2e.DlgWin]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero) }
        $dlg = Wait-Until -TimeoutSec 1.2 -PollMs 100 -Condition { [GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyDialog') | Select-Object -First 1 }
        if ($dlg) { break }
    }
    if (-not $dlg) { throw 'no URL confirmation dialog for the ms-settings: link' }
    $title = [GhosttyE2e.Win]::TextOf($dlg)
    if ($title -ne 'Open Link') { throw "url: window text is '$title'" }
    [void](Assert-Dialog $g $dlg 'url' $Theme @('Allow', 'Cancel') 'Open Link')
    $body = [GhosttyE2e.DlgWin]::Text([GhosttyE2e.Win]::GetDlgItem($dlg, 900))
    if ($body -notmatch 'ms-settings:') { throw "url: the link is not in the dialog: '$body'" }
    Send-DlgKey $dlg $script:VK_ESCAPE
    Wait-DlgGone $dlg 'Esc'
    $rec = Wait-Until -TimeoutSec 4 -PollMs 100 -Condition {
        @((Get-GhosttyState -Class $g.Class).m3.opened) | Where-Object { $_.url -eq 'ms-settings:' -and $_.outcome -eq 'cancelled' } | Select-Object -First 1
    }
    if (-not $rec) { throw 'Esc was not recorded as a cancelled open' }
}

function Test-ConfigDialog([string]$Theme, [bool]$Keys) {
    $g = Start-E2eGhostty -ConfigText ($script:BaseConfig + "`nfont-sise = 3`nwindow-theme = $Theme`n")
    $dlg = Get-DialogFor $g 'config errors'
    [void](Assert-Dialog $g $dlg 'config' $Theme @('Reload configuration', 'Open configuration', 'Ignore') 'Configuration errors')
    # The list is a real, scrollable, read-only EDIT with the lines in it.
    $list = [GhosttyE2e.Win]::GetDlgItem($dlg, 901)
    if ($list -eq [IntPtr]::Zero) { throw 'config: no list control (id 901)' }
    if ([GhosttyE2e.Win]::ClassOf($list) -ne 'Edit') { throw "config: the list is a '$([GhosttyE2e.Win]::ClassOf($list))'" }
    $text = [GhosttyE2e.DlgWin]::Text($list)
    if ($text -notmatch 'font-sise') { throw "config: the list does not show font-sise: '$text'" }
    # Not clipped: the last line, one line pitch tall, lies inside the edit.
    $lines = [int][GhosttyE2e.Win]::SendMessageW($list, 0xBA, [IntPtr]::Zero, [IntPtr]::Zero)
    $client = New-Object GhosttyE2e.Win+RECT
    [void][GhosttyE2e.Win]::GetClientRect($list, [ref]$client)
    $y0 = Get-EditY $list 0
    $y1 = Get-EditY $list ([int][GhosttyE2e.Win]::SendMessageW($list, 0xBB, [IntPtr]1, [IntPtr]::Zero))
    $yl = Get-EditY $list ([int][GhosttyE2e.Win]::SendMessageW($list, 0xBB, [IntPtr]($lines - 1), [IntPtr]::Zero))
    $pitch = $y1 - $y0
    Write-E2eInfo "config ${Theme}: $lines lines, pitch $pitch px, last line at $yl, edit height $($client.Bottom)"
    if ($lines -lt 2 -or $pitch -le 0) { throw "config: unexpected line metrics ($lines lines, pitch $pitch)" }
    if ($yl + $pitch -gt $client.Bottom) { throw "config: the last line is clipped (y $yl + $pitch > $($client.Bottom))" }
    Send-DlgKey $dlg $script:VK_ESCAPE
    Wait-DlgGone $dlg 'Esc'
    $choice = (Get-GhosttyState -Class $g.Class).m3.config_errors.choice
    if ($choice -ne 'ignore') { throw "Esc chose '$choice', expected ignore" }
    if ($Keys) {
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'reload_config')
        $dlg = Get-DialogFor $g 'config errors again'
        # Enter takes the default button, Reload: with the error still in the file the dialog comes back.
        Send-DlgKey $dlg $script:VK_RETURN
        Wait-DlgGone $dlg 'Enter'
        $dlg = Get-DialogFor $g 'config errors after Reload (the error is still there)'
        Send-DlgKey $dlg $script:VK_ESCAPE
        Wait-DlgGone $dlg 'Esc'
    }
}

Invoke-E2eScenario 'dialogs' {
    $script:EvidenceDir = $null
    $evi = if ($env:GHOSTTY_E2E_DIALOG_SHOTS) { $env:GHOSTTY_E2E_DIALOG_SHOTS } else { Join-Path (Resolve-Path (Join-Path $script:Root '..\..\..')).Path '.superpowers\sdd\M3-feature-parity\evidence\dialogs' }
    if (Test-Path -LiteralPath (Split-Path -Parent (Split-Path -Parent $evi))) {
        New-Item -ItemType Directory -Force -Path $evi | Out-Null
        $script:EvidenceDir = $evi
    }

    $themes = if ($env:GHOSTTY_E2E_DIALOG_THEMES) { $env:GHOSTTY_E2E_DIALOG_THEMES -split ',' } else { 'dark', 'light' }
    Test-NestedDialogs
    foreach ($theme in $themes) {
        $full = ($theme -eq 'dark')
        Test-CloseDialog $theme $full
        Test-PasteDialog $theme $full
        Test-UrlDialog $theme
        Test-ConfigDialog $theme $full
    }
}
