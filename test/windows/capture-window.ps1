<#
.SYNOPSIS
Captures a window with PrintWindow(PW_RENDERFULLCONTENT) into a PNG and
optionally prints the colour of one pixel.

.DESCRIPTION
PW_RENDERFULLCONTENT asks DWM for the composed content, so flip-model
swap chains (which GDI cannot read) come out. Prints SKIP and exits 0 when
the session is locked or non-interactive (Harness rules); never touches
focus or input.

.PARAMETER Hwnd
Window handle, decimal or 0x-prefixed hex (as printed by launch.ps1).

.PARAMETER Out
PNG file to write.

.PARAMETER Probe
Optional "x,y" client pixel; prints "probe x,y = #rrggbb".
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
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
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

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
    $bitmap.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    "saved $Out (${width}x${height})"

    if ($Probe) {
        $x, $y = $Probe -split ',' | ForEach-Object { [int]$_.Trim() }
        $c = $bitmap.GetPixel($x, $y)
        'probe {0},{1} = #{2:x2}{3:x2}{4:x2}' -f $x, $y, $c.R, $c.G, $c.B
    }
} finally {
    $bitmap.Dispose()
}
