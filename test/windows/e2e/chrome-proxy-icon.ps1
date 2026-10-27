# e2e: milestone=M3 timeout=240 order=396
# chrome-proxy-icon: the proxy icon of the title row. Without a known working
# directory there is no icon; once the focused surface reports one (test IPC
# op `pwd`) the shell's folder icon appears left of the title, the pair centred
# on the window, and the pixels of the icon rect are coloured. A click records
# the folder as `open` in `m3.opened` (test mode launches nothing), dragging
# the icon onto the terminal pastes the folder as the drop of a folder does,
# `macos-titlebar-proxy-icon = hidden` removes the icon. Interactive only.
# Keep this file ASCII only (Windows PowerShell 5.1 reads a BOM-less script as ANSI).
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

function Get-ScreenShot([int]$X, [int]$Y, [int]$W, [int]$H) {
    $bmp = New-Object Drawing.Bitmap $W, $H
    $gfx = [Drawing.Graphics]::FromImage($bmp)
    try { $gfx.CopyFromScreen($X, $Y, 0, 0, (New-Object Drawing.Size $W, $H)) } finally { $gfx.Dispose() }
    $bmp
}

function Get-Win($G) { @((Get-GhosttyState -Class $G.Class).windows)[0] }

function Set-Pwd($G, [string]$Path) {
    $r = Invoke-GhosttyIpc -Class $G.Class -Request @{ op = 'pwd'; path = $Path }
    if ($r.code -ne 0) { throw "ipc pwd ${Path}: code $($r.code): $($r.stderr)" }
}

Invoke-E2eScenario 'chrome-proxy-icon' {
    $folder = $env:SystemRoot
    $g = Start-BashE2e -ExtraConfig "window-decoration = client`nconfirm-close-surface = false`n"
    try {
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        $w = Get-Win $g
        if ($null -ne $w.strip.proxy_icon) { throw "an icon is shown before any directory is known: $($w.strip.proxy_icon -join ',')" }

        Set-Pwd $g $folder
        $w = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition {
            $w = Get-Win $g
            if ($w -and $null -ne $w.strip.proxy_icon) { $w }
        }
        if (-not $w) { throw 'the proxy icon did not appear after the directory was reported' }
        Start-Sleep -Milliseconds 500
        $w = Get-Win $g
        $s = $w.strip
        $icon = $s.proxy_icon
        $tt = $s.title_text
        $cw = $s.bounds[2] - $s.bounds[0]
        $mid = ($icon[0] + $tt[2]) / 2
        Write-E2eInfo "icon $($icon -join ',') title $($tt -join ',') centre $mid of $cw"
        if ([Math]::Abs($mid - $cw / 2) -gt 10) { throw "icon and title are not centred: centre $mid of $cw" }
        if ($icon[1] -lt 0 -or $icon[3] -gt $s.title_row[3]) { throw "the icon is outside the title row: $($icon -join ',')" }

        $o = New-Object GhosttyE2e.Mouse+POINT
        [void][GhosttyE2e.Mouse]::ClientToScreen($g.Hwnd, [ref]$o)
        $shot = Get-ScreenShot ($o.X + $icon[0]) ($o.Y + $icon[1]) ($icon[2] - $icon[0]) ($icon[3] - $icon[1])
        $colours = @{}
        for ($y = 0; $y -lt $shot.Height; $y++) { for ($x = 0; $x -lt $shot.Width; $x++) { $colours[$shot.GetPixel($x, $y).ToArgb()] = 1 } }
        $dir = Get-EvidenceDir
        if ($dir) { $shot.Save((Join-Path $dir 'chrome-proxy-icon-icon.png'), [Drawing.Imaging.ImageFormat]::Png) }
        $shot.Dispose()
        Write-E2eInfo "$($colours.Count) distinct colours in the icon rect"
        if ($colours.Count -lt 8) { throw "the icon rect is flat ($($colours.Count) colours)" }
        Save-Evidence 'proxy-icon' $g -Window

        # Click: the folder is recorded as opened.
        $cx = [int](($icon[0] + $icon[2]) / 2)
        $cy = [int](($icon[1] + $icon[3]) / 2)
        Send-MouseClick -Hwnd $g.Hwnd -X $cx -Y $cy
        $rec = Wait-Until -TimeoutSec 5 -PollMs 100 -Condition {
            @((Get-GhosttyState -Class $g.Class).m3.opened) | Where-Object { $_.url -eq $folder -and $_.verdict -eq 'open' } | Select-Object -First 1
        }
        if (-not $rec) { throw "the click did not record $folder as open: $(@((Get-GhosttyState -Class $g.Class).m3.opened) | ConvertTo-Json -Compress -Depth 4)" }
        Write-E2eInfo 'click recorded as open'

        # Drag onto the terminal: the folder is pasted (msys form in Git Bash).
        $oracle = Join-Path $g.Sandbox.Tmp 'gt-proxy.txt'
        Remove-Item -LiteralPath $oracle -Force -ErrorAction SilentlyContinue
        Send-Typed $g.Hwnd "echo -n "
        Start-Sleep -Milliseconds 400
        $below = [int]$s.bounds[3] + 100
        Send-MouseDrag -Hwnd $g.Hwnd -X $cx -Y $cy -ToX 300 -ToY $below -Steps 25 -HoldMs 400
        Start-Sleep -Milliseconds 1200
        Send-Typed $g.Hwnd " > `"`$TEMP/gt-proxy.txt`""
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
        if (-not (Wait-File $oracle 20)) { Save-Evidence 'drag-fail' $g -Window; throw 'the dragged folder was not pasted' }
        $text = [IO.File]::ReadAllText($oracle)
        Write-E2eInfo "pasted: $text"
        if ($text -notmatch '(?i)c/windows') { throw "the pasted text does not name the folder: $text" }
        [void](Get-Win $g)
    } finally {
        if (-not $g.Process.HasExited) {
            $g.Process.Kill()
            [void]$g.Process.WaitForExit(5000)
        }
    }

    # Hidden: no icon, however well known the directory is.
    $g = Start-BashE2e -ExtraConfig "window-decoration = client`nmacos-titlebar-proxy-icon = hidden`n"
    try {
        Set-Pwd $g $folder
        Start-Sleep -Milliseconds 800
        $w = Get-Win $g
        if ($null -ne $w.strip.proxy_icon) { throw "macos-titlebar-proxy-icon = hidden still shows the icon: $($w.strip.proxy_icon -join ',')" }
        Write-E2eInfo 'hidden: no icon'
    } finally {
        if (-not $g.Process.HasExited) {
            $g.Process.Kill()
            [void]$g.Process.WaitForExit(5000)
        }
    }
}
