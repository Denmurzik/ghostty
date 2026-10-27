# e2e: milestone=M3 timeout=180 order=650
# drop-text: text dragged from an OLE source is pasted like Ctrl+V. One line
# lands at the prompt without running; two lines raise the paste-confirm task
# dialog (GhosttyDialog), and Cancel types nothing. Interactive desktop only.
# Keep this file ASCII only (Windows PowerShell 5.1 reads a BOM-less script as ANSI).
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')
. (Join-Path $PSScriptRoot '_drop.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force

function Invoke-TextDrop($G, [string]$Text) {
    $st = Get-SplitState $G
    $box = (Get-SurfaceBoxes $st)[0]
    $drag = Start-OleTextDrag -Text $Text -ToHwnd $G.Hwnd -X ([int](($box.L + $box.R) / 2)) -Y ([int](($box.T + $box.B) / 2))
    try { Start-Sleep -Milliseconds 200 } finally { Stop-OleFileDrag $drag }
}

Invoke-E2eScenario 'drop-text' {
    $g = Start-BashE2e 'unsafe-paste'
    if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
    $oracle = Join-Path $g.Sandbox.Tmp 'gt-droptext.txt'
    Remove-Item -LiteralPath $oracle -Force -ErrorAction SilentlyContinue

    # 1. One line: typed at the prompt, not executed.
    Send-Typed $g.Hwnd 'echo '
    Invoke-TextDrop $g 'dropped > "$TEMP/gt-droptext.txt"'
    Start-Sleep -Milliseconds 1200
    Save-Evidence 'one-line' $g -Window
    if (Test-Path -LiteralPath $oracle) { throw 'the one-line drop was executed without Enter' }
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
    if (-not (Wait-File $oracle 20)) { throw 'the dropped line did not reach the prompt' }
    if ((Get-Content -LiteralPath $oracle -Raw).Trim() -ne 'dropped') { throw 'the dropped line produced the wrong output' }
    Remove-Item -LiteralPath $oracle -Force

    # 2. Two lines: the confirm dialog; Cancel types nothing.
    Invoke-TextDrop $g "echo one > `"`$TEMP/gt-droptext.txt`"`necho two > `"`$TEMP/gt-droptext.txt`"`n"
    $dlg = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition {
        [GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyDialog') | Select-Object -First 1
    }
    if (-not $dlg) { throw 'no paste-confirm dialog for a two-line drop' }
    Save-Evidence 'dialog' $g -Window -Hwnd $dlg
    # TDM_CLICK_BUTTON (WM_USER + 102) on IDCANCEL.
    [void][GhosttyE2e.Win]::PostMessageW($dlg, 0x466, [IntPtr]2, [IntPtr]::Zero)
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { -not [GhosttyE2e.Win]::IsWindow($dlg) })) { throw 'dialog still open after Cancel' }
    Start-Sleep -Milliseconds 800
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
    Start-Sleep -Milliseconds 2500
    if (Test-Path -LiteralPath $oracle) { throw 'Cancel still pasted the dropped text' }
}
