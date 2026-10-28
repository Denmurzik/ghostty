# e2e: milestone=M1 timeout=180 order=110
# paste-confirm: pasting a multi-line clipboard asks for confirmation (a
# GhosttyDialog dialog). The default button is Cancel: Enter cancels and nothing
# runs; answering Allow (custom button id 100) pastes both lines and (after Enter, as Git Bash holds a
# bracketed paste in its line buffer) the shell runs them. The dialog is
# answered with window messages, not key presses: the harness takes the
# foreground with an Alt tap, which puts a message box into menu mode, and
# the button labels are localised.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'paste-confirm' {
    $saved = Save-ClipboardText
    try {
        $g = Start-BashE2e 'unsafe-paste'
        $tmp = $g.Sandbox.Tmp
        $fa = Join-Path $tmp 'gt-pa.txt'
        $fb = Join-Path $tmp 'gt-pb.txt'

        Set-ClipboardText ("echo a > `"`$TEMP/gt-pa.txt`"`necho b > `"`$TEMP/gt-pb.txt`"`n")

        function Get-PasteDialog {
            Wait-Until -TimeoutSec 8 -PollMs 100 -Condition {
                [GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyDialog') | Select-Object -First 1
            }
        }

        # 1. Enter takes the default button (No): the paste is dropped.
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+shift+v'
        $dlg = Get-PasteDialog
        if (-not $dlg) { throw 'no confirmation dialog (GhosttyDialog) within 8 s of Ctrl+Shift+V' }
        $title = [GhosttyE2e.Win]::TextOf($dlg)
        Write-E2eInfo "dialog '$title'"
        Save-Evidence 'dialog' $g -Window -Hwnd $dlg
        [GhosttyE2e.Win]::PostEnter($dlg)
        $closed = Wait-Until -TimeoutSec 3 -PollMs 100 -Condition { -not [GhosttyE2e.Win]::IsWindow($dlg) }
        if (-not $closed) {
            # A task dialog may ignore a posted Enter: press its Cancel button.
            Write-E2eInfo 'posted Enter did not close the dialog; using TDM_CLICK_BUTTON(IDCANCEL)'
            [void][GhosttyE2e.Win]::PostMessageW($dlg, 0x466, [IntPtr]2, [IntPtr]::Zero)
            $closed = Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { -not [GhosttyE2e.Win]::IsWindow($dlg) }
        }
        if (-not $closed) { throw 'dialog still open after Enter and Cancel' }
        Start-Sleep -Milliseconds 2500
        if ((Test-Path $fa) -or (Test-Path $fb)) { throw 'Enter on the dialog (default No) still pasted and ran the text' }

        # 2. Allow: both lines are pasted and run.
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+shift+v'
        $dlg = Get-PasteDialog
        if (-not $dlg) { throw 'no confirmation dialog on the second paste' }
        # TDM_CLICK_BUTTON (WM_USER + 102) on the custom Allow button (id 100).
        [void][GhosttyE2e.Win]::PostMessageW($dlg, 0x466, [IntPtr]100, [IntPtr]::Zero)
        $closed = Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { -not [GhosttyE2e.Win]::IsWindow($dlg) }
        if (-not $closed) { throw 'dialog still open 5 s after answering Allow' }

        # Git Bash enables bracketed paste: the pasted lines wait in readline's
        # buffer (highlighted) until Enter, then both run.
        Start-Sleep -Milliseconds 1200
        Save-Evidence 'pasted' $g -Window
        if ((Test-Path $fa) -or (Test-Path $fb)) { Write-E2eInfo 'pasted lines ran without Enter (shell is not in bracketed paste mode)' }
        else { Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter' }

        if (-not (Wait-File $fa 15)) { Save-Evidence 'after-yes-fail' $g -Window; throw 'first pasted line did not run after Allow' }
        if (-not (Wait-File $fb 15)) { throw 'second pasted line did not run after Allow' }
        $a = (Get-Content -LiteralPath $fa -Raw).Trim()
        $b = (Get-Content -LiteralPath $fb -Raw).Trim()
        if ($a -ne 'a' -or $b -ne 'b') { throw "pasted lines produced '$a' and '$b'" }
        Save-Evidence 'after-yes' $g
    } finally {
        Restore-ClipboardText $saved
    }
}
