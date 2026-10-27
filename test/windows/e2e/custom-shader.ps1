# e2e: milestone=M3 timeout=180 order=530
# custom-shader: the invert shader inverts the background; a broken shader is
# logged and rendering stays normal; an animated shader changes the frame with
# custom-shader-animation = true; with false the idle CPU of the process stays
# within 0.5 % of a run without a shader (recorded).
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'custom-shader' {
    $invert = (Join-Path (Split-Path -Parent $PSScriptRoot) 'vt-smoke\shaders\invert.glsl').Replace([char]92, [char]47)
    $dir = $script:Sbx.Tmp
    $broken = (Join-Path $dir 'broken.glsl').Replace([char]92, [char]47)
    $anim = (Join-Path $dir 'anim.glsl').Replace([char]92, [char]47)
    Set-Content -LiteralPath $broken -Value 'void mainImage(out vec4 c, in vec2 p) { c = this is not glsl; }' -Encoding ASCII
    Set-Content -LiteralPath $anim -Encoding ASCII -Value @'
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 c = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = vec4(c.rgb * (0.5 + 0.5 * sin(iTime * 6.0)), c.a);
}
'@

    function Start-Phase([string]$Extra) {
        Stop-OwnGhostty
        Remove-Item -LiteralPath (Join-Path $script:Sbx.Dump 'surface-1.bmp') -Force -ErrorAction SilentlyContinue
        Start-BashE2e -ExtraConfig $Extra
    }
    function Get-Bg($G) {
        $d = Wait-Dump $G { param($d) $d.Width -gt 20 }
        if (-not $d) { throw 'no frame dump' }
        Get-DumpPixel $d ($d.Width - 6) ($d.Height - 6)
    }
    function Get-CpuSec($G, [double]$Seconds) {
        $G.Process.Refresh()
        $a = $G.Process.TotalProcessorTime.TotalSeconds
        Start-Sleep -Seconds $Seconds
        $G.Process.Refresh()
        ($G.Process.TotalProcessorTime.TotalSeconds - $a) / $Seconds
    }

    # 1. invert
    $g = Start-Phase "custom-shader = $invert"
    Start-Sleep -Seconds 1
    $p = Get-Bg $g
    if (-not (Test-PixelNear $p @(0xEF, 0xDF, 0xCF) 3)) { throw "invert: background $(Format-Pixel $p), want #efdfcf" }
    Write-E2eInfo "invert background $(Format-Pixel $p)"

    # 2. broken shader: normal rendering, error logged, no crash
    $g = Start-Phase "custom-shader = $broken"
    Start-Sleep -Seconds 1
    $p = Get-Bg $g
    if (-not (Test-PixelNear $p @(0x10, 0x20, 0x30) 3)) { throw "broken: background $(Format-Pixel $p), want #102030" }
    $g.Process.Refresh()
    if ($g.Process.HasExited) { throw 'ghostty exited with a broken custom shader' }
    $log = if (Test-Path $g.Log) { Get-Content -LiteralPath $g.Log -Raw } else { '' }
    if ($log -notmatch 'custom shader') { throw 'the broken shader was not reported in the log' }

    # 3. animation on: frames differ over 1 s
    $g = Start-Phase "custom-shader = $anim`ncustom-shader-animation = true"
    Start-Sleep -Seconds 1
    $seen = @{}
    for ($i = 0; $i -lt 10; $i++) {
        $seen[(Format-Pixel (Get-Bg $g))] = $true
        Start-Sleep -Milliseconds 100
    }
    if ($seen.Count -lt 2) { throw 'animation = true: the frame did not change over 1 s' }

    # 4. animation off: idle CPU vs. no shader (recorded)
    $g = Start-Phase ''
    Start-Sleep -Seconds 2
    $base = Get-CpuSec $g 10
    $g = Start-Phase "custom-shader = $anim`ncustom-shader-animation = false"
    Start-Sleep -Seconds 2
    $with = Get-CpuSec $g 10
    Write-E2eInfo ('idle cpu: no shader {0:P2}, shader (animation=false) {1:P2}' -f $base, $with)
    if ($with - $base -gt 0.005) { throw ('animation = false idles {0:P2} vs {1:P2} without a shader' -f $with, $base) }
}
