# e2e: milestone=M2 timeout=120 order=390
# resize-overlay: with `resize-overlay = always` and a 1 s duration a resize
# shows a GhosttyResizeOverlay popup of the process within 1 s and hides it
# again after the duration; the popup never takes the foreground. With
# `resize-overlay = never` no overlay window is ever visible.
. (Join-Path $PSScriptRoot '_common.ps1')

if (-not ('GhosttyE2e.Fg' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Fg -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();'
}

function Get-OverlayWindows($G) {
    @([GhosttyE2e.Win]::TopLevel([uint32]$G.Pid, 'GhosttyResizeOverlay') | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) })
}

Invoke-E2eScenario 'resize-overlay' {
    $g = Start-E2eGhostty -ConfigText "background = #102030`nconfirm-close-surface = false`nresize-overlay = always`nresize-overlay-duration = 1s"
    if (-not (Wait-Dump $g { param($d) $d.Width -gt 100 } 15)) { throw 'no frame dump within 15 s' }
    if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
    Start-Sleep -Milliseconds 1500
    if (@(Get-OverlayWindows $g).Count) { throw 'overlay visible before any resize' }

    Set-WindowSize $g.Hwnd 640 420
    if (-not (Wait-Until { @(Get-OverlayWindows $g).Count -gt 0 } 1)) { throw 'no visible GhosttyResizeOverlay within 1 s of the resize' }
    Write-E2eInfo 'overlay visible'
    $fg = [GhosttyE2e.Fg]::GetForegroundWindow()
    if ($fg -ne $g.Hwnd) { throw "foreground is $fg while the overlay shows, expected the Ghostty window $($g.Hwnd)" }

    Start-Sleep -Milliseconds 2500
    if (@(Get-OverlayWindows $g).Count) { throw 'overlay still visible 2.5 s after the resize with a 1 s duration' }
    Write-E2eInfo 'overlay hidden after the duration'

    $errors = @(Get-LogErrors $g)
    if ($errors.Count) { throw "ghostty.log has $($errors.Count) error line(s), first: $($errors[0])" }


    # never: a second instance of its own
    try { $g.Process.Kill() } catch { }
    [void]$g.Process.WaitForExit(5000)
    $g = Start-E2eGhostty -ConfigText "background = #102030`nconfirm-close-surface = false`nresize-overlay = never"
    if (-not (Wait-Dump $g { param($d) $d.Width -gt 100 } 15)) { throw 'no frame dump within 15 s' }

    foreach ($size in @(@(640, 420), @(500, 350), @(800, 500))) {
        Set-WindowSize $g.Hwnd $size[0] $size[1]
        $deadline = [DateTime]::UtcNow.AddMilliseconds(1200)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (@(Get-OverlayWindows $g).Count) { throw "overlay visible after the resize to $($size[0])x$($size[1]) with resize-overlay = never" }
            Start-Sleep -Milliseconds 50
        }
    }
    Write-E2eInfo 'no overlay ever visible'
}
