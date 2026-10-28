# e2e: milestone=M2 timeout=240 order=420
# close-confirm: closing something that still runs a process asks first, with
# a dialog (class GhosttyDialog, owned by the Ghostty pid). Cancel (the default)
# keeps everything; "Close" (id 100) closes and kills the process tree. Also
# covered: a shell that exits behind an open dialog, an IPC new-tab that runs
# inside the dialog's message loop, close_tab with two tabs and quit with
# its single-dialog gate. Dialog buttons are driven with TDM_CLICK_BUTTON.
# Keep this file ASCII only.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

$script:WM_CLOSE = 0x10
$script:TDM_CLICK_BUTTON = 0x466   # WM_USER + 102
$script:IdClose = 100
$script:IdCancel = 2

function Get-ConfirmDialogs($G) { @([GhosttyE2e.Win]::TopLevel([uint32]$G.Pid, 'GhosttyDialog')) }

function Wait-ConfirmDialog($G, [string]$What) {
    $dlg = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { Get-ConfirmDialogs $G | Select-Object -First 1 }
    if (-not $dlg) { throw "no confirmation dialog (GhosttyDialog) within 8 s: $What" }
    $dlg
}

function Send-DialogButton($Dlg, [int]$Id) {
    [void][GhosttyE2e.Win]::PostMessageW($Dlg, $script:TDM_CLICK_BUTTON, [IntPtr]$Id, [IntPtr]::Zero)
}

function Wait-DialogGone($Dlg, [string]$What) {
    $gone = Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { -not [GhosttyE2e.Win]::IsWindow($Dlg) }
    if (-not $gone) { throw "dialog still open 5 s after: $What" }
}

function Get-TabCount($G) {
    $d = Get-GhosttyState -Class $G.Class
    @(@($d.windows)[0].tabs).Count
}

# Git Bash with the close confirmation on (the shared configs switch it off).
function Start-ConfirmShell {
    $cfg = (Get-Content -LiteralPath (Get-ConfigPath 'gitbash-de') -Raw -Encoding UTF8) -replace 'confirm-close-surface = false', 'confirm-close-surface = true'
    $g = Start-E2eGhostty -ConfigText $cfg
    Wait-BashReady $g
    $g
}

function Start-PingShell {
    $g = Start-ConfirmShell
    Send-Line $g.Hwnd 'ping -t 127.0.0.1 > /dev/null'
    if (-not (Wait-ChildNamed $g @('ping.exe') 15)) { throw 'ping.exe never started' }
    Start-Sleep -Milliseconds 500
    $g
}

