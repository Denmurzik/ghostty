# e2e: milestone=M8 timeout=300 order=1220
# hidden-render: a surface that is not on screen draws nothing, costs no CPU,
# and comes back flash-free. pwsh panes on the bundled ConPTY (the inbox one
# drops Kitty APC); the animation is vt-smoke/cases/kitty-anim.sh (frame 1
# magenta, frame 2 green, 100 ms, looping, 8x4 cells at row 0 col 0). Reads the
# test IPC surface fields `core_visible`, `presents` (successful presents of
# the surface's renderer) and `chain_px` (the swap chain size, [1,1] while a
# hidden surface holds no back buffers). A build without `presents` SKIPs.
#  1. tab 1 plays the animation.
#  2. visible: `presents` grows >= 8/s and both colours show in the frame dump
#     (else R-M8-40 is reported; the hidden checks still run). The CPU of the
#     process over 3 s is logged as the reference.
#  3. new_tab: over 3 s tab 1 `presents` is constant, core_visible = false,
#     chain_px = [1,1] (when the swap chain shrink is enabled: R-M8-21; a chain that\n#     keeps its visible size is reported as "shrink disabled", not a failure),\n#     and ghostty.exe uses < 5 % of one core.
#  4. goto_tab:1: within 200 ms `presents` grows, a fresh frame dump shows
#     magenta or green in the image cells, and the rate is back to >= 8/s.
#  5. minimize: `presents` constant, chain_px unchanged (the chain is kept
#     for DWM previews); restore.
#  6. tab 2 floods (`for /L`, then fills the screen red) while hidden: `presents`
#     constant until the flood is done; after goto_tab:2 the screen shows the
#     tail (red), not the stale or an empty frame.
#  7. reshow flash check (background #102030): tab 2 (red) and tab 3 (full of
#     M), 20 switches, a CopyFromScreen probe sampling the terminal area as fast
#     as it can and a capture-window.ps1 capture after every switch: no frame
#     that is neither tab's content (a uniform background or stretched frame).
#  8. GHOSTTY_E2E_HIDDEN_DEBUG=1 runs the whole
#     scenario with GHOSTTY_D3D11_DEBUG=1 (the debug layer).
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GpuCounters.psm1') -Force

