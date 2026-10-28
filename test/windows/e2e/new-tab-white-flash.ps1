# e2e: milestone=M5 timeout=300 order=312
# new-tab-white-flash: tabs opened in a quick burst (before any Git Bash
# prompt) in a translucent window must show the terminal background from
# their first visible frame, never the bare glass. The window is
# `background-opacity = 0.85` without blur over a white backdrop window of
# our own, so bare glass reads white while the terminal background
# (#1a2b4c at 85 %) reads dark blue. A capture thread copies the terminal
# area as fast as it can while four `new_tab` actions run back to back; a
# frame whose sampled pixels are mostly near white (all channels >= 200)
# counts as a flash. Three runs, each with 0 white frames.
# GHOSTTY_E2E_FLASH_RUNS overrides the run count.
# Status: PENDING (M5): written while the desktop was busy, not run yet.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_backdrop.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

if (-not ('GhosttyE2e.WhiteFlashProbe' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Threading;
namespace GhosttyE2e {
public class WhiteFlashProbe {
    public List<double> Times = new List<double>();
    public List<double> WhiteFrac = new List<double>();
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
                int white = 0, n = 0;
                for (int row = 0; row < h; row += 9) {
                    byte* p = (byte*)d.Scan0 + row * d.Stride;
                    for (int col = 0; col < w; col += 9) {
                        byte* q = p + col * 4;
                        n++;
                        if (q[0] >= 200 && q[1] >= 200 && q[2] >= 200) white++;
                    }
                }
                bmp.UnlockBits(d);
                Times.Add(sw.Elapsed.TotalMilliseconds);
                WhiteFrac.Add(n == 0 ? 0 : (double)white / n);
            }
        }
    }
}
}
"@ -CompilerParameters (New-Object System.CodeDom.Compiler.CompilerParameters (,[string[]]@("System.dll","System.Drawing.dll")) -Property @{ CompilerOptions = "/unsafe" })
}

Invoke-E2eScenario 'new-tab-white-flash' {
    Assert-TransparencyEffects
    $runs = if ($env:GHOSTTY_E2E_FLASH_RUNS) { [int]$env:GHOSTTY_E2E_FLASH_RUNS } else { 3 }
    $burst = 4
    $back = New-BackdropForm 60 60 1500 1000
    $back.BackColor = [Drawing.Color]::FromArgb(255, 255, 255)
    try {
        Show-BackdropForm $back
        $g = Start-E2eGhostty -ConfigText "background = #1a2b4c`nforeground = #e0e0e0`nbackground-opacity = 0.85`nbackground-blur = false`nconfirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = always`n"
        try {
            if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "no frame dump at $($g.Dump)" }
            Move-Window $g.Hwnd 160 160 1000 700
            [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
            Start-Sleep -Milliseconds 1000
            $comp = (Get-GhosttyState -Class $g.Class).m3.composition
            if ($comp.mode -ne 'composition') { throw "mode is $($comp.mode), expected composition" }

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

                $probe = New-Object GhosttyE2e.WhiteFlashProbe
                # The probe only counts white pixels (nothing is saved); a foreign window would skew it.
                Assert-CaptureRectClear ($origin.X + 4) ($origin.Y + $top) $w $h
                $probe.Start($origin.X + 4, $origin.Y + $top, $w, $h)
                try {
                    Start-Sleep -Milliseconds 300
                    for ($i = 0; $i -lt $burst; $i++) {
                        [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
                        Start-Sleep -Milliseconds 60
                    }
                    $ok = Wait-Until -TimeoutSec 10 -PollMs 50 -Condition {
                        $x = @((Get-GhosttyState -Class $g.Class).windows)[0]
                        if (@($x.tabs).Count -eq $count + $burst) { $x }
                    }
                    Start-Sleep -Milliseconds 700
                } finally {
                    $probe.Stop()
                }
                if (-not $ok) { throw "run ${run}: the $burst new tabs did not appear" }
                $n = $probe.WhiteFrac.Count
                $white = 0
                $first = -1
                for ($i = 0; $i -lt $n; $i++) {
                    if ($probe.WhiteFrac[$i] -gt 0.5) {
                        $white++
                        if ($first -lt 0) { $first = [Math]::Round($probe.Times[$i]) }
                    }
                }
                Write-E2eInfo ("run {0}: {1} frames, {2} white, first white at {3} ms" -f $run, $n, $white, $first)
                if ($n -lt 20) { throw "run ${run}: only $n frames captured" }
                if ($white -ne 0) { throw "run ${run}: $white white frames of $n" }
            }
        } finally {
            if (-not $g.Process.HasExited) {
                $g.Process.Kill()
                [void]$g.Process.WaitForExit(5000)
            }
        }
    } finally {
        $back.Close()
    }
}