Invoke-E2eScenario 'close-confirm' {
    # 1. Window close: Cancel keeps the window, Close ends the whole tree.
    $g = Start-PingShell
    $snapshot = @(Get-ProcessTree $g.Pid)
    [void][GhosttyE2e.Win]::PostMessageW($g.Hwnd, $script:WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    $dlg = Wait-ConfirmDialog $g 'WM_CLOSE with a running ping'
    Write-E2eInfo "dialog title '$([GhosttyE2e.Win]::TextOf($dlg))'"
    Save-Evidence 'close-window' $g -Window -Hwnd $dlg
    Send-DialogButton $dlg $script:IdCancel
    Wait-DialogGone $dlg 'Cancel'
    Start-Sleep -Milliseconds 500
    if (-not [GhosttyE2e.Win]::IsWindow($g.Hwnd)) { throw 'the window closed after Cancel' }
    if ($g.Process.HasExited) { throw 'ghostty exited after Cancel' }

    [void][GhosttyE2e.Win]::PostMessageW($g.Hwnd, $script:WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    $dlg = Wait-ConfirmDialog $g 'second WM_CLOSE'
    Send-DialogButton $dlg $script:IdClose
    $exit = Wait-ProcessExit $g 5
    if (-not $exit.Exited) { throw 'ghostty still running 5 s after Close' }
    Assert-NoSurvivors $snapshot $g.Pid 3

    # 2. A shell that exits behind the dialog: its tab and window close while
    # the dialog is up; answering must not crash.
    $g = Start-ConfirmShell
    Send-Line $g.Hwnd 'sleep 4; exit'
    Start-Sleep -Milliseconds 400
    [void][GhosttyE2e.Win]::PostMessageW($g.Hwnd, $script:WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    $dlg = Wait-ConfirmDialog $g 'WM_CLOSE while a sleep runs'
    Start-Sleep -Seconds 6
    if ([GhosttyE2e.Win]::IsWindow($dlg)) { Send-DialogButton $dlg $script:IdCancel }
    $exit = Wait-ProcessExit $g 5
    if (-not $exit.Exited) { throw 'ghostty still running 5 s after the dialog was answered behind an exited shell' }
    if ($exit.Ms -gt 5000) { throw "ghostty needed $($exit.Ms) ms to exit" }

    # 3. close_tab with two tabs and a running ping asks and Cancel keeps both.
    $g = Start-PingShell
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
    [void](Wait-GhosttyState -Class $g.Class -TimeoutSec 10 -Predicate { @(@($_.windows)[0].tabs).Count -eq 2 })
    # Back to the first tab (the one running ping).
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'goto_tab:1')
    Start-Sleep -Milliseconds 400
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'close_tab')
    $dlg = Wait-ConfirmDialog $g 'close_tab with a running ping'
    Save-Evidence 'close-tab' $g -Window -Hwnd $dlg
    Send-DialogButton $dlg $script:IdCancel
    Wait-DialogGone $dlg 'Cancel on close_tab'
    Start-Sleep -Milliseconds 400
    if ((Get-TabCount $g) -ne 2) { throw "Cancel on close_tab left $(Get-TabCount $g) tabs, expected 2" }

    # 4. An IPC new-tab runs inside the open dialog's message loop: no crash,
    # the new tab is not closed unasked, the dialog stays until answered.
    [void][GhosttyE2e.Win]::PostMessageW($g.Hwnd, $script:WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    $dlg = Wait-ConfirmDialog $g 'WM_CLOSE before the IPC new-tab'
    $r = Invoke-GhosttyIpc -Class $g.Class -Request @{ op = 'new-tab'; args = @() }
    if ($r.code -ne 0) { throw "ipc new-tab failed: code $($r.code): $($r.stderr)" }
    $st = Wait-GhosttyState -Class $g.Class -TimeoutSec 10 -Predicate { @(@($_.windows)[0].tabs).Count -eq 3 }
    if (-not [GhosttyE2e.Win]::IsWindow($dlg)) { throw 'the dialog vanished when a tab was added behind it' }
    Send-DialogButton $dlg $script:IdCancel
    Wait-DialogGone $dlg 'Cancel after the IPC new-tab'
    Start-Sleep -Milliseconds 500
    if ($g.Process.HasExited) { throw 'ghostty exited while the new tab was added behind the dialog' }
    if ((Get-TabCount $g) -ne 3) { throw "expected 3 tabs after Cancel, found $(Get-TabCount $g)" }

    # 5. quit asks once ("Quit Ghostty?"); a second quit adds no second dialog.
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'quit')
    $dlg = Wait-ConfirmDialog $g 'quit with a running ping'
    Save-Evidence 'quit' $g -Window -Hwnd $dlg
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'quit')
    Start-Sleep -Milliseconds 1200
    $n = @(Get-ConfirmDialogs $g).Count
    if ($n -ne 1) { throw "a second quit left $n dialogs, expected 1 (QuitGate)" }
    Send-DialogButton $dlg $script:IdCancel
    Wait-DialogGone $dlg 'Cancel on quit'
    Start-Sleep -Milliseconds 500
    if ($g.Process.HasExited) { throw 'ghostty exited after Cancel on the quit dialog' }
}
