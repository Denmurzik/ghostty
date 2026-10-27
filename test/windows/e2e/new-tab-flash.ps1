# e2e: milestone=M2 timeout=240 order=310
# new-tab-flash: opening a new tab must not flash the terminal area black.
# A capture thread copies the surface area of the screen as fast as it can
# while `new_tab` runs through the test IPC; every frame is classified as
# black (most sampled pixels near #000000) or not. The configured
# background is a dark blue, so black is told apart from it. Three runs,
# each with 0 black frames. GHOSTTY_E2E_FLASH_RUNS overrides the run count.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

if (-not ('GhosttyE2e.FlashProbe' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Threading;
namespace GhosttyE2e {
public class FlashProbe {
    public List<double> Times = new List<double>();
    public List<double> BlackFrac = new List<double>();
    volatile bool stop;
    Thread thread;
    int x, y, w, h;
    public void Start(int x, int y, int w, int h) {
        this.x = x; this.y = y; this.w = w; this.h = h;
        stop = false;
        thread = new Thread(Run);
        thread.IsBackground = true;
        thread.Start();
    }
    public void Stop() { stop = true; thread.Join(); }
    unsafe void Run() {
        Stopwatch sw = Stopwatch.StartNew();
        using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        using (Graphics g = Graphics.FromImage(bmp)) {
            while (!stop) {
                g.CopyFromScreen(x, y, 0, 0, new Size(w, h));
                BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                int black = 0, n = 0;
                for (int row = 0; row < h; row += 9) {
                    byte* p = (byte*)d.Scan0 + row * d.Stride;
                    for (int col = 0; col < w; col += 9) {
                        byte* q = p + col * 4;
                        n++;
                        if (q[0] <= 6 && q[1] <= 6 && q[2] <= 6) black++;
                    }
                }
                bmp.UnlockBits(d);
                Times.Add(sw.Elapsed.TotalMilliseconds);
                BlackFrac.Add(n == 0 ? 0 : (double)black / n);
            }
        }
    }
}
}
"@ -CompilerParameters (New-Object System.CodeDom.Compiler.CompilerParameters (,[string[]]@("System.dll","System.Drawing.dll")) -Property @{ CompilerOptions = "/unsafe" })
}

Invoke-E2eScenario 'new-tab-flash' {
    $runs = if ($env:GHOSTTY_E2E_FLASH_RUNS) { [int]$env:GHOSTTY_E2E_FLASH_RUNS } else { 3 }
    $g = Start-E2eGhostty -ConfigText "background = #1a2b4c`nforeground = #e0e0e0`nconfirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = always`n"
    try {
        if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "no frame dump at $($g.Dump)" }
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        Start-Sleep -Milliseconds 800

        for ($run = 1; $run -le $runs; $run++) {
            $st = @((Get-GhosttyState -Class $g.Class).windows)[0]
            $count = @($st.tabs).Count
            $origin = New-Object GhosttyE2e.Mouse+POINT
            [void][GhosttyE2e.Mouse]::ClientToScreen($g.Hwnd, [ref]$origin)
            $rc = New-Object GhosttyE2e.Win+RECT
            [void][GhosttyE2e.Win]::GetClientRect($g.Hwnd, [ref]$rc)
            $top = [int]$st.strip.bounds[3] + 4
            $w = $rc.Right - 8
            $h = $rc.Bottom - $top - 4

            $probe = New-Object GhosttyE2e.FlashProbe
            # The probe only counts black pixels (nothing is saved); a foreign window would skew it.
            Assert-CaptureRectClear ($origin.X + 4) ($origin.Y + $top) $w $h
            $probe.Start($origin.X + 4, $origin.Y + $top, $w, $h)
            try {
                Start-Sleep -Milliseconds 300
                [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
                $ok = Wait-Until -TimeoutSec 8 -PollMs 50 -Condition {
                    $x = @((Get-GhosttyState -Class $g.Class).windows)[0]
                    if (@($x.tabs).Count -eq $count + 1) { $x }
                }
                Start-Sleep -Milliseconds 700
            } finally {
                $probe.Stop()
            }
            if (-not $ok) { throw "run ${run}: the new tab did not appear" }
            $n = $probe.BlackFrac.Count
            $black = 0
            for ($i = 0; $i -lt $n; $i++) { if ($probe.BlackFrac[$i] -gt 0.5) { $black++ } }
            $partial = 0
            for ($i = 0; $i -lt $n; $i++) { if ($probe.BlackFrac[$i] -gt 0.02 -and $probe.BlackFrac[$i] -le 0.5) { $partial++ } }
            $first = -1
            for ($i = 0; $i -lt $n; $i++) { if ($probe.BlackFrac[$i] -gt 0.5) { $first = [Math]::Round($probe.Times[$i]); break } }
            Write-E2eInfo ("run {0}: {1} frames, {2} black, {3} partly black, first black at {4} ms" -f $run, $n, $black, $partial, $first)
            if ($n -lt 20) { throw "run ${run}: only $n frames captured" }
            if ($black -ne 0) { throw "run ${run}: $black black frames of $n" }
        }
    } finally {
        if (-not $g.Process.HasExited) {
            $g.Process.Kill()
            [void]$g.Process.WaitForExit(5000)
        }
    }
}
