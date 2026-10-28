# e2e: milestone=M3 timeout=120 order=560
# status-overlays: `keybind = ctrl+shift+a>x=new_split:right` shows the key
# state label after ctrl+shift+a and hides it after `x` (a split exists);
# `toggle_readonly` shows the read-only badge and again hides it; copying a
# selection (`select_all`, `copy_to_clipboard`) shows the in-app toast within
# 500 ms and it is gone after 2.5 s. The clipboard is backed up and restored.
# Interactive only.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

Add-Type -AssemblyName System.Windows.Forms

Invoke-E2eScenario 'status-overlays' {
    $saved = Save-ClipboardText
    try {
        $cfg = (Get-Content -LiteralPath (Get-ConfigPath 'cmd') -Raw -Encoding UTF8) +
            "`nconfirm-close-surface = false`nkeybind = ctrl+shift+a>x=new_split:right`n"
        $g = Start-E2eGhostty -ConfigText $cfg
        [void](Wait-ChildNamed $g @('cmd.exe') 15)
        if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
        Set-WindowLayout $g.Hwnd '00000409'

        function Get-VisibleLabels { @([GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyOverlayLabel') | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) }) }
        function Wait-Labels([int]$Count, [double]$TimeoutSec) {
            Wait-Until -TimeoutSec $TimeoutSec -PollMs 50 -Condition { @(Get-VisibleLabels).Count -eq $Count }
        }
        Wait-SurfaceCount $g 1 | Out-Null

        # 1. Key sequence.
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+shift+a'
        if (-not (Wait-Labels 1 3)) { throw 'no key state label after ctrl+shift+a' }
        Save-Evidence 'key-sequence' $g -Window
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'x'
        if (-not (Wait-Labels 0 3)) { throw 'the key state label stays after the sequence ended' }
        Wait-SurfaceCount $g 2 | Out-Null
        Write-E2eInfo 'key sequence ok'

        # 2. Read-only badge.
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_readonly')
        if (-not (Wait-Labels 1 3)) { throw 'no read-only badge after toggle_readonly' }
        Save-Evidence 'readonly' $g -Window
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_readonly')
        if (-not (Wait-Labels 0 3)) { throw 'the read-only badge stays after the second toggle' }
        Write-E2eInfo 'read-only ok'

        # 3. Copy toast.
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'select_all')
        $sw = [Diagnostics.Stopwatch]::StartNew()
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'copy_to_clipboard')
        Update-ClipboardMark
        if (-not (Wait-Labels 1 0.5)) { throw 'no copy toast within 500 ms' }
        Write-E2eInfo "toast after $($sw.ElapsedMilliseconds) ms"
        Save-Evidence 'toast' $g -Window
        $gone = Wait-Until -TimeoutSec 2.5 -PollMs 100 -Condition { @(Get-VisibleLabels).Count -eq 0 }
        if (-not $gone) { throw 'the copy toast is still shown 2.5 s later' }
        Write-E2eInfo 'toast ok'

        $errors = @(Get-LogErrors $g)
        if ($errors.Count) { throw "ghostty.log has $($errors.Count) error line(s), first: $($errors[0])" }
    } finally {
        Restore-ClipboardText $saved
    }
}
