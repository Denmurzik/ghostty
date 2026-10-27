# WARNING: this spike captures the screen (CopyFromScreen) and is not guarded; run it only on a clear desktop.
<#
.SYNOPSIS
Runs the chrome spike (risk R9) and prints the measurements that decide the
tab-strip painter backend and whether SetParent keeps a presenting flip-model
swap chain alive.

.DESCRIPTION
Build first:  zig build -j2 --build-file test/windows/chrome-spike/build.zig

Every window launch, focus, hover and screen capture happens inside a
Harness scenario (Invoke-GuiScenario), i.e. under the shared desktop lock
%TEMP%\gui-e2e.lock; a locked or non-interactive session is a SKIP. Only the
spike's own windows are captured and only the processes started here are
killed. The cursor position is restored after hover steps.

Scenarios:
  none             baseline: Mica strip left transparent (no painter)
  dc               D2D DC render target in a BeginBufferedPaint DC, hover, maximize
  none-nobuttons   check (a): no DWM-drawn ghost caption buttons
  reparent         check (c): SetParent of the presenting child into a second window
  none2 / dc2      repeat of the RAM measurement (noise estimate)

Each run appends lines to <ShotsDir>\results.txt: CHECK/INFO/RAM lines are the
raw evidence for the report.
#>
param(
    [string]$Exe = (Join-Path $PSScriptRoot 'zig-out\bin\chrome-spike.exe'),
    [string]$ShotsDir = (Join-Path $env:TEMP 'chrome-spike-shots'),
    [string[]]$Only = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# `-File run.ps1 -Only a,b` arrives as one string.
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

Import-Module (Join-Path $PSScriptRoot '..\lib\Harness.psm1') -Force

if (-not (Test-Path -LiteralPath $Exe)) { throw "spike exe not found: $Exe (build it first)" }
New-Item -ItemType Directory -Force -Path $ShotsDir | Out-Null
$Results = Join-Path $ShotsDir 'results.txt'

# Skip heavy GUI work under memory pressure (the spike itself is ~100 MB).
$freeKb = [int64](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory
if ($freeKb -lt 2.5GB / 1KB) {
    "SKIP chrome-spike: free RAM $([math]::Round($freeKb / 1MB, 2)) GB < 2.5 GB"
    return
}

Add-Type -AssemblyName System.Drawing
if (-not ('ChromeSpike.Native' -as [type])) {
    Add-Type -Namespace ChromeSpike -Name Native -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
[StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
[DllImport("user32.dll")] public static extern bool GetMonitorInfoW(IntPtr m, ref MONITORINFO mi);
"@
}
# Physical pixels everywhere (CopyFromScreen, window rects, cursor positions).
[void][ChromeSpike.Native]::SetProcessDpiAwarenessContext([IntPtr]-4)

$script:Failed = [System.Collections.Generic.List[string]]::new()

function Out-Result([string]$Line) {
    Write-Host $Line
    Add-Content -LiteralPath $Results -Value $Line -Encoding UTF8
}

# A recorded check: a failing one fails the scenario at its end, a measurement
# (ok = $null) is only recorded.
function Add-Check([string]$Scenario, [string]$Name, $Ok, [string]$Detail) {
    $tag = if ($null -eq $Ok) { 'INFO' } elseif ($Ok) { 'CHECK-PASS' } else { 'CHECK-FAIL' }
    Out-Result "$tag [$Scenario] ${Name}: $Detail"
    if ($null -ne $Ok -and -not $Ok) { $script:Failed.Add("$Name ($Detail)") }
}

function Read-SpikeLog([string]$Path) {
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { '' }
}

function Wait-LogMatch([string]$Path, [string]$Pattern, [int]$TimeoutMs = 15000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $m = [regex]::Match((Read-SpikeLog $Path), $Pattern)
        if ($m.Success) { return $m }
        Start-Sleep -Milliseconds 50
    }
    throw "timeout waiting for /$Pattern/ in $Path"
}

function Start-Spike([string]$Scenario, [string]$Variant, [bool]$NoButtons, [bool]$Reparent, [int]$Seconds, [bool]$Plain = $false, [int]$Sync = 1, [string[]]$Extra = @()) {
    $log = Join-Path $ShotsDir "spike-$Scenario.log"
    # A log left by an earlier run would satisfy the 'ready' wait with a dead hwnd.
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    $argList = @("--variant=$Variant", "--seconds=$Seconds", "--log=$log")
    if ($NoButtons) { $argList += '--no-buttons' }
    if ($Reparent) { $argList += '--reparent' }
    if ($Plain) { $argList += '--plain' }
    if ($Sync -ne 1) { $argList += "--sync=$Sync" }
    $argList += $Extra
    $proc = Start-Process -FilePath $Exe -ArgumentList $argList -PassThru
    $s = [pscustomobject]@{ Proc = $proc; Log = $log; Hwnd = [IntPtr]::Zero; Geo = $null }
    [void](Wait-LogMatch $log 'ready')
    $text = Read-SpikeLog $log
    $m = [regex]::Match($text, 'window name=a hwnd=0x([0-9a-f]+)')
    $s.Hwnd = [IntPtr][Convert]::ToInt64($m.Groups[1].Value, 16)
    $s.Geo = Get-Geometry $text 'a'
    $s
}

function Get-Geometry([string]$Text, [string]$Name) {
    $ms = [regex]::Matches($Text, "geometry name=$Name dpi=(\d+) client=(-?\d+),(-?\d+),(\d+),(\d+) window=(-?\d+),(-?\d+),(-?\d+),(-?\d+) strip_h=(\d+) button_w=(\d+) tab=(\d+),(\d+),(\d+),(\d+) inset=(\d+)")
    if ($ms.Count -eq 0) { return $null }
    $g = $ms[$ms.Count - 1].Groups
    [pscustomobject]@{
        Dpi = [int]$g[1].Value; StripH = [int]$g[10].Value; ButtonW = [int]$g[11].Value
        Tab = @([int]$g[12].Value, [int]$g[13].Value, [int]$g[14].Value, [int]$g[15].Value)
        Inset = [int]$g[16].Value
    }
}

function Stop-Spike($Spike) {
    if ($null -eq $Spike) { return }
    $p = $Spike.Proc
    $p.Refresh()
    if (-not $p.HasExited) {
        if ([ChromeSpike.Native]::IsWindow($Spike.Hwnd)) {
            [void][ChromeSpike.Native]::PostMessageW($Spike.Hwnd, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
        }
        if (-not $p.WaitForExit(5000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
}

function Get-ClientInfo([IntPtr]$Hwnd) {
    $wr = New-Object ChromeSpike.Native+RECT
    $cr = New-Object ChromeSpike.Native+RECT
    $o = New-Object ChromeSpike.Native+POINT
    [void][ChromeSpike.Native]::GetWindowRect($Hwnd, [ref]$wr)
    [void][ChromeSpike.Native]::GetClientRect($Hwnd, [ref]$cr)
    [void][ChromeSpike.Native]::ClientToScreen($Hwnd, [ref]$o)
    [pscustomobject]@{ Wr = $wr; W = $cr.right; H = $cr.bottom; X = $o.x; Y = $o.y }
}

# Copies the window rectangle off the screen. Pixel (x, y) of the client area
# is bitmap pixel (Ox + x, Oy + y).
# With -ChildRgb and -StripH the capture is verified before anything is
# written: the child area must show that colour at its corners and centre,
# otherwise another window overlaps the spike (the owner works on the same
# desktop) and the capture is discarded unsaved.
function Save-Capture([IntPtr]$Hwnd, [string]$Path, $ChildRgb = $null, [int]$StripH = 0) {
    $ci = Get-ClientInfo $Hwnd
    $w = $ci.Wr.right - $ci.Wr.left
    $h = $ci.Wr.bottom - $ci.Wr.top
    if ($w -le 0 -or $h -le 0 -or $w -gt 8000 -or $h -gt 8000) {
        throw "bad window rect for 0x$($Hwnd.ToString('x')): $($ci.Wr.left),$($ci.Wr.top),$($ci.Wr.right),$($ci.Wr.bottom) IsWindow=$([ChromeSpike.Native]::IsWindow($Hwnd))"
    }
    $bmp = New-Object Drawing.Bitmap($w, $h, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    try {
        $g.CopyFromScreen($ci.Wr.left, $ci.Wr.top, 0, 0, (New-Object Drawing.Size($w, $h)))
    } finally { $g.Dispose() }
    $cap = [pscustomobject]@{ Bmp = $bmp; Ox = $ci.X - $ci.Wr.left; Oy = $ci.Y - $ci.Wr.top; W = $ci.W; H = $ci.H; Path = $Path }
    if ($ChildRgb) {
        $mx = $cap.W - 20
        $my = $cap.H - 20
        # The top-right corner is left out: the snap layouts flyout opens there.
        $pts = @(@([int]($cap.W / 2), [int](($StripH + $cap.H) / 2)), @(20, ($StripH + 20)), @(20, $my), @([int]($cap.W / 2), $my), @($mx, $my))
        foreach ($pt in $pts) {
            if (-not (Test-Near (Get-Px $cap $pt[0] $pt[1]) $ChildRgb 2)) {
                $bmp.Dispose()
                throw "capture of 0x$($Hwnd.ToString('x')) is obscured (child pixel at $($pt[0]),$($pt[1]) is not $(Format-Px $ChildRgb)); not saved"
            }
        }
    }
    if ($Path) {
        # Saved cropped to the client area: the window rectangle also holds the
        # invisible resize borders, which show whatever is behind the window.
        $crop = $bmp.Clone((New-Object Drawing.Rectangle($cap.Ox, $cap.Oy, $cap.W, $cap.H)), $bmp.PixelFormat)
        try { $crop.Save($Path, [Drawing.Imaging.ImageFormat]::Png) } finally { $crop.Dispose() }
    }
    $cap
}

function Get-Px($Cap, [int]$X, [int]$Y) {
    $c = $Cap.Bmp.GetPixel($Cap.Ox + $X, $Cap.Oy + $Y)
    , @([int]$c.R, [int]$c.G, [int]$c.B)
}

function Test-Near($Px, $Expect, [int]$Tol) {
    for ($i = 0; $i -lt 3; $i++) { if ([math]::Abs($Px[$i] - $Expect[$i]) -gt $Tol) { return $false } }
    $true
}

function Format-Px($Px) { '#{0:X2}{1:X2}{2:X2}' -f $Px[0], $Px[1], $Px[2] }

# Pixels in a client-space box whose brightest channel exceeds a threshold
# (text and glyph ink on the dark strip).
function Get-InkCount($Cap, [int]$L, [int]$T, [int]$R, [int]$B, [int]$Min = 140) {
    $n = 0
    for ($y = $T; $y -lt $B; $y++) {
        for ($x = $L; $x -lt $R; $x++) {
            $c = $Cap.Bmp.GetPixel($Cap.Ox + $x, $Cap.Oy + $y)
            if ([math]::Max([math]::Max($c.R, $c.G), $c.B) -gt $Min) { $n++ }
        }
    }
    $n
}

function Move-CursorTo([int]$X, [int]$Y) { [void][ChromeSpike.Native]::SetCursorPos($X, $Y) }

function Wait-SinceStart($Spike, [int]$Ms) {
    $left = $Ms - ((Get-Date) - $Spike.Proc.StartTime).TotalMilliseconds
    if ($left -gt 0) { Start-Sleep -Milliseconds ([int]$left) }
}

function Get-PrivateMb($Spike) {
    $p = Get-Process -Id $Spike.Proc.Id
    [math]::Round($p.PrivateMemorySize64 / 1MB, 2)
}

# Samples shared by every non-reparent scenario: the strip shows the backdrop,
# the child shows its swap chain colour.
function Test-StripAndChild([string]$Sc, $Cap, $Geo, [string]$Label, $ChildRgb = @(16, 32, 48)) {
    $bgX = $Cap.W - 3 * $Geo.ButtonW - 60
    $bg = Get-Px $Cap $bgX ([int]($Geo.StripH / 2))
    $kid = Get-Px $Cap ([int]($Cap.W / 2)) ($Geo.StripH + [int](($Cap.H - $Geo.StripH) / 2))
    $black = Test-Near $bg @(0, 0, 0) 0
    $childLike = Test-Near $bg @(16, 32, 48) 4
    Add-Check $Sc "$Label strip background is the backdrop" ((-not $black) -and (-not $childLike)) "pixel $(Format-Px $bg) at client ($bgX,$([int]($Geo.StripH / 2)))"
    Add-Check $Sc "$Label child shows $(Format-Px $ChildRgb)" (Test-Near $kid $ChildRgb 2) "pixel $(Format-Px $kid)"
    $bg
}

# Frames per second the child presented, from the spike log (ready -> done).
function Get-Fps([string]$Text) {
    $r = [regex]::Match($Text, '\[\s*(\d+)\] ready')
    $d = [regex]::Match($Text, '\[\s*(\d+)\] done frames=(\d+)')
    if (-not ($r.Success -and $d.Success)) { return 'n/a' }
    $sec = ([int]$d.Groups[1].Value - [int]$r.Groups[1].Value) / 1000.0
    '{0:N1} fps ({1} frames in {2:N1} s), slow presents (>200 ms): {3}' -f ([int]$d.Groups[2].Value / $sec), $d.Groups[2].Value, $sec, ([regex]::Matches($Text, 'slow_present')).Count
}

function Invoke-Run([string]$Sc, [string]$Variant, [bool]$NoButtons, [string[]]$Extra = @()) {
    $spike = $null
    $cursor = New-Object ChromeSpike.Native+POINT
    [void][ChromeSpike.Native]::GetCursorPos([ref]$cursor)
    try {
        $spike = Start-Spike $Sc $Variant $NoButtons $false 40 $false 1 $Extra
        $geo = $spike.Geo
        $fg = Set-ForegroundSafe -Hwnd $spike.Hwnd
        Add-Check $Sc 'window is foreground' $fg ''
        Start-Sleep -Milliseconds 1200

        $cap1 = Save-Capture $spike.Hwnd (Join-Path $ShotsDir "$Sc.png") @(16, 32, 48) $geo.StripH
        $bg1 = Test-StripAndChild $Sc $cap1 $geo 'idle'

        if ($Variant -eq 'dc') {
            $inkTab = Get-InkCount $cap1 ($geo.Tab[0] + 8) $geo.Tab[1] ($geo.Tab[2] - 8) $geo.Tab[3]
            Add-Check $Sc 'tab text pixels present' ($inkTab -ge 20) "$inkTab bright pixels in the tab"
            if (-not $NoButtons) {
                $names = @('min', 'max', 'close')
                for ($i = 0; $i -lt 3; $i++) {
                    $l = $cap1.W - (3 - $i) * $geo.ButtonW
                    $n = Get-InkCount $cap1 $l 0 ($l + $geo.ButtonW) $geo.StripH
                    Add-Check $Sc "caption glyph '$($names[$i])' pixels present" ($n -ge 6) "$n bright pixels"
                }
            }
        }

        Wait-SinceStart $spike 5000
        $mb = Get-PrivateMb $spike
        Out-Result "RAM [$Sc] variant=$Variant private_mb=$mb (5 s after launch)"
        Add-Content -LiteralPath (Join-Path $ShotsDir 'ram.txt') -Value "$Sc variant=$Variant private_mb=$mb" -Encoding UTF8

        # Hover the maximize button for 1 s, then capture again (snap layouts
        # flyout visible = manual look).
        $ci = Get-ClientInfo $spike.Hwnd
        $hx = $ci.X + $cap1.W - [int](1.5 * $geo.ButtonW)
        $hy = $ci.Y + [int]($geo.StripH / 2)
        Move-CursorTo ($hx - 40) $hy
        Start-Sleep -Milliseconds 200
        Move-CursorTo ($hx - 3) $hy
        Start-Sleep -Milliseconds 100
        Move-CursorTo $hx $hy
        Start-Sleep -Milliseconds 1200
        $cap2 = Save-Capture $spike.Hwnd (Join-Path $ShotsDir "$Sc-hover.png") @(16, 32, 48) $geo.StripH
        Out-Result "INFO [$Sc] hover shot: $($cap2.Path) (cursor at $hx,$hy)"

        if ($NoButtons) {
            # (a) no DWM-drawn ghost buttons in the top-right 3 x 46 px caption
            # area: every pixel of the area equals the strip background of its
            # row (+-6), with and without hover. The area stops short of the
            # window's rounded top-right corner.
            $x0 = $cap1.W - 3 * $geo.ButtonW
            $x1 = $cap1.W - 12
            foreach ($state in @(@($cap1, 'without'), @($cap2, 'with'))) {
                $cap = $state[0]
                $bad = 0
                $worst = 0
                for ($y = 2; $y -lt $geo.StripH; $y++) {
                    $ref = Get-Px $cap ($x0 - 60) $y
                    for ($x = $x0; $x -lt $x1; $x++) {
                        $px = Get-Px $cap $x $y
                        $d = [math]::Max([math]::Max([math]::Abs($px[0] - $ref[0]), [math]::Abs($px[1] - $ref[1])), [math]::Abs($px[2] - $ref[2]))
                        if ($d -gt 6) { $bad++ }
                        $worst = [math]::Max($worst, $d)
                    }
                }
                Add-Check $Sc "(a) caption area equals the strip background $($state[1]) hover" ($bad -eq 0) "$bad pixels differ by more than 6 (worst delta $worst)"
            }
        } else {
            $bg2 = Get-Px $cap2 ($cap2.W - [int](1.5 * $geo.ButtonW)) ([int]($geo.StripH / 2))
            $bg1m = Get-Px $cap1 ($cap1.W - [int](1.5 * $geo.ButtonW)) ([int]($geo.StripH / 2))
            Add-Check $Sc 'hover over the max button, pixel at the glyph' $null "idle $(Format-Px $bg1m) -> hover $(Format-Px $bg2)"
        }
        Move-CursorTo ($ci.X + [int]($cap1.W / 2)) ($ci.Y + $geo.StripH + 100)

        if ($Variant -eq 'dc' -and -not $NoButtons) {
            # (b) maximized under Mica.
            [void][ChromeSpike.Native]::ShowWindow($spike.Hwnd, 3)
            Start-Sleep -Milliseconds 1200
            $ci = Get-ClientInfo $spike.Hwnd
            $mon = New-Object ChromeSpike.Native+MONITORINFO
            $mon.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'ChromeSpike.Native+MONITORINFO')
            $hmon = [ChromeSpike.Native]::MonitorFromWindow($spike.Hwnd, 2)
            [void][ChromeSpike.Native]::GetMonitorInfoW($hmon, [ref]$mon)
            $m = $mon.rcMonitor
            $inset = $geo.Inset
            $wr = $ci.Wr
            $inside = ($wr.left -ge $m.left - $inset) -and ($wr.top -ge $m.top - $inset) -and ($wr.right -le $m.right + $inset) -and ($wr.bottom -le $m.bottom + $inset)
            Add-Check $Sc '(b) maximized window rect inside monitor + frame inset' $inside "window $($wr.left),$($wr.top),$($wr.right),$($wr.bottom) monitor $($m.left),$($m.top),$($m.right),$($m.bottom) inset $inset"
            Add-Check $Sc '(b) maximized client top is on screen' ($ci.Y -ge $m.top -and $ci.Y -lt $m.top + $geo.StripH) "client top y=$($ci.Y), monitor top=$($m.top), zoomed=$([ChromeSpike.Native]::IsZoomed($spike.Hwnd))"
            $cap3 = Save-Capture $spike.Hwnd (Join-Path $ShotsDir "$Sc-maximized.png") @(16, 32, 48) $geo.StripH
            [void](Test-StripAndChild $Sc $cap3 $geo 'maximized')
            [void][ChromeSpike.Native]::ShowWindow($spike.Hwnd, 9)
            Start-Sleep -Milliseconds 500
        }
    } finally {
        Move-CursorTo $cursor.x $cursor.y
        Stop-Spike $spike
    }
    $text = Read-SpikeLog $spike.Log
    $done = [regex]::Match($text, 'done frames=(\d+) occluded=(\d+) errors=(\d+)')
    Add-Check $Sc 'child presented without DXGI errors' ($done.Success -and $done.Groups[3].Value -eq '0') $done.Value
    Add-Check $Sc 'present rate' $null (Get-Fps $text)
}

# Control run: ordinary frame, no Mica, no custom caption. Isolates what the
# chrome costs in RAM and present rate.
function Invoke-Plain([string]$Sc, [int]$Sync = 1) {
    $spike = $null
    try {
        $spike = Start-Spike $Sc 'none' $false $false 40 $true $Sync
        [void](Set-ForegroundSafe -Hwnd $spike.Hwnd)
        Wait-SinceStart $spike 5000
        $mb = Get-PrivateMb $spike
        Out-Result "RAM [$Sc] variant=plain private_mb=$mb (5 s after launch)"
        Add-Content -LiteralPath (Join-Path $ShotsDir 'ram.txt') -Value "$Sc variant=plain private_mb=$mb" -Encoding UTF8
        Start-Sleep -Milliseconds 1500
    } finally {
        Stop-Spike $spike
    }
    Add-Check $Sc 'present rate' $null (Get-Fps (Read-SpikeLog $spike.Log))
}

function Invoke-Reparent([string]$Sc, [string[]]$Extra = @(), [bool]$Harsh = $false) {
    $spike = $null
    try {
        $spike = Start-Spike $Sc 'dc' $false $true 40 $false 1 $Extra
        $fg = Set-ForegroundSafe -Hwnd $spike.Hwnd
        Add-Check $Sc 'window A is foreground' $fg ''
        Start-Sleep -Milliseconds 800
        $capA = Save-Capture $spike.Hwnd (Join-Path $ShotsDir "$Sc-before.png") @(16, 32, 48) $spike.Geo.StripH
        $kid = Get-Px $capA ([int]($capA.W / 2)) ($spike.Geo.StripH + 100)
        Add-Check $Sc 'before: child in A shows #102030' (Test-Near $kid @(16, 32, 48) 2) "pixel $(Format-Px $kid)"

        $m = Wait-LogMatch $spike.Log 'reparent prev=0x([0-9a-f]+) last_error=(\d+) frames_before=(\d+) child_parent=0x([0-9a-f]+)' 12000
        $t0 = [Diagnostics.Stopwatch]::StartNew()
        $text = Read-SpikeLog $spike.Log
        $bm = [regex]::Match($text, 'window name=b hwnd=0x([0-9a-f]+)')
        $hwndB = [IntPtr][Convert]::ToInt64($bm.Groups[1].Value, 16)
        $geoB = Get-Geometry $text 'b'
        Add-Check $Sc 'SetParent returned the previous parent A' ($m.Groups[1].Value -eq ('{0:x}' -f [int64]$spike.Hwnd)) "prev=0x$($m.Groups[1].Value) last_error=$($m.Groups[2].Value) child_parent=0x$($m.Groups[4].Value) B=0x$($bm.Groups[1].Value)"

        # Poll B until its child shows the new clear colour.
        $matchMs = -1
        $px = $null
        while ($t0.ElapsedMilliseconds -lt 1500) {
            $capB = Save-Capture $hwndB $null
            $px = Get-Px $capB ([int]($capB.W / 2)) ($geoB.StripH + 100)
            $capB.Bmp.Dispose()
            if (Test-Near $px @(32, 48, 16) 2) { $matchMs = $t0.ElapsedMilliseconds; break }
            Start-Sleep -Milliseconds 60
        }
        Add-Check $Sc '(c) child in B shows #203010 within 1 s of SetParent' ($matchMs -ge 0 -and $matchMs -le 1000) "first match after $matchMs ms (last pixel $(Format-Px $px))"

        Start-Sleep -Milliseconds 500
        $c1 = Save-Capture $hwndB (Join-Path $ShotsDir "$Sc-after.png") @(32, 48, 16) $geoB.StripH
        $p1 = Get-Px $c1 ([int]($c1.W / 2)) ($geoB.StripH + 100)
        Start-Sleep -Milliseconds 500
        $c2 = Save-Capture $hwndB $null
        $p2 = Get-Px $c2 ([int]($c2.W / 2)) ($geoB.StripH + 100)
        Add-Check $Sc '(c) two captures 500 ms apart both show #203010' ((Test-Near $p1 @(32, 48, 16) 2) -and (Test-Near $p2 @(32, 48, 16) 2)) "$(Format-Px $p1) then $(Format-Px $p2)"
        [void](Test-StripAndChild $Sc (Save-Capture $hwndB $null) $geoB 'B' @(32, 48, 16))

        if (-not $Harsh) {
            # A's visible left sliver must no longer show the child.
            $capA2 = Save-Capture $spike.Hwnd $null
            $left = Get-Px $capA2 10 300
            Add-Check $Sc 'child left window A (sliver of A no longer #102030/#203010)' (-not ((Test-Near $left @(16, 32, 48) 4) -or (Test-Near $left @(32, 48, 16) 4))) "pixel $(Format-Px $left)"
        } else {
            # A is destroyed, then B is resized so the child's swap chain runs ResizeBuffers.
            [void](Wait-LogMatch $spike.Log 'destroyed_a frames=(\d+)' 8000)
            Add-Check $Sc 'window A destroyed' (-not [ChromeSpike.Native]::IsWindow($spike.Hwnd)) "IsWindow(A)=$([ChromeSpike.Native]::IsWindow($spike.Hwnd))"
            $spike.Hwnd = $hwndB   # Stop-Spike closes through B
            [void](Wait-LogMatch $spike.Log 'resized frames=(\d+)' 8000)
            $logNow = Read-SpikeLog $spike.Log
            $fAt = [int][regex]::Match($logNow, 'resized frames=(\d+)').Groups[1].Value
            Start-Sleep -Milliseconds 800
            $ciB = Get-ClientInfo $hwndB
            Add-Check $Sc 'B resized (child gets a new size)' ($ciB.W -gt ($c1.W + 100)) "client $($c1.W)x$($c1.H) -> $($ciB.W)x$($ciB.H)"
            $r1 = Save-Capture $hwndB (Join-Path $ShotsDir "$Sc-resized.png") @(32, 48, 16) $geoB.StripH
            Add-Check $Sc 'after destroy A + resize: child area (corners and centre) shows #203010' $true "5 sample points verified, client $($r1.W)x$($r1.H)"
            Start-Sleep -Milliseconds 500
            $r2 = Save-Capture $hwndB $null @(32, 48, 16) $geoB.StripH
            Add-Check $Sc 'after resize: second capture 500 ms later still #203010' $true "5 sample points verified"
            Start-Sleep -Milliseconds 700
            $sm = [regex]::Matches((Read-SpikeLog $spike.Log), 'stat frames=(\d+)')
            $fLater = [int]$sm[$sm.Count - 1].Groups[1].Value
            Add-Check $Sc 'frames rising after resize' ($fLater -gt $fAt + 5) "frames at resize $fAt, later $fLater"
        }

        Start-Sleep -Milliseconds 1500
    } finally {
        Stop-Spike $spike
    }
    $text = Read-SpikeLog $spike.Log
    $rep = [regex]::Match($text, '\[\s*(\d+)\] reparent prev=.*frames_before=(\d+)')
    $ready = [regex]::Match($text, '\[\s*(\d+)\] ready')
    $done = [regex]::Match($text, '\[\s*(\d+)\] done frames=(\d+) occluded=(\d+) errors=(\d+) first_error=0x([0-9a-f]+)')
    $after = [int]$done.Groups[2].Value - [int]$rep.Groups[2].Value
    $fpsBefore = [int]$rep.Groups[2].Value / (([int]$rep.Groups[1].Value - [int]$ready.Groups[1].Value) / 1000.0)
    $fpsAfter = $after / (([int]$done.Groups[1].Value - [int]$rep.Groups[1].Value) / 1000.0)
    Add-Check $Sc '(c) frames kept presenting after SetParent at the same rate' (($after -ge 10) -and ($fpsAfter -ge 0.5 * $fpsBefore)) ('frames before={0} after={1}; {2:N1} fps before, {3:N1} fps after' -f $rep.Groups[2].Value, $after, $fpsBefore, $fpsAfter)
    Add-Check $Sc '(c) no DXGI error in the spike log' ($done.Success -and $done.Groups[4].Value -eq '0' -and $text -notmatch 'present_error') $done.Value
}

$plan = @(
    @{ Name = 'none'; Run = { Invoke-Run 'none' 'none' $false } }
    @{ Name = 'dc'; Run = { Invoke-Run 'dc' 'dc' $false } }
    @{ Name = 'none-nobuttons'; Run = { Invoke-Run 'none-nobuttons' 'none' $true } }
    @{ Name = 'nobuttons-nosysmenu'; Run = { Invoke-Run 'nobuttons-nosysmenu' 'none' $true @('--style-off=sysmenu') } }
    @{ Name = 'nobuttons-nocaption'; Run = { Invoke-Run 'nobuttons-nocaption' 'none' $true @('--style-off=caption') } }
    @{ Name = 'reparent-destroy-resize'; Run = { Invoke-Reparent 'reparent-destroy-resize' @('--destroy-a', '--resize') $true } }
    @{ Name = 'dc-nosysmenu'; Run = { Invoke-Run 'dc-nosysmenu' 'dc' $false @('--style-off=sysmenu') } }
    @{ Name = 'reparent'; Run = { Invoke-Reparent 'reparent' } }
    @{ Name = 'plain'; Run = { Invoke-Plain 'plain' } }
    @{ Name = 'plain-sync0'; Run = { Invoke-Plain 'plain-sync0' 0 } }
    @{ Name = 'none2'; Run = { Invoke-Run 'none2' 'none' $false } }
    @{ Name = 'dc2'; Run = { Invoke-Run 'dc2' 'dc' $false } }
)

foreach ($step in $plan) {
    if ($Only.Count -gt 0 -and $Only -notcontains $step.Name) { continue }
    $script:Failed.Clear()
    $run = $step.Run
    Invoke-GuiScenario -Name "chrome-spike-$($step.Name)" -ScriptBlock {
        & $run
        if ($script:Failed.Count -gt 0) { throw ($script:Failed -join '; ') }
    }
}
