<#
.SYNOPSIS
Captures the client area of a window with PrintWindow(PW_RENDERFULLCONTENT)
into a PNG and optionally prints the colour of one pixel.

.DESCRIPTION
PW_RENDERFULLCONTENT asks DWM for the composed content, so flip-model
swap chains (which GDI cannot read) come out. Prints SKIP and exits 0 when
the session is locked or non-interactive (Harness rules); never touches
focus or input. PrintWindow renders the whole window rectangle, including
the invisible DWM resize borders, title bar and frame; the bitmap is
cropped to the client area so it lines up with a frame dump.

.PARAMETER Hwnd
Window handle, decimal or 0x-prefixed hex (as printed by launch.ps1).

.PARAMETER Out
PNG file to write.

.PARAMETER Probe
Optional "x,y" pixel in client coordinates (0,0 = top-left of the client
area); prints "probe x,y = #rrggbb".
#>
param(
    [Parameter(Mandatory)][string]$Hwnd,
    [Parameter(Mandatory)][string]$Out,
    [string]$Probe
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\Harness.psm1')

if (-not (Test-InteractiveSession)) {
    "SKIP capture-window: $(Get-SkipReason)"
    return
}

Add-Type -AssemblyName System.Drawing
if (-not ('GhosttyCapture.Native' -as [type])) {
    Add-Type -Namespace GhosttyCapture -Name Native -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT pt);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
"@
}

$handle = [IntPtr][Convert]::ToInt64($Hwnd, $(if ($Hwnd -like '0x*') { 16 } else { 10 }))
$rect = New-Object GhosttyCapture.Native+RECT
if (-not [GhosttyCapture.Native]::GetWindowRect($handle, [ref]$rect)) {
    throw "GetWindowRect failed for $Hwnd"
}
$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
if ($width -le 0 -or $height -le 0) { throw "window $Hwnd has no size ($width x $height)" }

# The client area inside the window bitmap (whose origin is the window rect's).
$client = New-Object GhosttyCapture.Native+RECT
$origin = New-Object GhosttyCapture.Native+POINT
if (-not [GhosttyCapture.Native]::GetClientRect($handle, [ref]$client) -or
    -not [GhosttyCapture.Native]::ClientToScreen($handle, [ref]$origin)) {
    throw "GetClientRect failed for $Hwnd"
}
$cw = $client.Right - $client.Left
$ch = $client.Bottom - $client.Top
if ($cw -le 0 -or $ch -le 0) { throw "window $Hwnd has no client area ($cw x $ch)" }
$cx = $origin.X - $rect.Left
$cy = $origin.Y - $rect.Top

$PW_RENDERFULLCONTENT = 2
$bitmap = New-Object System.Drawing.Bitmap $width, $height
try {
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $hdc = $graphics.GetHdc()
        try {
            if (-not [GhosttyCapture.Native]::PrintWindow($handle, $hdc, $PW_RENDERFULLCONTENT)) {
                throw "PrintWindow failed for $Hwnd"
            }
        } finally {
            $graphics.ReleaseHdc($hdc)
        }
    } finally {
        $graphics.Dispose()
    }

    $cropped = $bitmap.Clone(
        (New-Object System.Drawing.Rectangle $cx, $cy, $cw, $ch),
        $bitmap.PixelFormat)
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
        $cropped.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
        "saved $Out (client ${cw}x${ch})"

        if ($Probe) {
            $x, $y = $Probe -split ',' | ForEach-Object { [int]$_.Trim() }
            if ($x -lt 0 -or $y -lt 0 -or $x -ge $cw -or $y -ge $ch) {
                throw "probe $x,$y is outside the client area (${cw}x${ch})"
            }
            $c = $cropped.GetPixel($x, $y)
            'probe {0},{1} = #{2:x2}{3:x2}{4:x2}' -f $x, $y, $c.R, $c.G, $c.B
        }
    } finally {
        $cropped.Dispose()
    }
} finally {
    $bitmap.Dispose()
}
