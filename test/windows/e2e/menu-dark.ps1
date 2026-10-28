# e2e: milestone=M5 timeout=150 order=640
# menu-dark: the popup menus follow the app theme. The tab menu (a #32768
# window of the process) is dark under the dark scheme and light under the
# light one: its median background luminance is below 90 / above 170 (0..255).
# The scheme is simulated with the test-only `color-scheme` op; the menu is
# captured through the guarded Save-WindowShot. Keep this file ASCII only.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'menu-dark' {
    $g = Start-E2eGhostty -ConfigText "confirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = always`n"
    if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "no frame dump at $($g.Dump)" }
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
    foreach ($i in 1..2) { [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab') }

    function Get-Win { @((Get-GhosttyState -Class $g.Class).windows)[0] }
    function Get-Popup {
        @([GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, '#32768') | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) })
    }
    $w = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { $x = Get-Win; if ($x -and @($x.tabs).Count -eq 3) { $x } }
    if (-not $w) { throw 'three tabs did not appear' }

    foreach ($case in @(@{ Scheme = 'dark'; Dark = $true }, @{ Scheme = 'light'; Dark = $false })) {
        $r = Invoke-GhosttyIpc -Class $g.Class -Request @{ op = 'color-scheme'; scheme = $case.Scheme }
        if ($r.code -ne 0) { throw "color-scheme $($case.Scheme): code $($r.code)" }
        Start-Sleep -Milliseconds 600

        $w = Get-Win
        $t = @($w.strip.tabs)[1]
        $cx = [int](($t[0] + $t[2]) / 2) - 40
        $cy = [int](($t[1] + $t[3]) / 2)
        Send-MouseClick -Hwnd $g.Hwnd -X $cx -Y $cy -Button right
        $menu = Wait-Until -TimeoutSec 4 -PollMs 50 -Condition { Get-Popup | Select-Object -First 1 }
        if (-not $menu) { throw "$($case.Scheme): the tab menu did not open" }
        Start-Sleep -Milliseconds 300

        $png = Join-Path $script:Sbx.Tmp "menu-$($case.Scheme).png"
        Save-WindowShot $menu $png
        $bmp = [Drawing.Bitmap]::FromFile($png)
        try {
            $lum = New-Object System.Collections.Generic.List[double]
            $m = 6
            for ($y = $m; $y -lt $bmp.Height - $m; $y += 3) {
                for ($x = $m; $x -lt $bmp.Width - $m; $x += 3) {
                    $p = $bmp.GetPixel($x, $y)
                    $lum.Add(0.2126 * $p.R + 0.7152 * $p.G + 0.0722 * $p.B)
                }
            }
            $sorted = $lum | Sort-Object
            $median = $sorted[[int]($sorted.Count / 2)]
        } finally { $bmp.Dispose() }
        $dir = Get-EvidenceDir
        if ($dir) { Copy-Item -LiteralPath $png -Destination (Join-Path $dir "menu-dark-$($case.Scheme).png") -Force }
        Write-E2eInfo "$($case.Scheme): tab menu median luminance $([math]::Round($median, 1))"
        if ($case.Dark -and $median -ge 90) { throw "dark scheme: the menu is light (median luminance $median)" }
        if (-not $case.Dark -and $median -le 170) { throw "light scheme: the menu is dark (median luminance $median)" }

        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'esc' -Panel
        $closed = Wait-Until -TimeoutSec 4 -PollMs 50 -Condition { @(Get-Popup).Count -eq 0 }
        if (-not $closed) { throw "$($case.Scheme): the menu did not close" }
    }
}
