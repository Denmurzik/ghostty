# Clipboard snapshot for the e2e harness: every HGLOBAL-backed format on the
# clipboard (Unicode text, "HTML Format", "Rich Text Format", DIB, registered
# formats ...) is read into memory and can be put back in the same order.
# A clipboard holding something that cannot be copied this way (owner-display,
# GDI handles, private ranges, delayed formats that give no data) is refused
# with an E2E-SKIP error, so nothing is lost. A copy on disk (for a runner
# that restores after a killed scenario) is protected with DPAPI, current
# user. Keep this file ASCII only (Windows PowerShell 5.1).

Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Security

if (-not ('GhosttyClip.Api' -as [type])) {
    Add-Type -Namespace GhosttyClip -Name Api -MemberDefinition @"
[DllImport("user32.dll", SetLastError = true)] static extern bool OpenClipboard(IntPtr owner);
[DllImport("user32.dll", SetLastError = true)] static extern bool CloseClipboard();
[DllImport("user32.dll", SetLastError = true)] static extern bool EmptyClipboard();
[DllImport("user32.dll")] static extern uint EnumClipboardFormats(uint format);
[DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint format);
[DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint format, IntPtr mem);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClipboardFormatNameW(uint format, System.Text.StringBuilder name, int max);
[DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr h);
[DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr h);
[DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr h);
[DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
[DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr h);

const long MaxTotal = 64L * 1024 * 1024;

static bool OpenRetry() {
    for (int i = 0; i < 30; i++) {
        if (OpenClipboard(IntPtr.Zero)) return true;
        System.Threading.Thread.Sleep(100);
    }
    return false;
}

static string NameOf(uint f) {
    var sb = new System.Text.StringBuilder(256);
    if (f >= 0xC000 && GetClipboardFormatNameW(f, sb, 256) > 0) return sb.ToString();
    return "format " + f;
}

// Formats as {id, bytes} pairs; `problem` says why the clipboard cannot be
// copied (null when it can).
public static object[] Snapshot(out string problem) {
    problem = null;
    if (!OpenRetry()) { problem = "the clipboard is busy"; return null; }
    try {
        var ids = new System.Collections.Generic.List<uint>();
        for (uint f = EnumClipboardFormats(0); f != 0; f = EnumClipboardFormats(f)) ids.Add(f);
        bool hasDib = ids.Contains(8) || ids.Contains(17);
        var items = new System.Collections.Generic.List<object>();
        long total = 0;
        foreach (uint f in ids) {
            // A bitmap handle next to a DIB is the system's own conversion.
            if ((f == 2 || f == 9) && hasDib) continue;
            if (f == 2 || f == 3 || f == 9 || f == 14 || (f >= 0x80 && f <= 0x8E) || (f >= 0x200 && f <= 0x3FF)) {
                problem = NameOf(f) + " (a handle that cannot be copied)";
                return null;
            }
            IntPtr h = GetClipboardData(f);
            if (h == IntPtr.Zero) { problem = NameOf(f) + " (no data)"; return null; }
            long size = (long)(ulong)GlobalSize(h);
            if (size <= 0) { problem = NameOf(f) + " (not a memory block)"; return null; }
            total += size;
            if (total > MaxTotal) { problem = "more than 64 MB on the clipboard"; return null; }
            IntPtr p = GlobalLock(h);
            if (p == IntPtr.Zero) { problem = NameOf(f) + " (cannot be locked)"; return null; }
            byte[] data = new byte[size];
            System.Runtime.InteropServices.Marshal.Copy(p, data, 0, (int)size);
            GlobalUnlock(h);
            items.Add(new object[] { f, data });
        }
        return items.ToArray();
    } finally { CloseClipboard(); }
}

// Replaces the clipboard by `items` (as returned by Snapshot), in order.
public static void Restore(object[] items) {
    if (!OpenRetry()) throw new System.InvalidOperationException("the clipboard is busy");
    try {
        EmptyClipboard();
        foreach (object o in items) {
            object[] pair = (object[])o;
            uint f = (uint)pair[0];
            byte[] data = (byte[])pair[1];
            IntPtr mem = GlobalAlloc(2, new UIntPtr((ulong)data.Length));
            if (mem == IntPtr.Zero) throw new System.OutOfMemoryException();
            IntPtr p = GlobalLock(mem);
            System.Runtime.InteropServices.Marshal.Copy(data, 0, p, data.Length);
            GlobalUnlock(mem);
            if (SetClipboardData(f, mem) == IntPtr.Zero) { GlobalFree(mem); throw new System.InvalidOperationException("SetClipboardData failed for " + NameOf(f)); }
        }
    } finally { CloseClipboard(); }
}

public static void Clear() {
    if (!OpenRetry()) throw new System.InvalidOperationException("the clipboard is busy");
    try { EmptyClipboard(); } finally { CloseClipboard(); }
}
"@
}

# The clipboard as an object, or throws 'E2E-SKIP: ...' when it holds
# something that could not be put back. Items is an array of @(id, bytes).
function Get-ClipboardSnapshot {
    $problem = $null
    $items = [GhosttyClip.Api]::Snapshot([ref]$problem)
    if ($null -eq $items) { throw "E2E-SKIP: clipboard holds data that cannot be copied and put back ($problem)" }
    [pscustomobject]@{ Items = @($items) }
}

function Set-ClipboardSnapshot($Snapshot) {
    if ($null -eq $Snapshot) { return }
    if (@($Snapshot.Items).Count -eq 0) { [GhosttyClip.Api]::Clear(); return }
    [GhosttyClip.Api]::Restore([object[]]@($Snapshot.Items))
}

function Test-ClipboardSnapshotEqual($A, $B) {
    $x = @($A.Items); $y = @($B.Items)
    if ($x.Count -ne $y.Count) { return $false }
    for ($i = 0; $i -lt $x.Count; $i++) {
        if ([uint32]$x[$i][0] -ne [uint32]$y[$i][0]) { return $false }
        $bx = [byte[]]$x[$i][1]; $by = [byte[]]$y[$i][1]
        if ($bx.Length -ne $by.Length) { return $false }
        for ($k = 0; $k -lt $bx.Length; $k++) { if ($bx[$k] -ne $by[$k]) { return $false } }
    }
    $true
}

# DPAPI (current user) copy of a snapshot on disk.
function Export-ClipboardSnapshot($Snapshot, [string]$Path) {
    $ms = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter $ms
    $items = @($Snapshot.Items)
    $w.Write([int]$items.Count)
    foreach ($it in $items) {
        $w.Write([uint32]$it[0])
        $w.Write([int]([byte[]]$it[1]).Length)
        $w.Write([byte[]]$it[1])
    }
    $w.Flush()
    $blob = [Security.Cryptography.ProtectedData]::Protect($ms.ToArray(), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes($Path, $blob)
}

function Import-ClipboardSnapshot([string]$Path) {
    $raw = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($Path), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $r = New-Object IO.BinaryReader (New-Object IO.MemoryStream (, $raw))
    $n = $r.ReadInt32()
    $items = @()
    for ($i = 0; $i -lt $n; $i++) {
        $f = $r.ReadUInt32()
        $len = $r.ReadInt32()
        $items += , @($f, $r.ReadBytes($len))
    }
    [pscustomobject]@{ Items = $items }
}

Export-ModuleMember -Function Get-ClipboardSnapshot, Set-ClipboardSnapshot, Test-ClipboardSnapshotEqual, Export-ClipboardSnapshot, Import-ClipboardSnapshot
