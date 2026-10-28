# e2e: milestone=M5 timeout=420 order=312
# new-tab-white-flash: panes opened in a quick burst (before any Git Bash
# prompt) in a translucent window must show the terminal background from
# their first visible frame, never the bare glass. The window is
# `background-opacity = 0.85` without blur over a white backdrop window of
# our own, so bare glass reads white while the terminal background
# (#1a2b4c at 85 %) reads dark blue. A capture thread copies the terminal
# area as fast as it can while a burst runs; a frame whose sampled pixels are
# mostly near white (all channels >= 200) counts as a flash. Phases, each
# with 0 white frames:
#   tabs    - four `new_tab` back to back (GHOSTTY_E2E_FLASH_RUNS times, 3)
#   splits  - three `new_split:right` back to back
#   window  - one `new_window` (cascaded over the first window)
#   theme   - tabs again with `theme = light:e2e-light,dark:e2e-dark`, the
#             light theme near white: the stand-in must take the dark one
#             (only on a dark system scheme; SKIP of the phase otherwise)
# A white frame is reported with the probe times of the `new_tab` calls, its
# log time (UTC, to match ghostty.log) and, with an evidence dir, the frame
# and the one before it as PNGs (only when every sampled point then showed
# a window of ours).
# RED/GREEN: point GHOSTTY_E2E_EXE at a build of the base (91ff7bac1) to see
# it fail, at the fix to see it pass (see flash-report.md, Fix round 1). The
# residual one-frame flash of a new tab container (flash2-report.md, base
# 297a91d6a) shows about once in 30 tabs: GHOSTTY_E2E_FLASH_RUNS=8 makes it
# show in most runs of the base.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_backdrop.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')
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
    // The first white frame and the one before it (evidence), and whether
    // only our own windows were at the sampled points when it was taken.
    public Bitmap FirstWhite, BeforeWhite;
    public bool WhiteClear;
    public DateTime StartUtc;
    public string WhiteOwners = "";
    public uint[] OwnPids = new uint[0];
    volatile bool stop;
    Thread thread;
    int x, y, w, h;
    Stopwatch sw;
    public double Now() { return sw == null ? 0 : sw.Elapsed.TotalMilliseconds; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct PT { public int X, Y; }
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr WindowFromPoint(PT p);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint f);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    bool OnlyOwn() {
        bool ok = true;
        var seen = new List<uint>();
        for (int i = 0; i < 8; i++) for (int j = 0; j < 6; j++) {
            PT p; p.X = x + (w - 1) * i / 7; p.Y = y + (h - 1) * j / 5;
            IntPtr hit = WindowFromPoint(p);
            if (hit == IntPtr.Zero) continue;
            IntPtr root = GetAncestor(hit, 2);
            if (root == IntPtr.Zero) root = hit;
            uint pid; GetWindowThreadProcessId(root, out pid);
            if (!seen.Contains(pid)) seen.Add(pid);
            if (Array.IndexOf(OwnPids, pid) < 0) ok = false;
        }
        WhiteOwners = string.Join(",", seen.ToArray());
        return ok;
    }
    public void Start(int x, int y, int w, int h) {
        this.x = x; this.y = y; this.w = w; this.h = h;
        stop = false;
        thread = new Thread(Run);
        thread.IsBackground = true;
        thread.Start();
    }
    public void Stop() { stop = true; thread.Join(); }
    unsafe void Run() {
        StartUtc = DateTime.UtcNow;
        sw = Stopwatch.StartNew();
        Bitmap prev = null;
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
                double frac = n == 0 ? 0 : (double)white / n;
                WhiteFrac.Add(frac);
                if (frac > 0.5 && FirstWhite == null) {
                    WhiteClear = OnlyOwn();
                    FirstWhite = (Bitmap)bmp.Clone();
                    BeforeWhite = prev;
                    prev = null;
                } else if (FirstWhite == null) {
                    if (prev != null) prev.Dispose();
                    prev = (Bitmap)bmp.Clone();
                }
            }
        }
        if (prev != null) prev.Dispose();
    }
}
}
"@ -CompilerParameters (New-Object System.CodeDom.Compiler.CompilerParameters (,[string[]]@("System.dll","System.Drawing.dll")) -Property @{ CompilerOptions = "/unsafe" })
}

