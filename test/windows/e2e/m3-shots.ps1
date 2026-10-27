# e2e: milestone=M3 timeout=600 order=900
# m3-shots: the M3 acceptance screenshot set, one PNG per feature in the evidence dir
# (m3-<name>.png): search bar, command palette (open, filtered), key-state label,
# read-only badge, link label, quick terminal (top, bottom), inspector, health bar
# (Debug builds only: simulated device loss), dimmed split, bell border, custom
# shader. Every image is a crop of one Ghostty window taken through Save-WindowShot
# (screen rect after the foreign-window guard, so owned popups show); a phase that
# meets a foreign window records a SKIP line and the set continues. The transparency
# shots over the magenta backdrop come from the transparency and opacity-blur
# scenarios. Interactive only. Keep this file ASCII only.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')
. (Join-Path $PSScriptRoot '_backdrop.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force

if (-not ('GhosttyE2e.ShotDwm' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name ShotDwm -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, ref RECT r, int size);
"@
}
if (-not ('GhosttyE2e.ShotKeys' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name ShotKeys -MemberDefinition @"
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
"@
}

Invoke-E2eScenario 'm3-shots' {
    $dir = Get-EvidenceDir
    if (-not $dir) { throw 'E2E-SKIP: no evidence dir (run through e2e.ps1 -EvidenceDir)' }
    $results = New-Object System.Collections.ArrayList
    $smoke = Join-Path $script:WinDir 'vt-smoke'

    # Runs one phase with a fresh Ghostty; a SKIP or a failure is recorded, the set goes on.
    function Invoke-Phase([string]$Name, [scriptblock]$Body) {
        try {
            Stop-OwnGhostty
            & $Body
            [void]$results.Add("OK   $Name")
        } catch {
            $m = $_.Exception.Message
            if ($m -like 'E2E-SKIP:*') { [void]$results.Add("SKIP $Name : $($m.Substring(9).Trim())") }
            else { [void]$results.Add("FAIL $Name : $m") }
        }
        Write-E2eInfo $results[$results.Count - 1]
    }
    # The visible frame (DWMWA_EXTENDED_FRAME_BOUNDS), not GetWindowRect: the latter holds the invisible resize
    # border, where the pixels belong to whatever is behind the window. Still through the capture guard.
    function Shot($G, [IntPtr]$Hwnd, [string]$Name, [int]$Margin = 0) {
        $r = New-Object GhosttyE2e.ShotDwm+RECT
        if ([GhosttyE2e.ShotDwm]::DwmGetWindowAttribute($Hwnd, 9, [ref]$r, 16) -ne 0) { throw "no frame bounds for $Name" }
        # 3 px inset: the rounded corners and the 1 px border blend with whatever is behind the window.
        $bmp = Get-ScreenShot ($r.Left + 3) ($r.Top + 3) ($r.Right - $r.Left - 6) ($r.Bottom - $r.Top - 6)
        try { $bmp.Save((Join-Path $dir "m3-$Name.png"), [Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
    }
    function Place($G) {
        Move-Window $G.Hwnd 160 160 1000 700
        [void](Set-ForegroundSafe -Hwnd $G.Hwnd)
        Start-Sleep -Milliseconds 800
    }
    function Get-Data($G) { Get-IpcData (Get-GhosttyState -Class $G.Class) }
    function Get-Labels($G) { @([GhosttyE2e.Win]::TopLevel([uint32]$G.Pid, 'GhosttyOverlayLabel') | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) }) }
    function Get-HwndFromText([string]$s) { [IntPtr][Convert]::ToInt64($s.Substring(2), 16) }

    Invoke-Phase 'search bar' {
        if (-not (Find-GitBash)) { throw 'E2E-SKIP: Git Bash not found' }
        $g = Start-BashE2e
        Place $g
        Send-Line $g.Hwnd 'echo alpha beta alpha gamma alpha'
        Start-Sleep -Milliseconds 500
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'start_search')
        if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { $s = (Get-Data $g).m3.search; $s.visible -and $s.focused })) { throw 'no search bar' }
        Invoke-SendInput -Hwnd $g.Hwnd -Text 'alpha' -Panel
        Wait-Until -TimeoutSec 3 -PollMs 100 -Condition { (Get-Data $g).m3.search.total -ge 3 } | Out-Null
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter' -Panel
        Start-Sleep -Milliseconds 500
        Shot $g $g.Hwnd 'search-bar'
    }

    Invoke-Phase 'command palette' {
        $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'cmd')
        Place $g
        [void](Wait-SurfaceCount $g 1)
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_command_palette')
        if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { $p = (Get-Data $g).m3.palette; $p.open -and $p.visible -and $p.focused })) { throw 'no palette' }
        Start-Sleep -Milliseconds 400
        Shot $g $g.Hwnd 'palette-open'
        Invoke-SendInput -Hwnd $g.Hwnd -Text 'split' -Panel
        Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { (Get-Data $g).m3.palette.query -eq 'split' } | Out-Null
        Start-Sleep -Milliseconds 400
        Shot $g $g.Hwnd 'palette-filtered'
    }

    Invoke-Phase 'key-state label and read-only badge' {
        $cfg = (Get-Content -LiteralPath (Get-ConfigPath 'cmd') -Raw -Encoding UTF8) + "`nconfirm-close-surface = false`nkeybind = ctrl+shift+a>x=new_split:right`n"
        $g = Start-E2eGhostty -ConfigText $cfg
        [void](Wait-ChildNamed $g @('cmd.exe') 15)
        Place $g
        Set-WindowLayout $g.Hwnd '00000409'
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+shift+a'
        if (-not (Wait-Until -TimeoutSec 3 -PollMs 50 -Condition { @(Get-Labels $g).Count -eq 1 })) { throw 'no key state label' }
        Start-Sleep -Milliseconds 300
        Shot $g $g.Hwnd 'key-state'
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'x'
        Wait-Until -TimeoutSec 3 -PollMs 50 -Condition { @(Get-Labels $g).Count -eq 0 } | Out-Null
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_readonly')
        if (-not (Wait-Until -TimeoutSec 3 -PollMs 50 -Condition { @(Get-Labels $g).Count -eq 1 })) { throw 'no read-only badge' }
        Start-Sleep -Milliseconds 300
        Shot $g $g.Hwnd 'readonly-badge'
    }

    Invoke-Phase 'link label' {
        if (-not (Find-GitBash)) { throw 'E2E-SKIP: Git Bash not found' }
        $g = Start-BashE2e
        Place $g
        $url = 'https://example.com/ghostty-e2e'
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+l'
        Start-Sleep -Milliseconds 300
        Send-Line $g.Hwnd ("printf '\033]8;;$url\033\\ghostty-link\033]8;;\033\\\n'")
        Start-Sleep -Milliseconds 800
        $s = @((Get-Data $g).windows)[0].tabs[0].surfaces[0]
        $surface = Get-HwndFromText $s.hwnd
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        $hovered = $false
        [GhosttyE2e.ShotKeys]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
        try {
            foreach ($y in 20..300 | Where-Object { $_ % 10 -eq 0 }) {
                Send-MouseMove -Hwnd $surface -X 30 -Y $y
                if (Wait-Until -TimeoutSec 0.5 -PollMs 50 -Condition { @(Get-Labels $g).Count -ge 1 }) { $hovered = $true; break }
            }
            if (-not $hovered) { throw 'no link label' }
            Start-Sleep -Milliseconds 400
            Shot $g $g.Hwnd 'link-label'
        } finally { [GhosttyE2e.ShotKeys]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero) }
    }

    foreach ($pos in 'top', 'bottom') {
        Invoke-Phase "quick terminal $pos" {
            if (-not (Find-GitBash)) { throw 'E2E-SKIP: Git Bash not found' }
            $base = Get-Content -LiteralPath (Get-ConfigPath 'gitbash-de') -Raw -Encoding UTF8
            $g = Start-E2eGhostty -ConfigText ($base + "`nquick-terminal-animation-duration = 0.1`nquick-terminal-autohide = false`nquick-terminal-position = $pos`n")
            Wait-BashReady $g
            $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $back = New-BackdropForm $wa.X $wa.Y $wa.Width $wa.Height
            try {
            Show-BackdropForm $back
            $p = Start-Launch $g.Class @('+toggle-quick-terminal')
            if (-not $p.WaitForExit(5000)) { throw '+toggle-quick-terminal did not finish' }
            $q = Wait-Until -TimeoutSec 5 -PollMs 50 -Condition {
                $q = (Get-Data $g).m3.quick
                if ($q -and $q.shown -and $q.visible -and -not $q.animating) { $q }
            }
            if (-not $q) { throw 'the quick terminal did not show' }
            Start-Sleep -Milliseconds 600
            Shot $g (Get-HwndFromText $q.hwnd) "quick-$pos-window"
            # The whole work area over our own backdrop: shows where the window sits.
            $bmp = Get-ScreenShot $wa.X $wa.Y $wa.Width $wa.Height
            try { $bmp.Save((Join-Path $dir "m3-quick-$pos.png"), [Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
            } finally { $back.Close() }
        }
    }

    Invoke-Phase 'inspector' {
        if (-not (Find-GitBash)) { throw 'E2E-SKIP: Git Bash not found' }
        $g = Start-BashE2e
        Place $g
        Send-Line $g.Hwnd 'echo inspector shot'
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'inspector:toggle')
        $w = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition {
            $x = @([GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyInspector') | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) })
            if ($x.Count -eq 1) { ,$x }
        }
        if (-not $w) { throw 'no inspector window' }
        Start-Sleep -Milliseconds 1200
        # Topmost over our own main window (same process), so no part of it covers the inspector.
        Move-Window (@($w)[0]) 100 100 900 600
        Start-Sleep -Milliseconds 500
        Shot $g (@($w)[0]) 'inspector'
    }

    Invoke-Phase 'health bar (simulated device loss)' {
        $text = Get-Content -LiteralPath (Get-ConfigPath 'cmd') -Raw -Encoding UTF8
        $g = Start-E2eGhostty -ConfigText $text -Env @{ GHOSTTY_D3D11_SIMULATE_DEVICE_LOST = '9000' }
        $modeLine = Wait-Until -TimeoutSec 15 -PollMs 200 -Condition {
            if (Test-Path -LiteralPath $g.Log) { Select-String -LiteralPath $g.Log -Pattern 'ghostty build optimize=(\S+)' | Select-Object -First 1 }
        }
        if (-not $modeLine) { throw 'no build line in the log' }
        if ($modeLine.Matches[0].Groups[1].Value -ine 'debug') { throw "E2E-SKIP: build optimize=$($modeLine.Matches[0].Groups[1].Value) does not simulate device loss" }
        Place $g
        # The loss is noticed by the next frame: keep drawing, shoot at the first bar.
        $deadline = (Get-Date).AddSeconds(30)
        $shot = $false
        while ((Get-Date) -lt $deadline -and -not $shot) {
            [void](Invoke-GhosttyAction -Class $g.Class -Action 'text:a')
            $bars = [int](Get-Data $g).m3.health.bars
            if ($bars -gt 0) { Shot $g $g.Hwnd 'health-bar'; $shot = $true }
            else { Start-Sleep -Milliseconds 40 }
        }
        if (-not $shot) { throw 'the health bar was never seen (recovery is quicker than the capture)' }
    }

    Invoke-Phase 'dimmed split' {
        $g = Start-E2eGhostty -ConfigText "command = direct:cmd.exe /k chcp 65001`nbackground = #101820`nforeground = #c0c0c0`nunfocused-split-fill = #ffffff`nunfocused-split-opacity = 0.7`n"
        Place $g
        [void](Wait-SurfaceCount $g 1)
        Invoke-SplitAction $g 'new_split:right'
        [void](Wait-SurfaceCount $g 2)
        Invoke-SplitAction $g 'goto_split:left'
        Start-Sleep -Milliseconds 700
        Shot $g $g.Hwnd 'split-dim'
    }

    Invoke-Phase 'bell border' {
        $g = Start-E2eGhostty -ConfigText "command = direct:cmd.exe /k chcp 65001`nbackground = #101820`nunfocused-split-opacity = 1`nbell-features = border`n"
        Place $g
        [void](Wait-SurfaceCount $g 1)
        Invoke-SplitAction $g 'new_split:right'
        $st = Wait-SurfaceCount $g 2
        $left = @(Get-SurfaceBoxes $st | Sort-Object L)[0]
        Invoke-SplitAction $g 'goto_split:left'
        Send-Line $g.Hwnd 'powershell -NoProfile -Command "Start-Sleep 2; [Console]::Write([char]7)"'
        Invoke-SplitAction $g 'goto_split:right'
        # The bell rings in the unfocused left split: wait for its edge to change from the background.
        $edge = Wait-Until -TimeoutSec 20 -PollMs 200 -Condition {
            $d = Read-Dump (Get-DumpPath $g $left.Id)
            if ($d -and -not (Test-PixelNear (Get-DumpPixel $d 0 0) @(16, 24, 32) 6)) { $true }
        }
        if (-not $edge) { throw 'no bell border within 20 s' }
        Start-Sleep -Milliseconds 300
        Shot $g $g.Hwnd 'bell-border'
    }

    Invoke-Phase 'custom shader' {
        if (-not (Find-GitBash)) { throw 'E2E-SKIP: Git Bash not found' }
        $invert = (Join-Path $smoke 'shaders\invert.glsl').Replace([char]92, [char]47)
        $g = Start-BashE2e -ExtraConfig "custom-shader = $invert"
        Place $g
        Send-Line $g.Hwnd 'echo custom shader'
        Send-Line $g.Hwnd 'ls --color=always /c | head -20'
        Start-Sleep -Milliseconds 900
        Shot $g $g.Hwnd 'custom-shader'
    }

    $results | ForEach-Object { Write-Output $_ }
    Set-Content -LiteralPath (Join-Path $dir 'm3-shots-results.txt') -Value $results -Encoding UTF8
    if (@($results | Where-Object { $_ -like 'FAIL*' }).Count) { throw "shot phases failed: $(@($results | Where-Object { $_ -like 'FAIL*' }) -join '; ')" }
}
