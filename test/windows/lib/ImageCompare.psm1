# Image comparison for the screenshot checks (vt-smoke). Windows PowerShell
# 5.1 compatible (System.Drawing). Keep this file ASCII only.

Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Drawing

if (-not ('GhosttyImage.Cmp' -as [type])) {
    Add-Type -Namespace GhosttyImage -Name Cmp -ReferencedAssemblies 'System.Drawing' -MemberDefinition @"
public static byte[] Load(string path, out int w, out int h) {
    using (var src = new System.Drawing.Bitmap(path)) {
        w = src.Width; h = src.Height;
        using (var b = new System.Drawing.Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb)) {
            using (var g = System.Drawing.Graphics.FromImage(b)) { g.DrawImageUnscaled(src, 0, 0); }
            var rect = new System.Drawing.Rectangle(0, 0, w, h);
            var d = b.LockBits(rect, System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            try {
                var bytes = new byte[w * h * 4];
                for (int y = 0; y < h; y++)
                    System.Runtime.InteropServices.Marshal.Copy(new System.IntPtr(d.Scan0.ToInt64() + (long)y * d.Stride), bytes, y * w * 4, w * 4);
                return bytes;
            } finally { b.UnlockBits(d); }
        }
    }
}

// Per-channel (B, G, R; alpha ignored) absolute difference. Returns the count
// of pixels within tol; maxDiff / sumDiff are over all channels.
public static long Diff(byte[] a, byte[] r, int tol, out int maxDiff, out double meanDiff, byte[] diffOut) {
    long ok = 0, sum = 0;
    int max = 0;
    int n = a.Length / 4;
    for (int i = 0; i < n; i++) {
        int o = i * 4;
        int pm = 0;
        for (int c = 0; c < 3; c++) {
            int d = a[o + c] - r[o + c];
            if (d < 0) d = -d;
            sum += d;
            if (d > pm) pm = d;
        }
        if (pm > max) max = pm;
        bool good = pm <= tol;
        if (good) ok++;
        if (diffOut != null) {
            if (good) {
                diffOut[o] = (byte)(a[o] / 4); diffOut[o + 1] = (byte)(a[o + 1] / 4); diffOut[o + 2] = (byte)(a[o + 2] / 4);
            } else {
                diffOut[o] = 0; diffOut[o + 1] = 0; diffOut[o + 2] = 255;
            }
            diffOut[o + 3] = 255;
        }
    }
    maxDiff = max;
    meanDiff = n == 0 ? 0 : (double)sum / ((double)n * 3.0);
    return ok;
}

public static void SavePng(byte[] bgra, int w, int h, string path) {
    using (var b = new System.Drawing.Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb)) {
        var rect = new System.Drawing.Rectangle(0, 0, w, h);
        var d = b.LockBits(rect, System.Drawing.Imaging.ImageLockMode.WriteOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        try {
            for (int y = 0; y < h; y++)
                System.Runtime.InteropServices.Marshal.Copy(bgra, y * w * 4, new System.IntPtr(d.Scan0.ToInt64() + (long)y * d.Stride), w * 4);
        } finally { b.UnlockBits(d); }
        b.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }
}
"@
}

<#
.SYNOPSIS
Compares an image with a reference PNG, per channel.

.DESCRIPTION
Match is the fraction of pixels whose every channel differs by at most
Tolerance; the caller passes when Match >= MinMatch. MaxDiff and MeanDiff are
over all channels (alpha is ignored). When Match < MinMatch a diff image (red
where a pixel exceeds the tolerance, the actual image dimmed elsewhere) is
written to DiffPng (default: <actual>.diff.png). Images of different sizes
are an error.
#>
function Compare-Image {
    param(
        [Parameter(Mandatory)][string]$Actual,
        [Parameter(Mandatory)][string]$Reference,
        [int]$Tolerance = 24,
        [double]$MinMatch = 0.995,
        [string]$DiffPng
    )
    $aw = 0; $ah = 0; $rw = 0; $rh = 0
    $a = [GhosttyImage.Cmp]::Load((Resolve-Path -LiteralPath $Actual).Path, [ref]$aw, [ref]$ah)
    $r = [GhosttyImage.Cmp]::Load((Resolve-Path -LiteralPath $Reference).Path, [ref]$rw, [ref]$rh)
    if ($aw -ne $rw -or $ah -ne $rh) {
        throw "size mismatch: actual ${aw}x${ah}, reference ${rw}x${rh}"
    }
    $diff = New-Object byte[] $a.Length
    $max = 0; $mean = 0.0
    $ok = [GhosttyImage.Cmp]::Diff($a, $r, $Tolerance, [ref]$max, [ref]$mean, $diff)
    $n = $aw * $ah
    $match = if ($n -eq 0) { 1.0 } else { [double]$ok / [double]$n }
    $out = $null
    if ($match -lt $MinMatch) {
        $out = if ($DiffPng) { $DiffPng } else { $Actual + '.diff.png' }
        [GhosttyImage.Cmp]::SavePng($diff, $aw, $ah, $out)
    }
    [pscustomobject]@{ Match = $match; MaxDiff = $max; MeanDiff = $mean; DiffPng = $out }
}

Export-ModuleMember -Function Compare-Image
