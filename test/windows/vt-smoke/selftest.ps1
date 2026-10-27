# Self-test of lib\ImageCompare.psm1 (Compare-Image). Windows PowerShell 5.1.
#   powershell -NoProfile -File test/windows/vt-smoke/selftest.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\lib\ImageCompare.psm1') -Force
Add-Type -AssemblyName System.Drawing

$dir = Join-Path $env:TEMP ('vts-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$fail = 0
function Check([string]$What, [bool]$Ok) {
    if ($Ok) { Write-Host "PASS $What" } else { Write-Host "FAIL $What"; $script:fail++ }
}
function New-Png([string]$Path, [int]$W, [int]$H, [int]$X = -1, [int]$Y = -1, [int]$Gray = 0) {
    $b = New-Object System.Drawing.Bitmap $W, $H, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $g = [System.Drawing.Graphics]::FromImage($b)
        $g.Clear([System.Drawing.Color]::FromArgb(255, 16, 32, 48))
        $g.Dispose()
        if ($X -ge 0) { $b.SetPixel($X, $Y, [System.Drawing.Color]::FromArgb(255, 16 + $Gray, 32, 48)) }
        $b.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $b.Dispose() }
}
try {
    $a = Join-Path $dir 'a.png'; $b = Join-Path $dir 'b.png'; $c = Join-Path $dir 'c.png'
    New-Png $a 40 30
    New-Png $b 40 30
    New-Png $c 40 30 5 7 200

    $r = Compare-Image -Actual $a -Reference $b
    Check 'identical: Match 1.0' ($r.Match -eq 1.0 -and $r.MaxDiff -eq 0 -and $r.MeanDiff -eq 0)

    $r = Compare-Image -Actual $c -Reference $a -MinMatch 1.0
    Check 'one pixel at 200: MaxDiff 200' ($r.MaxDiff -eq 200)
    Check 'one pixel at 200: Match < 1' ($r.Match -lt 1.0)
    Check 'one pixel at 200: DiffPng written' ($r.DiffPng -and (Test-Path -LiteralPath $r.DiffPng))

    $r = Compare-Image -Actual $c -Reference $a -Tolerance 255
    Check 'tolerance 255 hides it' ($r.Match -eq 1.0 -and $r.MaxDiff -eq 200)

    $d = Join-Path $dir 'd.png'
    New-Png $d 41 30
    $threw = $false
    try { [void](Compare-Image -Actual $d -Reference $a) } catch { $threw = $true }
    Check 'size mismatch throws' $threw
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "selftest FAILED ($fail)"; exit 1 }
Write-Host 'selftest PASS'
