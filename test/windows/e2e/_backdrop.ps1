# Helpers of the transparency scenarios: a backdrop window of our own behind
# Ghostty (so translucency is measurable by pixel), screen-rect capture
# (PrintWindow does not see the backdrop) and a blur measure. Dot-source after
# _common.ps1. ASCII only.
if (-not ('GhosttyE2e.BackdropDpi' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name BackdropDpi -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
"@
}
# Physical pixels everywhere (window rects, CopyFromScreen, WinForms bounds).
[void][GhosttyE2e.BackdropDpi]::SetProcessDpiAwarenessContext([IntPtr](-4))
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('GhosttyE2e.BackdropNative' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name BackdropNative -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int value, int size);
"@
}

# A borderless form with a solid magenta colour or red/green stripes (6 px).
# Show it with Show-BackdropForm; it is ours, so it may take the foreground.
function New-BackdropForm([int]$X, [int]$Y, [int]$W, [int]$H, [switch]$Stripes) {
    $f = New-Object Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.ShowInTaskbar = $false
    $f.StartPosition = 'Manual'
    $f.Bounds = New-Object Drawing.Rectangle $X, $Y, $W, $H
    if ($Stripes) {
        $bmp = New-Object Drawing.Bitmap $W, $H
        $gfx = [Drawing.Graphics]::FromImage($bmp)
        try {
            $red = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 0, 0))
            $green = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(0, 255, 0))
            for ($yy = 0; $yy -lt $H; $yy += 6) {
                $b = if ((($yy / 6) % 2) -eq 0) { $red } else { $green }
                $gfx.FillRectangle($b, 0, $yy, $W, 6)
            }
        } finally { $gfx.Dispose() }
        $f.BackgroundImage = $bmp
    } else {
        $f.BackColor = [Drawing.Color]::FromArgb(255, 0, 255)
    }
    $f
}

function Show-BackdropForm($F) {
    $F.Show()
    $F.Refresh()
    # The first paint of a fresh form can lag under load: white backdrops fail the checks.
    Invoke-Pump 800
    $F.Refresh()
    Invoke-Pump 200
}

function Invoke-Pump([int]$Ms) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 15
    }
}

function Get-ScreenBitmap([int]$X, [int]$Y, [int]$W, [int]$H) {
    $bmp = New-Object Drawing.Bitmap $W, $H
    $gfx = [Drawing.Graphics]::FromImage($bmp)
    try { $gfx.CopyFromScreen($X, $Y, 0, 0, (New-Object Drawing.Size $W, $H)) } finally { $gfx.Dispose() }
    $bmp
}

function Get-ScreenPixel([int]$X, [int]$Y) {
    $b = Get-ScreenBitmap $X $Y 1 1
    try { $b.GetPixel(0, 0) } finally { $b.Dispose() }
}

function Format-Color([Drawing.Color]$C) { '#{0:x2}{1:x2}{2:x2}' -f $C.R, $C.G, $C.B }

# Screen position of a client point of a window.
function Get-ClientScreenPoint([IntPtr]$Hwnd, [int]$X, [int]$Y) {
    $p = New-Object GhosttyE2e.BackdropNative+POINT
    $p.X = $X
    $p.Y = $Y
    [void][GhosttyE2e.BackdropNative]::ClientToScreen($Hwnd, [ref]$p)
    , @($p.X, $p.Y)
}

# Luminance standard deviation down the middle column of a bitmap: ~64 for
# unblurred red/green stripes, near 0 when they are blurred.
function Get-LumaSpread([Drawing.Bitmap]$Bmp) {
    $n = 0
    $sum = 0.0
    $sq = 0.0
    for ($y = 0; $y -lt $Bmp.Height; $y += 1) {
        $c = $Bmp.GetPixel([int]($Bmp.Width / 2), $y)
        $l = 0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B
        $n++
        $sum += $l
        $sq += $l * $l
    }
    $m = $sum / $n
    [Math]::Sqrt([Math]::Max($sq / $n - $m * $m, 0))
}

function Test-ColorNear([Drawing.Color]$C, [int[]]$Rgb, [int]$Tol) {
    ([Math]::Abs($C.R - $Rgb[0]) -le $Tol) -and ([Math]::Abs($C.G - $Rgb[1]) -le $Tol) -and ([Math]::Abs($C.B - $Rgb[2]) -le $Tol)
}

# Moves/sizes a top-level window (physical pixels) without changing z-order.
function Move-Window([IntPtr]$Hwnd, [int]$X, [int]$Y, [int]$W, [int]$H) {
    # SWP_NOZORDER | SWP_NOACTIVATE
    [void][GhosttyE2e.BackdropNative]::SetWindowPos($Hwnd, [IntPtr]::Zero, $X, $Y, $W, $H, 0x4 -bor 0x10)
}

# Takes the foreground away from Ghostty without covering it: a small window
# of ours far to the right. Returns the form (close it when done).
function Switch-AwayFromGhostty($G) {
    # On the monitor of the window, away from it.
    $area = [Windows.Forms.Screen]::FromHandle($G.Hwnd).Bounds
    $f = New-BackdropForm ($area.Right - 240) ($area.Top + 100) 200 200
    Show-BackdropForm $f
    if (-not (Set-ForegroundSafe -Hwnd $f.Handle)) { $f.Close(); throw 'E2E-SKIP: could not take the foreground' }
    Invoke-Pump 1200
    if ([GhosttyE2e.Win]::GetForegroundWindow() -eq $G.Hwnd) { $f.Close(); throw 'Ghostty is still the foreground window' }
    $f
}

# Skips the scenario when Windows "Transparency effects" is off (Acrylic and the
# frosted look need it). Read only.
function Assert-TransparencyEffects {
    $v = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name EnableTransparency -ErrorAction SilentlyContinue).EnableTransparency
    if ($null -ne $v -and $v -eq 0) { throw 'E2E-SKIP: Windows Transparency effects are off' }
}