if (-not ('GhosttyE2e.FlashZ' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name FlashZ -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
"@
}

# The terminal area of the first window (below the tab strip), in screen pixels.
function Get-TerminalRect($G) {
    $st = @((Get-GhosttyState -Class $G.Class).windows)[0]
    $origin = New-Object GhosttyE2e.Mouse+POINT
    [void][GhosttyE2e.Mouse]::ClientToScreen($G.Hwnd, [ref]$origin)
    $rc = New-Object GhosttyE2e.Win+RECT
    [void][GhosttyE2e.Win]::GetClientRect($G.Hwnd, [ref]$rc)
    $top = [int]$st.strip.bounds[3] + 4
    [pscustomobject]@{ X = $origin.X + 4; Y = $origin.Y + $top; W = $rc.Right - 8; H = $rc.Bottom - $top - 4 }
}

# Runs `$Burst` while the probe samples `$Rect`, waits for `$Done` to return
# something, and throws on any white frame.
function Measure-Burst($Label, $Rect, [scriptblock]$Burst, [scriptblock]$Done) {
    $probe = New-Object GhosttyE2e.WhiteFlashProbe
    $probe.OwnPids = [uint32[]]@($script:FlashOwnPids)
    $script:FlashProbe = $probe
    $script:FlashMarks = New-Object Collections.Generic.List[string]
    # A foreign window would skew the count; the first white frame is kept
    # only when the sampled points showed nothing but our windows then.
    Assert-CaptureRectClear $Rect.X $Rect.Y $Rect.W $Rect.H
    $probe.Start($Rect.X, $Rect.Y, $Rect.W, $Rect.H)
    try {
        Start-Sleep -Milliseconds 300
        & $Burst
        $ok = Wait-Until -TimeoutSec 10 -PollMs 50 -Condition $Done
        Start-Sleep -Milliseconds 700
    } finally {
        $probe.Stop()
    }
    if (-not $ok) { throw "${Label}: the new panes did not appear" }
    $n = $probe.WhiteFrac.Count
    $white = 0
    $first = -1
    for ($i = 0; $i -lt $n; $i++) {
        if ($probe.WhiteFrac[$i] -gt 0.5) {
            $white++
            if ($first -lt 0) { $first = [Math]::Round($probe.Times[$i]) }
        }
    }
    Write-E2eInfo ("{0}: {1} frames, {2} white, first white at {3} ms" -f $Label, $n, $white, $first)
    if ($white -ne 0) {
        $runs = @()
        for ($i = 0; $i -lt $n; $i++) { if ($probe.WhiteFrac[$i] -gt 0.5) { $runs += ('{0:N0}ms={1:N2}' -f $probe.Times[$i], $probe.WhiteFrac[$i]) } }
        $prevT = if ($first -ge 0) { ($probe.Times | Where-Object { $_ -lt $first } | Select-Object -Last 1) } else { $null }
        Write-E2eInfo ("{0}: white frames {1}; frame before at {2:N0} ms; actions {3}; owners at the first white frame {4} (clear {5}); log time {6} UTC; ghostty,runner pids {7}" -f $Label, ($runs -join ' '), $prevT, ($script:FlashMarks -join ' '), $probe.WhiteOwners, $probe.WhiteClear, $probe.StartUtc.AddMilliseconds($first).ToString("HH:mm:ss.fff"), ($script:FlashOwnPids -join ","))
        $dir = Get-EvidenceDir
        if ($dir -and $probe.WhiteClear) {
            $tag = ($Label -replace '[^A-Za-z0-9]+', '-')
            $probe.FirstWhite.Save((Join-Path $dir "$($script:Sbx.Name)-$tag-white.png"), [Drawing.Imaging.ImageFormat]::Png)
            if ($probe.BeforeWhite) { $probe.BeforeWhite.Save((Join-Path $dir "$($script:Sbx.Name)-$tag-before.png"), [Drawing.Imaging.ImageFormat]::Png) }
        }
    }
    if ($n -lt 20) { throw "${Label}: only $n frames captured" }
    if ($white -ne 0) { throw "${Label}: $white white frames of $n" }
}

function Get-TabCount($G) { @(@((Get-GhosttyState -Class $G.Class).windows)[0].tabs).Count }

function Invoke-TabBurst($G, [string]$Label, [int]$Count = 4) {
    $before = Get-TabCount $G
    Measure-Burst $Label (Get-TerminalRect $G) {
        for ($i = 0; $i -lt $Count; $i++) {
            $t0 = $script:FlashProbe.Now()
            [void](Invoke-GhosttyAction -Class $G.Class -Action 'new_tab')
            $script:FlashMarks.Add(('new_tab {0:N0}-{1:N0}ms' -f $t0, $script:FlashProbe.Now()))
            Start-Sleep -Milliseconds 60
        }
    } {
        if ((Get-TabCount $G) -eq $before + $Count) { $true }
    }
}

function Start-FlashGhostty([string]$Extra) {
    $g = Start-E2eGhostty -ConfigText "foreground = #e0e0e0`nbackground-opacity = 0.85`nbackground-blur = false`nconfirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = always`n$Extra"
    if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "no frame dump at $($g.Dump)" }
    Move-Window $g.Hwnd 160 160 1000 700
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
    Start-Sleep -Milliseconds 1000
    $comp = (Get-GhosttyState -Class $g.Class).m3.composition
    if ($comp.mode -ne 'composition') { throw "mode is $($comp.mode), expected composition" }
    $script:FlashOwnPids = @([uint32]$g.Pid, [uint32]$PID)
    $g
}

