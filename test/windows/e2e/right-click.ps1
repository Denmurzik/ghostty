# e2e: milestone=M5 timeout=420 order=116
# right-click: what a right click does in Git Bash for each right-click-action.
#  - copy-or-paste (the Windows default): no selection pastes the clipboard
#    (unsafe multi-line text still asks first); a selection is copied and
#    cleared, nothing is pasted.
#  - paste: pastes even over a selection (and clears it). copy: copies only.
#  - context-menu: a native popup (#32768) with Copy (selection only), Paste...
#  - an app with mouse reporting (printf '\e[?1000h') gets the click instead.
# The clipboard is saved first and put back in `finally`.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'right-click' {
    $saved = Save-ClipboardText
    try {

        function Start-Case([string]$Extra) {
            $g = Start-BashE2e 'gitbash-de' -ExtraConfig $Extra
            $global:E2eLast = $g
            [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
            $g
        }
        function Stop-Case($g) {
            [void](Invoke-GhosttyAction -Class $g.Class -Action 'close_window')
            if (-not (Wait-ProcessExit $g 8).Exited) { throw 'ghostty did not exit after close_window' }
        }
        function Get-ClickPoint($g) {
            $s = Get-ClientSize $g.Hwnd
            , @([int]($s.Width / 2), [int]($s.Height * 0.7))
        }
        function Click-Right($g) {
            $p = Get-ClickPoint $g
            Send-MouseClick -Hwnd $g.Hwnd -X $p[0] -Y $p[1] -Button right
        }
        # The clipboard is text that, pasted at the prompt and run with Enter,
        # writes $Name.txt. No newline, so it is safe to paste.
        function Set-Payload([string]$Name) {
            Set-ClipboardText ('echo ok-{0} > "$TEMP/gt-rc-{0}.txt"' -f $Name)
        }
        function Get-Marker($g, [string]$Name) { Join-Path $g.Sandbox.Tmp "gt-rc-$Name.txt" }
        function Assert-Pasted($g, [string]$Name) {
            Start-Sleep -Milliseconds 500
            Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
            if (-not (Wait-File (Get-Marker $g $Name) 10)) { Save-Evidence "no-paste-$Name" $g -Window; throw "'$Name': the clipboard text was not pasted" }
        }
        function Assert-NotPasted($g, [string]$Name) {
            Start-Sleep -Milliseconds 700
            Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
            Start-Sleep -Milliseconds 1500
            if (Test-Path (Get-Marker $g $Name)) { throw "'$Name': the clipboard text was pasted" }
        }
        # Select what is on the screen and make the clipboard hold a sentinel.
        function Select-Screen($g, [string]$Word) {
            Send-Line $g.Hwnd "echo $Word"
            Start-Sleep -Milliseconds 800
            if (-not (Invoke-GhosttyAction -Class $g.Class -Action 'select_all')) { throw 'select_all was not performed' }
            Start-Sleep -Milliseconds 300
        }
        # Whether the surface has a selection: copy_to_clipboard performs only with one.
        function Test-Selection($g) { Invoke-GhosttyAction -Class $g.Class -Action 'copy_to_clipboard' }
        function Get-Popups($g) {
            @([GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, '#32768') | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) })
        }
        function Wait-Popup($g, [bool]$Present, [string]$What) {
            $ok = Wait-Until -TimeoutSec 5 -PollMs 50 -Condition { (@(Get-Popups $g).Count -gt 0) -eq $Present }
            if (-not $ok) { throw "$What : the menu is $(if ($Present) { 'missing' } else { 'still there' })" }
        }

        # 1. copy-or-paste (the default: no right-click-action in the config).
        $g = Start-Case ''
        Set-Payload 'cop-paste'
        Click-Right $g
        Assert-Pasted $g 'cop-paste'

        # 1b. Unsafe text asks first; cancelling drops it.
        Set-ClipboardText ("echo a1`necho b1 > `"`$TEMP/gt-rc-unsafe.txt`"`n")
        Click-Right $g
        $dlg = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { [GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyDialog') | Select-Object -First 1 }
        if (-not $dlg) { Save-Evidence 'no-dialog' $g -Window; throw 'a right click pasting multi-line text did not ask for confirmation' }
        Save-Evidence 'unsafe-dialog' $g -Window -Hwnd $dlg
        [void][GhosttyE2e.Win]::PostMessageW($dlg, 0x466, [IntPtr]2, [IntPtr]::Zero)
        if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { -not [GhosttyE2e.Win]::IsWindow($dlg) })) { throw 'dialog still open after Cancel' }
        Assert-NotPasted $g 'unsafe'

        # 1c. With a selection: copied, cleared, not pasted.
        Select-Screen $g 'SELECTME-cop'
        Set-ClipboardText 'echo SENTINEL > "$TEMP/gt-rc-cop-sel.txt"'
        Click-Right $g
        Start-Sleep -Milliseconds 600
        $clip = Invoke-ClipboardRetry { [System.Windows.Forms.Clipboard]::GetText() }
        if ($clip -notmatch 'SELECTME-cop') { throw "the right click did not copy the selection; clipboard: '$clip'" }
        if (Test-Selection $g) { throw 'the selection is still there after the right click' }
        Assert-NotPasted $g 'cop-sel'
        Stop-Case $g

        # 2. paste: pastes over a selection and clears it.
        $g = Start-Case "right-click-action = paste`n"
        Select-Screen $g 'SELECTME-paste'
        Set-Payload 'paste-mode'
        Click-Right $g
        Assert-Pasted $g 'paste-mode'
        if (Test-Selection $g) { throw 'paste: the selection is still there' }
        Stop-Case $g

        # 3. copy: copies and clears, never pastes.
        $g = Start-Case "right-click-action = copy`n"
        Set-Payload 'copy-mode'
        Click-Right $g
        Assert-NotPasted $g 'copy-mode'
        Select-Screen $g 'SELECTME-copy'
        Set-ClipboardText 'sentinel-before'
        Click-Right $g
        Start-Sleep -Milliseconds 600
        $clip = Invoke-ClipboardRetry { [System.Windows.Forms.Clipboard]::GetText() }
        if ($clip -notmatch 'SELECTME-copy') { throw "copy: the selection was not copied; clipboard: '$clip'" }
        if (Test-Selection $g) { throw 'copy: the selection is still there' }
        Stop-Case $g

        # 4. context-menu: a native popup.
        $g = Start-Case "right-click-action = context-menu`n"
        Set-Payload 'menu-paste'
        Click-Right $g
        Wait-Popup $g $true 'right click in context-menu mode'
        Save-Evidence 'menu-no-selection' $g -Window
        # No selection: the first item is Paste.
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'down', 'enter' -Panel
        Wait-Popup $g $false 'Enter on Paste'
        Assert-Pasted $g 'menu-paste'
        # Escape closes the menu and does nothing.
        Set-Payload 'menu-esc'
        Click-Right $g
        Wait-Popup $g $true 'second right click'
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'esc' -Panel
        Wait-Popup $g $false 'Escape on the menu'
        Assert-NotPasted $g 'menu-esc'
        # With a selection under the pointer the first item is Copy.
        Select-Screen $g 'SELECTME-menu'
        Set-ClipboardText 'sentinel-menu'
        Click-Right $g
        Wait-Popup $g $true 'right click on a selection'
        Save-Evidence 'menu-selection' $g -Window
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'down', 'enter' -Panel
        Wait-Popup $g $false 'Enter on Copy'
        Start-Sleep -Milliseconds 500
        $clip = Invoke-ClipboardRetry { [System.Windows.Forms.Clipboard]::GetText() }
        if ($clip -notmatch 'SELECTME-menu') { throw "menu Copy did not copy; clipboard: '$clip'" }
        Stop-Case $g

        # 5. An app with mouse reporting gets the click, in every mode.
        foreach ($mode in 'copy-or-paste', 'context-menu') {
            $g = Start-Case "right-click-action = $mode`n"
            $probe = Join-Path $g.Sandbox.Tmp 'gt-rc-mouse.txt'
            Set-Payload "mouse-$mode"
            Send-Line $g.Hwnd "printf '\033[?1000h\033[?1006h'; stty raw -echo; head -c 5 > `"`$TEMP/gt-rc-mouse.txt`"; stty sane; printf '\033[?1000l'"
            Start-Sleep -Milliseconds 1200
            Click-Right $g
            if (-not (Wait-File $probe 10)) { Save-Evidence "mouse-$mode" $g -Window; throw "$mode : the mouse app received nothing" }
            Start-Sleep -Milliseconds 300
            if (@(Get-Popups $g).Count -gt 0) { throw "$mode : a menu opened over a mouse-reporting app" }
            $r = Read-ShellFile $probe
            if ($r.Utf8 -ne "$([char]27)[<2;") { throw "$mode : the app got '$($r.Hex)', expected the SGR right press ESC [ < 2 ;" }
            Stop-Case $g
        }
    } finally {
        Restore-ClipboardText $saved
    }
}