if (-not ('GhosttyE2e.HidRender' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name HidRender -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
'@
}
if (-not ('GhosttyE2e.ReshowProbe' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Threading;
namespace GhosttyE2e {
public class ReshowProbe {
    public List<double> Times = new List<double>();
    public List<double> Bg = new List<double>();
    public List<double> Red = new List<double>();
    volatile bool stop;
    Thread thread;
    int x, y, w, h;

    // {share of pixels near the #102030 background, share of reddish pixels}
    // over a grid (every 9th pixel) of the region.
    public static unsafe double[] Measure(Bitmap bmp, int rx, int ry, int rw, int rh) {
        BitmapData d = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        int n = 0, nb = 0, nr = 0;
        for (int row = ry; row < ry + rh && row < bmp.Height; row += 9) {
            byte* p = (byte*)d.Scan0 + row * d.Stride;
            for (int col = rx; col < rx + rw && col < bmp.Width; col += 9) {
                byte* q = p + col * 4;
                int b = q[0], g = q[1], r = q[2];
                n++;
                if (Math.Abs(r - 16) <= 6 && Math.Abs(g - 32) <= 6 && Math.Abs(b - 48) <= 6) nb++;
                if (r - g > 60 && r - b > 60) nr++;
            }
        }
        bmp.UnlockBits(d);
        return new double[] { n == 0 ? 0 : (double)nb / n, n == 0 ? 0 : (double)nr / n };
    }

    public static double[] MeasureFile(string path, int rx, int ry, int rw, int rh) {
        using (Bitmap src = new Bitmap(path))
        using (Bitmap c = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb)) {
            using (Graphics g = Graphics.FromImage(c)) g.DrawImage(src, 0, 0, src.Width, src.Height);
            return Measure(c, rx, ry, rw, rh);
        }
    }

    public void Start(int x, int y, int w, int h) {
        this.x = x; this.y = y; this.w = w; this.h = h;
        stop = false;
        thread = new Thread(Run);
        thread.IsBackground = true;
        thread.Start();
    }
    public void Stop() { stop = true; thread.Join(); }

    void Run() {
        Stopwatch sw = Stopwatch.StartNew();
        using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        using (Graphics g = Graphics.FromImage(bmp)) {
            while (!stop) {
                g.CopyFromScreen(x, y, 0, 0, new Size(w, h));
                double[] m = Measure(bmp, 0, 0, w, h);
                Times.Add(sw.Elapsed.TotalMilliseconds);
                Bg.Add(m[0]);
                Red.Add(m[1]);
            }
        }
    }
}
}
"@ -CompilerParameters (New-Object System.CodeDom.Compiler.CompilerParameters (,[string[]]@("System.dll", "System.Drawing.dll")) -Property @{ CompilerOptions = "/unsafe" })
}

$script:SW_MINIMIZE = 6
$script:SW_RESTORE = 9

function Get-AppState($G) {
    $st = Get-GhosttyState -Class $G.Class
    if ($st.PSObject.Properties['data']) { $st.data } else { $st }
}

# The first surface of the tab at `$Index` (0-based) of the first window.
function Get-TabSurface($G, [int]$Index) {
    $win = @((Get-AppState $G).windows)[0]
    @(@($win.tabs)[$Index].surfaces)[0]
}

function Get-Field($Obj, [string]$Name) {
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { $Obj.$Name } else { $null }
}

function Get-Presents($G, [int]$Tab) {
    $v = Get-Field (Get-TabSurface $G $Tab) 'presents'
    if ($null -eq $v) { throw 'E2E-SKIP: the surface state has no `presents` field (a build without Task 15)' }
    [uint64]$v
}

# The swap chain size [w, h] of a tab's surface, or $null (no field).
function Get-ChainPx($G, [int]$Tab) {
    $v = Get-Field (Get-TabSurface $G $Tab) 'chain_px'
    if ($null -eq $v) { return $null }
    , @([int]$v[0], [int]$v[1])
}

function Wait-CoreVisible($G, [int]$Tab, [bool]$Want, [string]$What, [double]$TimeoutSec = 2) {
    $ok = Wait-Until -TimeoutSec $TimeoutSec -PollMs 40 -Condition {
        $s = Get-TabSurface $G $Tab
        $null -ne $s -and ([bool]$s.core_visible) -eq $Want
    }
    if (-not $ok) { throw "core_visible of tab $($Tab + 1) did not become $Want ($What): $((Get-TabSurface $G $Tab) | ConvertTo-Json -Compress -Depth 4)" }
}

function Wait-TabCount($G, [int]$Count) {
    $ok = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { @(@((Get-AppState $G).windows)[0].tabs).Count -eq $Count }
    if (-not $ok) { throw "the window did not reach $Count tabs" }
}

# Share of grid pixels of a frame dump region of one kind: magenta (#ff00ff),
# green (#00ff00) within 24, or reddish (red well above green and blue).
function Measure-Share($D, [string]$Kind, [int]$X0, [int]$Y0, [int]$W, [int]$H, [int]$Step = 4) {
    $W = [Math]::Min($W, $D.Width - $X0)
    $H = [Math]::Min($H, $D.Height - $Y0)
    $hit = 0
    $n = 0
    for ($y = $Y0; $y -lt $Y0 + $H; $y += $Step) {
        $row = if ($D.TopDown) { $y } else { $D.Height - 1 - $y }
        for ($x = $X0; $x -lt $X0 + $W; $x += $Step) {
            $i = 54 + ($row * $D.Width + $x) * 4
            $b = [int]$D.Bytes[$i]; $g = [int]$D.Bytes[$i + 1]; $r = [int]$D.Bytes[$i + 2]
            $n++
            $ok = $false
            if ($Kind -eq 'magenta') { $ok = ($r -ge 231 -and $g -le 24 -and $b -ge 231) }
            elseif ($Kind -eq 'green') { $ok = ($r -le 24 -and $g -ge 231 -and $b -le 24) }
            elseif ($Kind -eq 'red') { $ok = (($r - $g) -gt 60 -and ($r - $b) -gt 60) }
            if ($ok) { $hit++ }
        }
    }
    if ($n) { $hit / [double]$n } else { 0.0 }
}

# 'magenta', 'green' or $null: the colour of the 8x4-cell image rectangle.
function Get-AnimColor($D, [int[]]$Cell) {
    $w = 8 * $Cell[0]; $h = 4 * $Cell[1]
    if ((Measure-Share $D 'magenta' 0 0 $w $h 3) -ge 0.9) { return 'magenta' }
    if ((Measure-Share $D 'green' 0 0 $w $h 3) -ge 0.9) { return 'green' }
    $null
}

# CPU of ghostty.exe over `$Seconds` as a percentage of one core, and the
# presents of a tab's surface over the same time.
function Measure-Window($G, [int]$Tab, [double]$Seconds) {
    $p0 = Get-Presents $G $Tab
    $c0 = Get-CpuSeconds $G.Process
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds ([int]($Seconds * 1000))
    $wall = $sw.Elapsed.TotalSeconds
    $c1 = Get-CpuSeconds $G.Process
    $p1 = Get-Presents $G $Tab
    [pscustomobject]@{
        Presents0 = $p0; Presents1 = $p1
        Delta     = [int64]($p1 - $p0)
        Rate      = ([double]($p1 - $p0)) / $wall
        CpuCore   = ConvertTo-CpuPercent -CpuSeconds ($c1 - $c0) -WallSeconds $wall
        Seconds   = $wall
    }
}

# Types a line into the pwsh of the focused tab until a marker file proves the
# shell runs our lines (the pty buffers input typed ahead).
function Wait-PwshReady($G, [string]$Name, [double]$TimeoutSec = 40) {
    $marker = Join-Path $G.Sandbox.Tmp "$Name.ready"
    $fwd = $marker -replace '\\', '/'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Send-Line $G.Hwnd ("Set-Content -LiteralPath '$fwd' -Value ready")
        if (Wait-File $marker 6) { return }
    }
    throw "pwsh ($Name) did not run a typed line within $TimeoutSec s"
}