function Stop-FlashGhostty($G) {
    if ($G -and -not $G.Process.HasExited) {
        $G.Process.Kill()
        [void]$G.Process.WaitForExit(5000)
    }
}

Invoke-E2eScenario 'new-tab-white-flash' {
    Assert-TransparencyEffects
    $runs = if ($env:GHOSTTY_E2E_FLASH_RUNS) { [int]$env:GHOSTTY_E2E_FLASH_RUNS } else { 3 }
    $back = New-BackdropForm 60 60 1500 1000
    $back.BackColor = [Drawing.Color]::FromArgb(255, 255, 255)
    try {
        Show-BackdropForm $back

        $g = Start-FlashGhostty "background = #1a2b4c`n"
        try {
            for ($run = 1; $run -le $runs; $run++) { Invoke-TabBurst $g "tabs run $run" }

            $before = (Get-SplitState $g).Surfaces.Count
            Measure-Burst 'splits' (Get-TerminalRect $g) {
                for ($i = 0; $i -lt 3; $i++) {
                    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_split:right')
                    Start-Sleep -Milliseconds 60
                }
            } {
                if ((Get-SplitState $g).Surfaces.Count -eq $before + 3) { $true }
            }

            # The new window cascades by a caption height over the first one
            # and is not topmost: the first window and the backdrop step down
            # so that it shows above them. The sampled rect is the part both
            # windows cover.
            $notTopmost = [IntPtr]::op_Explicit(-2)
            [void][GhosttyE2e.BackdropNative]::SetWindowPos($back.Handle, $notTopmost, 0, 0, 0, 0, 0x13)
            [void][GhosttyE2e.BackdropNative]::SetWindowPos($g.Hwnd, $notTopmost, 0, 0, 0, 0, 0x13)
            [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
            # HWND_NOTOPMOST does not move a window that already is not
            # topmost, and the foreground change is refused while the user
            # works in another window: the backdrop would stay above the
            # first window and read as white from the first frame on.
            [void][GhosttyE2e.BackdropNative]::SetWindowPos($g.Hwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x13)
            Start-Sleep -Milliseconds 500
            $r = Get-TerminalRect $g
            $shift = 80
            $rect = [pscustomobject]@{ X = $r.X + $shift; Y = $r.Y + $shift; W = $r.W - 2 * $shift; H = $r.H - 2 * $shift }
            $centre = New-Object GhosttyE2e.FlashZ+POINT
            $centre.X = $rect.X + [int]($rect.W / 2)
            $centre.Y = $rect.Y + [int]($rect.H / 2)
            $top = [GhosttyE2e.FlashZ]::GetAncestor([GhosttyE2e.FlashZ]::WindowFromPoint($centre), 2)
            if ($top -ne $g.Hwnd) { throw "window: before the burst the sampled rect shows window 0x$('{0:x}' -f $top.ToInt64()), not the first window" }
            Measure-Burst 'window' $rect {
                [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_window')
            } {
                if (@((Get-GhosttyState -Class $g.Class).windows).Count -eq 2) { $true }
            }
            # The phase means something only if the new window was what the
            # probe saw: it must contain the sampled rect and be on top there.
            $nw = @(@((Get-GhosttyState -Class $g.Class).windows) | Where-Object { [Convert]::ToInt64(([string]$_.hwnd).Substring(2), 16) -ne $g.Hwnd.ToInt64() })
            if ($nw.Count -ne 1) { throw "window: expected one new window, found $($nw.Count)" }
            $nh = [IntPtr][Convert]::ToInt64(([string]$nw[0].hwnd).Substring(2), 16)
            $wr = New-Object GhosttyE2e.Win+RECT
            [void][GhosttyE2e.Win]::GetWindowRect($nh, [ref]$wr)
            if ($wr.Left -gt $rect.X -or $wr.Top -gt $rect.Y -or $wr.Right -lt $rect.X + $rect.W -or $wr.Bottom -lt $rect.Y + $rect.H) {
                throw "window: the new window ($($wr.Left),$($wr.Top))-($($wr.Right),$($wr.Bottom)) does not cover the sampled rect ($($rect.X),$($rect.Y)) $($rect.W)x$($rect.H)"
            }
            $centre = New-Object GhosttyE2e.FlashZ+POINT
            $centre.X = $rect.X + [int]($rect.W / 2)
            $centre.Y = $rect.Y + [int]($rect.H / 2)
            $top = [GhosttyE2e.FlashZ]::GetAncestor([GhosttyE2e.FlashZ]::WindowFromPoint($centre), 2)
            if ($top -ne $nh) { throw "window: the sampled rect shows window 0x$('{0:x}' -f $top.ToInt64()), not the new window 0x$('{0:x}' -f $nh.ToInt64())" }
        } finally {
            Stop-FlashGhostty $g
        }

        # Light/dark theme pair: App.config holds the light theme; on a dark
        # system the panes are dark and the stand-in must be too.
        $light = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
        if ($null -ne $light -and $light -ne 0) {
            Write-E2eInfo 'theme: SKIP (the system scheme is light, the light theme is what shows)'
        } else {
            $themes = Join-Path $script:Sbx.Home '.config\ghostty\themes'
            New-Item -ItemType Directory -Force -Path $themes | Out-Null
            $utf8 = New-Object Text.UTF8Encoding $false
            [IO.File]::WriteAllText((Join-Path $themes 'e2e-light'), "background = #f4f4f4`nforeground = #202020`n", $utf8)
            [IO.File]::WriteAllText((Join-Path $themes 'e2e-dark'), "background = #1a2b4c`nforeground = #e0e0e0`n", $utf8)
            [void][GhosttyE2e.BackdropNative]::SetWindowPos($back.Handle, [IntPtr]::op_Explicit(-1), 0, 0, 0, 0, 0x13)
            $g = Start-FlashGhostty "theme = light:e2e-light,dark:e2e-dark`n"
            try {
                Invoke-TabBurst $g 'theme'
            } finally {
                Stop-FlashGhostty $g
            }
        }
    } finally {
        $back.Close()
    }
}
