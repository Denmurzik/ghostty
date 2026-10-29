# e2e: milestone=M2 timeout=180 order=320
# tab-rename: a double click on a tab opens a borderless themed popup with an
# Edit control over it (state.windows[0].title_edit); Enter commits (the tab
# title changes), Esc cancels, an empty commit clears the title. The
# prompt_surface_title action opens the editor too, and its commit sets the
# surface title. The editor is not a white box (fewer than 10 % of its pixels
# are near white, its median colour is the tab fill within 24 per channel)
# and the typed text is visible, also with background-opacity = 0.85.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_backdrop.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'tab-rename' {
    $g = Start-E2eGhostty -ConfigText "confirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = always`n"
    if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "no frame dump at $($g.Dump)" }
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)

    function Get-Win {
        $d = Get-GhosttyState -Class $g.Class
        @($d.windows)[0]
    }
    function Wait-Win([string]$What, [scriptblock]$Predicate, [double]$TimeoutSec = 6) {
        $w = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
            $w = Get-Win
            if ($w -and (& $Predicate $w)) { $w }
        }
        if (-not $w) { throw "timeout waiting for: $What; state: $(Get-Win | ConvertTo-Json -Depth 8 -Compress)" }
        $w
    }
    function Get-Centre($R) { , @([int](($R[0] + $R[2]) / 2), [int](($R[1] + $R[3]) / 2)) }
    function Get-TitleEdit { $w = Get-Win; if ($w) { $w.title_edit } }
    function Wait-Edit([bool]$Present, [string]$What) {
        $ok = Wait-Until -TimeoutSec 4 -PollMs 50 -Condition { $t = Get-TitleEdit; ($t -and ([bool]$t.open) -eq $Present) }
        if (-not $ok) { throw "$What : the title editor is $(if ($Present) { 'missing' } else { 'still there' })" }
    }

    # Pixels of the editor popup (screen rect from the state): the pre-typing
    # capture is returned; a white box or a text-less editor throws.
    # The editor rect from the state; the editor can be momentarily absent from a poll.
    function Get-EditRect {
        for ($i = 0; $i -lt 30; $i++) {
            $e = Get-TitleEdit
            if ($e -and $e.rect) { return ,@($e.rect | ForEach-Object { [int]$_ }) }
            Start-Sleep -Milliseconds 100
        }
        throw 'the title editor has no rect in the state'
    }
    function Get-EditorShot {
        $r = Get-EditRect
        $script:EditRect = $r
        $bmp = Get-ScreenShot $r[0] $r[1] ($r[2] - $r[0]) ($r[3] - $r[1])
        $bmp
    }
    function Get-Median([int[]]$Values) {
        $s = @($Values | Sort-Object)
        $s[[int][Math]::Floor($s.Count / 2)]
    }
    function Get-Lum($p) { 0.2126 * $p.R + 0.7152 * $p.G + 0.0722 * $p.B }
    function Assert-EditorLooksLikeTab([string]$Tag, $Bmp) {
        $white = 0; $rs = @(); $gs = @(); $bs = @()
        for ($y = 0; $y -lt $Bmp.Height; $y++) {
            for ($x = 0; $x -lt $Bmp.Width; $x++) {
                $p = $Bmp.GetPixel($x, $y)
                if ($p.R -ge 240 -and $p.G -ge 240 -and $p.B -ge 240) { $white++ }
                $rs += [int]$p.R; $gs += [int]$p.G; $bs += [int]$p.B
            }
        }
        $total = $Bmp.Width * $Bmp.Height
        if ($white -ge 0.1 * $total) { throw "$Tag : the editor is a white box ($white of $total pixels are near white)" }
        # The tab fill next to the editor: the tab strip just above it, inside the same tab.
        $r = $script:EditRect
        $near = Get-ScreenShot $r[0] ($r[1] - 3) ($r[2] - $r[0]) 1
        $nr = @(); $ng = @(); $nb = @()
        for ($x = 0; $x -lt $near.Width; $x++) { $p = $near.GetPixel($x, 0); $nr += [int]$p.R; $ng += [int]$p.G; $nb += [int]$p.B }
        $near.Dispose()
        $med = @((Get-Median $rs), (Get-Median $gs), (Get-Median $bs))
        $fill = @((Get-Median $nr), (Get-Median $ng), (Get-Median $nb))
        for ($i = 0; $i -lt 3; $i++) {
            if ([Math]::Abs($med[$i] - $fill[$i]) -gt 24) { throw "$Tag : editor median colour $($med -join ',') is not the tab fill $($fill -join ',') (+-24)" }
        }
        Write-E2eInfo "$Tag : editor median $($med -join ','), tab fill $($fill -join ','), near-white $white/$total"
    }
    function Assert-EditorTextVisible([string]$Tag, $Before) {
        $after = Get-EditorShot
        try {
            $n = 0
            $w = [Math]::Min($Before.Width, $after.Width); $h = [Math]::Min($Before.Height, $after.Height)
            for ($y = 0; $y -lt $h; $y++) {
                for ($x = 0; $x -lt $w; $x++) {
                    if ([Math]::Abs((Get-Lum $after.GetPixel($x, $y)) - (Get-Lum $Before.GetPixel($x, $y))) -gt 60) { $n++ }
                }
            }
            if ($n -lt 30) { throw "$Tag : only $n pixels changed by typing; the text is not visible" }
            Write-E2eInfo "$Tag : $n pixels changed by typing"
        } finally { $after.Dispose() }
    }
    # Opens the editor on the first tab, checks the pixels, types, checks the text, Esc.
    function Test-EditorPixels([string]$Tag) {
        $w = Get-Win
        $c = Get-Centre @($w.strip.tabs)[0]
        Send-MouseClick -Hwnd $g.Hwnd -X ($c[0] - 40) -Y $c[1] -Double
        Wait-Edit $true "$Tag double click"
        Start-Sleep -Milliseconds 300
        $before = Get-EditorShot
        try {
            Assert-EditorLooksLikeTab $Tag $before
            Invoke-SendInput -Panel -Hwnd $g.Hwnd -Text 'renamed'
            Start-Sleep -Milliseconds 300
            Assert-EditorTextVisible $Tag $before
        } finally { $before.Dispose() }
        Invoke-SendInput -Panel -Hwnd $g.Hwnd -Keys 'esc'
        Wait-Edit $false "$Tag Esc"
    }


    # 0. The editor is the tab made editable, not a white box.
    Test-EditorPixels 'opaque'

    # 1. Double click on the tab, type, Enter.
    $w = Get-Win
    $c = Get-Centre @($w.strip.tabs)[0]
    Send-MouseClick -Hwnd $g.Hwnd -X ($c[0] - 40) -Y $c[1] -Double
    Wait-Edit $true 'double click'
    Invoke-SendInput -Panel -Hwnd $g.Hwnd -Text 'renamed'
    Invoke-SendInput -Panel -Hwnd $g.Hwnd -Keys 'enter'
    Wait-Edit $false 'Enter'
    $w = Wait-Win 'tab title renamed' { param($w) @($w.tabs)[0].title -eq 'renamed' }
    $caption = Wait-Until -TimeoutSec 4 -PollMs 100 -Condition {
        $t = [GhosttyE2e.Win]::TextOf($g.Hwnd)
        if ($t -eq 'renamed') { $t }
    }
    if (-not $caption) { throw "window caption '$([GhosttyE2e.Win]::TextOf($g.Hwnd))', want 'renamed'" }

    # 2. Again, type, Esc: unchanged.
    $c = Get-Centre @($w.strip.tabs)[0]
    Send-MouseClick -Hwnd $g.Hwnd -X ($c[0] - 40) -Y $c[1] -Double
    Wait-Edit $true 'second double click'
    Invoke-SendInput -Panel -Hwnd $g.Hwnd -Text 'discarded'
    Invoke-SendInput -Panel -Hwnd $g.Hwnd -Keys 'esc'
    Wait-Edit $false 'Esc'
    Start-Sleep -Milliseconds 300
    $w = Get-Win
    if (@($w.tabs)[0].title -ne 'renamed') { throw "Esc changed the title to '$(@($w.tabs)[0].title)'" }

    # 3. prompt_surface_title opens the editor, Enter sets the surface title.
    if (-not (Invoke-GhosttyAction -Class $g.Class -Action 'prompt_surface_title')) { throw 'prompt_surface_title was not performed' }
    Wait-Edit $true 'prompt_surface_title'
    Invoke-SendInput -Panel -Hwnd $g.Hwnd -Text 'surf'
    Invoke-SendInput -Panel -Hwnd $g.Hwnd -Keys 'enter'
    Wait-Edit $false 'Enter after prompt_surface_title'
    $w = Wait-Win 'surface title surf' { param($w) @(@($w.tabs)[0].surfaces)[0].title -eq 'surf' }

    # 4. An empty commit on the tab clears the user's title.
    $c = Get-Centre @($w.strip.tabs)[0]
    Send-MouseClick -Hwnd $g.Hwnd -X ($c[0] - 40) -Y $c[1] -Double
    Wait-Edit $true 'third double click'
    Invoke-SendInput -Panel -Hwnd $g.Hwnd -Keys 'backspace'
    Invoke-SendInput -Panel -Hwnd $g.Hwnd -Keys 'enter'
    Wait-Edit $false 'Enter with empty text'
    [void](Wait-Win 'title back to the surface title' { param($w) @($w.tabs)[0].title -eq 'surf' })

    Save-Evidence -Tag 'tab-rename' -G $g -Window

    # 5. The same pixels over a translucent window (issues-after-v1 section 3).
    if (-not $g.Process.HasExited) { $g.Process.Kill(); [void]$g.Process.WaitForExit(5000) }
    # A backdrop window of ours behind it: the owner's windows must not show through the glass.
    $back = New-BackdropForm 60 60 1500 1000
    try {
        Show-BackdropForm $back
        Move-Window $back.Handle 60 60 1500 1000
        $g = Start-E2eGhostty -ConfigText "confirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = always`nbackground-opacity = 0.85`n"
        if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "translucent: no frame dump at $($g.Dump)" }
        Move-Window $g.Hwnd 160 160 1000 700
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        Start-Sleep -Milliseconds 800
        Test-EditorPixels 'translucent'
    } finally { $back.Close() }
}