Invoke-E2eScenario 'hidden-render' {
    $tmp = $script:Sbx.Tmp
    $tmpFwd = $tmp -replace '\\', '/'
    $bash = Find-GitBash
    if (-not $bash) { throw 'E2E-SKIP: Git Bash is not installed (kitty-anim.sh plays the animation)' }
    $animSh = (Join-Path $script:WinDir 'vt-smoke\cases\kitty-anim.sh') -replace '\\', '/'
    if (-not (Test-Path -LiteralPath $animSh)) { throw "missing $animSh" }
    $debug = ($env:GHOSTTY_E2E_HIDDEN_DEBUG -eq '1')

    # pwsh panes: bundled ConPTY (Kitty APC), no blinking cursor (a blink would present while visible),
    # no padding (the image rectangle starts at pixel 0,0).
    $cfg = $script:BaseConfig + "command = direct:powershell.exe -NoProfile -NoLogo`nwindows-conpty = bundled`ncursor-style-blink = false`nwindow-padding-x = 0`nwindow-padding-y = 0`nwindow-padding-balance = false`n"
    $env1 = @{ TMUX = $null; TMUX_PANE = $null }
    if ($debug) { $env1['GHOSTTY_D3D11_DEBUG'] = '1'; Write-E2eInfo 'GHOSTTY_D3D11_DEBUG=1 (the debug layer is on)' }
    $g = Start-E2eGhostty -ConfigText $cfg -Env $env1
    Set-WindowLayout $g.Hwnd '00000409'
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)

    # 1. Tab 1 plays the animation.
    Wait-PwshReady $g 'tab1'
    $done = Join-Path $tmp 'anim.done'
    Send-Line $g.Hwnd ('$env:VTS_DONE = ''' + $tmpFwd + '/anim.done''; & ''' + $bash + ''' ''' + $animSh + '''')
    if (-not (Wait-File $done 30)) { throw 'the animation script never ran in tab 1' }
    $cell = $null
    $st = Wait-Until -TimeoutSec 15 -PollMs 150 -Condition {
        $w = @((Get-AppState $g).windows)[0]
        if ($w -and [int]$w.cell[0] -gt 0 -and [int]$w.cell[1] -gt 0) { $w }
    }
    if (-not $st) { throw 'no cell size in the state' }
    $cell = @([int]$st.cell[0], [int]$st.cell[1])
    [void](Get-Presents $g 0)   # SKIPs a build without the field
    Write-E2eInfo "cell $($cell[0])x$($cell[1]); chain_px of tab 1: $(((Get-ChainPx $g 0) -join 'x'))"

    # 2. Visible: the animation drives the presents.
    $seen = @{}
    $cpuVisible = $null
    # Frames and presents in one 3 s window.
    $p0 = Get-Presents $g 0
    $c0 = Get-CpuSeconds $g.Process
    $swV = [Diagnostics.Stopwatch]::StartNew()
    while ($swV.Elapsed.TotalSeconds -lt 3) {
        if (Test-Path -LiteralPath $g.Dump) {
            $d = Read-Dump $g.Dump
            if ($d) { $c = Get-AnimColor $d $cell; if ($c) { $seen[$c] = $true } }
        }
        Start-Sleep -Milliseconds 100
    }
    $wallV = $swV.Elapsed.TotalSeconds
    $c1 = Get-CpuSeconds $g.Process
    $p1 = Get-Presents $g 0
    $rateV = ([double]($p1 - $p0)) / $wallV
    $cpuVisible = ConvertTo-CpuPercent -CpuSeconds ($c1 - $c0) -WallSeconds $wallV
    Write-E2eInfo ('visible animation (reference): {0:N1} presents/s, ghostty.exe CPU {1:N1} % of one core, colours seen: {2}' -f $rateV, $cpuVisible, $(if ($seen.Count) { ($seen.Keys | Sort-Object) -join '+' } else { 'none' }))
    Save-Evidence -Tag 'visible' -G $g -Window
    $imageSeen = [bool]$seen.Count
    $animAdvances = ($rateV -ge 8) -and ($seen.Count -ge 2)
    if (-not $animAdvances) {
        Write-E2eInfo ('R-M8-40: the animation does not advance while visible ({0:N1} presents/s, colours: {1}); the hidden checks still run' -f $rateV, $(if ($seen.Count) { ($seen.Keys | Sort-Object) -join '+' } else { 'none' }))
    }

    # 3. New tab: tab 1 is hidden and renders nothing.
    $chainVisible = Get-ChainPx $g 0
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
    Wait-TabCount $g 2
    Wait-CoreVisible $g 0 $false 'tab 1 after new_tab'
    $cp = Get-ChainPx $g 0
    if ($null -eq $cp) {
        Write-E2eInfo 'chain_px is not in the surface state: the [1,1] check is skipped'
    } else {
        $ok = Wait-Until -TimeoutSec 3 -PollMs 100 -Condition { $c = Get-ChainPx $g 0; $c[0] -eq 1 -and $c[1] -eq 1 }
        if (-not $ok) {
            $now = Get-ChainPx $g 0
            if ($null -ne $chainVisible -and $now[0] -eq $chainVisible[0] -and $now[1] -eq $chainVisible[1]) {
                Write-E2eInfo ('swap chain shrink disabled: the hidden tab keeps its {0}x{1} chain (R-M8-21 gate dropped it?); the [1,1] check is skipped' -f $now[0], $now[1])
            } else {
                throw "tab 1 is hidden but its swap chain is $($now -join 'x') (visible: $($chainVisible -join 'x')), expected 1x1 or unchanged"
            }
        }
    }
    Start-Sleep -Milliseconds 500
    $h = Measure-Window $g 0 3
    Write-E2eInfo ('hidden animation: {0} presents in {1:N1} s, ghostty.exe CPU {2:N2} % of one core (visible reference {3:N1} %)' -f $h.Delta, $h.Seconds, $h.CpuCore, $cpuVisible)
    if ($h.Delta -ne 0) { throw "tab 1 is hidden but presented $($h.Delta) times in 3 s" }
    if ($h.CpuCore -ge 5) { throw ('ghostty.exe used {0:N1} % of one core with the animation hidden (limit 5 %)' -f $h.CpuCore) }
    $hiddenPresents = $h.Presents1
    Save-Evidence -Tag 'hidden' -G $g -Window

    # 4. Back to tab 1: it draws at once and the animation runs.
    Remove-Item -LiteralPath $g.Dump -ErrorAction SilentlyContinue
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'goto_tab:1')
    $ms = $null
    while ($sw.Elapsed.TotalMilliseconds -lt 2000) {
        if ((Get-Presents $g 0) -gt $hiddenPresents) { $ms = $sw.Elapsed.TotalMilliseconds; break }
    }
    if ($null -eq $ms) { throw 'tab 1 did not present within 2 s of goto_tab:1' }
    Write-E2eInfo ('goto_tab:1 -> first present after {0:N0} ms' -f $ms)
    if ($ms -gt 200) { throw ('tab 1 presented {0:N0} ms after goto_tab:1 (limit 200 ms)' -f $ms) }
    Wait-CoreVisible $g 0 $true 'tab 1 after goto_tab:1'
    if ($imageSeen) {
        $d = Wait-Dump $g {
            param($d)
            [bool](Get-AnimColor $d $cell)
        } 3
        if (-not $d) { throw 'goto_tab:1: no fresh frame dump with magenta or green in the image cells within 3 s' }
        Write-E2eInfo "goto_tab:1: the image cells are $(Get-AnimColor $d $cell)"
    } else {
        Write-E2eInfo 'goto_tab:1: image colour check skipped (the image never showed, see R-M8-40)'
    }
    if ($animAdvances) {
        Start-Sleep -Milliseconds 300
        $r = Measure-Window $g 0 1.5
        Write-E2eInfo ('after goto_tab:1: {0:N1} presents/s' -f $r.Rate)
        if ($r.Rate -lt 8) { throw ('the animation did not resume: {0:N1} presents/s after goto_tab:1 (expected >= 8)' -f $r.Rate) }
    }

    # 5. Minimized: no presents, the swap chain stays.
    $chainBefore = Get-ChainPx $g 0
    [void][GhosttyE2e.HidRender]::ShowWindowAsync($g.Hwnd, $script:SW_MINIMIZE)
    try {
        Wait-CoreVisible $g 0 $false 'tab 1 minimized' 3
        Start-Sleep -Milliseconds 1000
        $m = Measure-Window $g 0 2.5
        Write-E2eInfo ('minimized: {0} presents in {1:N1} s, CPU {2:N2} % of one core' -f $m.Delta, $m.Seconds, $m.CpuCore)
        if ($m.Delta -ne 0) { throw "the minimized window presented $($m.Delta) times in 2.5 s" }
        $chainMin = Get-ChainPx $g 0
        if ($null -ne $chainBefore) {
            if ($chainMin[0] -ne $chainBefore[0] -or $chainMin[1] -ne $chainBefore[1]) {
                throw "minimizing changed the swap chain: $($chainBefore -join 'x') -> $($chainMin -join 'x') (DWM previews need it)"
            }
        }
    } finally {
        [void][GhosttyE2e.HidRender]::ShowWindowAsync($g.Hwnd, $script:SW_RESTORE)
    }
    Wait-CoreVisible $g 0 $true 'tab 1 restored' 4
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
    Write-E2eInfo 'minimized: presents constant, chain unchanged; restored'

    # 6. A flood in a hidden tab: nothing is drawn; the tail is there on show.
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'goto_tab:2')
    Wait-CoreVisible $g 1 $true 'tab 2 shown'
    Wait-PwshReady $g 'tab2'
    $flood = Join-Path $tmp 'flood.done'
    $line = 'cmd /c "for /L %i in (1,1,1000000) do @echo %i"; [Console]::Write([string][char]27 + ''[41m'' + [string][char]27 + ''[2J''); Set-Content -LiteralPath ''' + $tmpFwd + '/flood.done'' -Value done'
    Send-Line $g.Hwnd $line
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'goto_tab:1')
    Wait-CoreVisible $g 1 $false 'tab 2 hidden while flooding'
    Start-Sleep -Milliseconds 300
    $swF = [Diagnostics.Stopwatch]::StartNew()
    $f0 = Get-Presents $g 1
    if (Test-Path -LiteralPath $flood) { throw 'the flood was over before it could be measured hidden (raise the line count)' }
    if (-not (Wait-File $flood 120)) { throw 'the hidden flood did not finish within 120 s' }
    $f1 = Get-Presents $g 1
    Write-E2eInfo ('hidden flood: done after {0:N1} s, tab 2 presents {1} -> {2}' -f $swF.Elapsed.TotalSeconds, $f0, $f1)
    if ($f1 -ne $f0) { throw "tab 2 is hidden but presented $($f1 - $f0) times during the flood" }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath (Get-DumpPath $g 2) -ErrorAction SilentlyContinue
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'goto_tab:2')
    $d2 = Wait-Dump ([pscustomobject]@{ Dump = (Get-DumpPath $g 2) }) {
        param($d)
        (Measure-Share $d 'red' 0 0 $d.Width $d.Height 16) -ge 0.8
    } 5
    Save-Evidence -Tag 'flood-shown' -G ([pscustomobject]@{ Dump = (Get-DumpPath $g 2) }) -Window -Hwnd $g.Hwnd
    if (-not $d2) { throw 'goto_tab:2: the screen of the flooded tab does not show the output tail (no red frame within 5 s)' }
    Write-E2eInfo 'hidden flood: the tail (red screen) is drawn after goto_tab:2'

    # 7. Reshow flash check: tab 2 (red) against tab 3 (full of M).
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
    Wait-TabCount $g 3
    Wait-CoreVisible $g 2 $true 'tab 3 shown'
    Wait-PwshReady $g 'tab3'
    Send-Line $g.Hwnd ('[Console]::Write(''M'' * 20000); Set-Content -LiteralPath ''' + $tmpFwd + '/m.done'' -Value done')
    if (-not (Wait-File (Join-Path $tmp 'm.done') 20)) { throw 'tab 3 never printed its M screen' }
    Start-Sleep -Milliseconds 800
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)

    $stw = @((Get-AppState $g).windows)[0]
    $sb = @($stw.strip.bounds)
    $top = [int]$sb[1] + [int]$sb[3] + 4
    $cs = Get-ClientSize $g.Hwnd
    $origin = New-Object GhosttyE2e.HidRender+POINT
    [void][GhosttyE2e.HidRender]::ClientToScreen($g.Hwnd, [ref]$origin)
    $pw = $cs.Width - 8
    $ph = $cs.Height - $top - 4
    $dirReshow = Join-Path $tmp 'reshow'
    New-Item -ItemType Directory -Force -Path $dirReshow | Out-Null
    $isContent = { param($Bg, $Red) ($Red -ge 0.85) -or (($Bg -ge 0.30) -and ($Bg -le 0.97) -and ($Red -lt 0.02)) }

    # Both tabs in steady state must classify as content (the classifier works).
    foreach ($t in 1, 2) {
        [void](Invoke-GhosttyAction -Class $g.Class -Action ('goto_tab:' + ($t + 1)))
        Wait-CoreVisible $g $t $true "tab $($t + 1) steady"
        Start-Sleep -Milliseconds 600
        $png = Join-Path $dirReshow "steady-$t.png"
        & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $script:CaptureWindow -Hwnd ('0x{0:X}' -f $g.Hwnd.ToInt64()) -Out $png 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $png)) { throw 'E2E-SKIP: capture-window.ps1 made no capture (locked or non-interactive session)' }
        $m = [GhosttyE2e.ReshowProbe]::MeasureFile($png, 4, $top, $pw, $ph)
        Write-E2eInfo ('steady tab {0}: background {1:P0}, red {2:P0}' -f ($t + 1), $m[0], $m[1])
        if (-not (& $isContent $m[0] $m[1])) { throw ('tab {0} in steady state is not classified as content (background {1:P0}, red {2:P0}): the flash check cannot tell frames apart' -f ($t + 1), $m[0], $m[1]) }
    }

    Assert-CaptureRectClear ($origin.X + 4) ($origin.Y + $top) $pw $ph
    $probe = New-Object GhosttyE2e.ReshowProbe
    $captures = @()
    $probe.Start($origin.X + 4, $origin.Y + $top, $pw, $ph)
    try {
        Start-Sleep -Milliseconds 300
        for ($i = 0; $i -lt 20; $i++) {
            $tab = if ($i % 2 -eq 0) { 1 } else { 2 }
            [void](Invoke-GhosttyAction -Class $g.Class -Action ('goto_tab:' + ($tab + 1)))
            Start-Sleep -Milliseconds 150
            $png = Join-Path $dirReshow ('switch-{0:D2}.png' -f $i)
            & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $script:CaptureWindow -Hwnd ('0x{0:X}' -f $g.Hwnd.ToInt64()) -Out $png 2>&1 | Out-Null
            if (Test-Path -LiteralPath $png) {
                $m = [GhosttyE2e.ReshowProbe]::MeasureFile($png, 4, $top, $pw, $ph)
                $captures += [pscustomobject]@{ Switch = $i; Tab = $tab + 1; Bg = $m[0]; Red = $m[1]; Ok = [bool](& $isContent $m[0] $m[1]); Png = $png }
            }
        }
        Start-Sleep -Milliseconds 300
    } finally {
        $probe.Stop()
    }
    $n = $probe.Bg.Count
    $flash = @()
    for ($i = 0; $i -lt $n; $i++) {
        if (-not (& $isContent $probe.Bg[$i] $probe.Red[$i])) { $flash += [pscustomobject]@{ T = [math]::Round($probe.Times[$i]); Bg = $probe.Bg[$i]; Red = $probe.Red[$i] } }
    }
    $badCaps = @($captures | Where-Object { -not $_.Ok })
    Write-E2eInfo ('reshow: {0} probe frames, {1} neither tab''s content; {2} of 20 captures, {3} neither tab''s content' -f $n, $flash.Count, $captures.Count, $badCaps.Count)
    if ($n -lt 40) { throw "the reshow probe captured only $n frames" }
    if ($captures.Count -lt 20) { throw "only $($captures.Count) of 20 window captures were made" }
    if ($badCaps.Count) {
        $b = $badCaps[0]
        Save-Evidence -Tag 'reshow-bad-capture' -G $g
        $ev = Get-EvidenceDir; if ($ev) { Copy-Item -LiteralPath $b.Png -Destination $ev -ErrorAction SilentlyContinue }
        throw ('{0} capture(s) after a tab switch show neither tab''s content, first: switch {1} to tab {2} (background {3:P0}, red {4:P0}) {5}' -f $badCaps.Count, $b.Switch, $b.Tab, $b.Bg, $b.Red, $b.Png)
    }
    if ($flash.Count) {
        $f = $flash[0]
        throw ('{0} of {1} probe frames show neither tab''s content, first at {2} ms (background {3:P0}, red {4:P0})' -f $flash.Count, $n, $f.T, $f.Bg, $f.Red)
    }

    # 8. The debug layer. Nothing routes its messages to ghostty.log (they go to the
    #    debugger), so this is not a pass/fail check: look at them with a debugger or
    #    DebugView on a GHOSTTY_E2E_HIDDEN_DEBUG=1 run.
    if ($debug) {
        Write-E2eInfo 'GHOSTTY_D3D11_DEBUG=1 was on, but the debug layer output is NOT captured here (it goes to the debugger, not ghostty.log): check it with DebugView'
    } else {
        Write-E2eInfo 'debug layer: not captured by this scenario (no log routing); GHOSTTY_E2E_HIDDEN_DEBUG=1 + DebugView for a look'
    }
}
