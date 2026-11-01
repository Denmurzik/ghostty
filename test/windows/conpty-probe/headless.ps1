<#
.SYNOPSIS
Headless ConPTY probe: which escape sequences leave a pseudo console, for the
inbox ConPTY (kernel32) and for a bundled conpty.dll + OpenConsole.exe pair.

.DESCRIPTION
No window, no Ghostty: this script is the terminal. It creates the pseudo
console itself (kernel32, or CreatePseudoConsole/ResizePseudoConsole/
ClosePseudoConsole from <DllDir>\conpty.dll loaded with
LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32; OpenConsole.exe
must sit next to it), runs cases/headless-seqs.sh in Git Bash on it and reads
the raw output bytes. The oracle is the byte stream a terminal would get:

  apc     ESC _ G (Kitty graphics) reaches the output
  sgr58   an SGR with 58 (underline colour) reaches the output
  osc133  four ESC ] 133 ; reach the output
  osc7 / osc8 / osc52 / osc9   ESC ] 7 ; / 8 ; / 52 ; / 9 ; reach the output
  dsr     who answers the case's CSI 6 n (the host answers a forwarded query
          with 24;77, inside the 80x25 grid) and the column after a ZWJ emoji
  size    `stty size` after ResizePseudoConsole(100x30) says `30 100`

The host answers DA1 (`ESC [ ?62;22c`, Ghostty's reply) and CSI 6 n like a
terminal. Latency: cmd.exe on the pseudo console, one key at a time, time from
WriteFile to the echoed byte (conhost's cooked-mode echo), <Samples> samples.

Rows go to <OutDir>\headless.csv; the raw output of every run to
<OutDir>\<variant>-<run>.bin. Exit 1 when a run could not start.

-Kitty5522 (M8): OSC 5522 (kitty clipboard) and DECSET/DECRQM ?5522 through the
console. cases/headless-5522.sh (Git Bash) or the vtreader exe (native) emits
them; the host records which of them arrive byte-identical, answers DECRQM ?5522
with `ESC [ ? 5522 ; 1 $ y` and a read request with a fixed OK / listing / DATA /
DONE reply of -ReplyBytes base64 bytes (default 4096), and compares what the
client read. Native runs at each of -TimingBytes (default 1 MiB and 8 MiB) time
the input path (up to -TimingLimitSec, default 60) and sample the private bytes of the
console host processes.

-Visibility (M8): `ESC [ ? 2033 h`, `ESC [ ? 998 n` and `ESC [ ? 2033 $ p` through
the console; the host answers the first two with `ESC [ ? 999 ; 1 n` and the
DECRQM with `ESC [ ? 2033 ; 2 $ y`, and records which requests arrived and what
the client read.

.PARAMETER DllDir
Directory with conpty.dll and OpenConsole.exe of the target architecture.
Without it only the inbox variants run.

.EXAMPLE
powershell -NoProfile -File test/windows/conpty-probe/headless.ps1 -DllDir C:\tmp\conpty-x64 -Repeat 2
#>
param(
    [string]$DllDir,
    [string[]]$Flags = @(0, 8),
    [ValidateRange(1, 10)][int]$Repeat = 1,
    [ValidateRange(0, 2000)][int]$Samples = 200,
    [string]$Bash,
    [string]$OutDir,
    [switch]$KittyQ,
    [switch]$Kitty5522,
    [switch]$Visibility,
    [ValidateRange(0, 16777216)][int]$ReplyBytes = 4096,
    [int[]]$TimingBytes = @(1048576, 8388608),
    [ValidateRange(5, 600)][int]$TimingLimitSec = 60,
    [string[]]$ReplyForm = @('plain', 'w32im')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ReplyForm = @($ReplyForm | ForEach-Object { $_ -split "," } | Where-Object { $_ })
foreach ($rf in $ReplyForm) { if ($rf -notin 'plain', 'w32im') { throw "-ReplyForm: plain or w32im, not '$rf'" } }
$Flags = @($Flags | ForEach-Object { $_ -split "," } | Where-Object { $_ } | ForEach-Object { [uint32]$_ })
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'conpty-probe-headless' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
if (-not $Bash) {
    foreach ($v in 'ProgramFiles', 'ProgramW6432') {
        $d = [Environment]::GetEnvironmentVariable($v)
        if ($d -and (Test-Path -LiteralPath (Join-Path $d 'Git\bin\bash.exe'))) { $Bash = Join-Path $d 'Git\bin\bash.exe'; break }
    }
}
if (-not $Bash) { Write-Output 'SKIP: Git Bash not found (-Bash)'; exit 0 }
$case = Join-Path $PSScriptRoot 'cases\headless-seqs.sh'
$dll = $null
if ($DllDir) {
    $dll = [IO.Path]::GetFullPath((Join-Path $DllDir "conpty.dll"))
    foreach ($f in $dll, (Join-Path (Split-Path $dll) 'OpenConsole.exe')) {
        if (-not (Test-Path -LiteralPath $f)) { Write-Output "missing: $f"; exit 1 }
    }
}

if (-not ('CpProbe.Session' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace CpProbe {
[StructLayout(LayoutKind.Sequential)] public struct COORD { public short X; public short Y; }
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct STARTUPINFO {
    public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
}
[StructLayout(LayoutKind.Sequential)] public struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
[StructLayout(LayoutKind.Sequential)] public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

[UnmanagedFunctionPointer(CallingConvention.Winapi)] public delegate int CreateFn(COORD size, IntPtr hIn, IntPtr hOut, uint flags, out IntPtr hpc);
[UnmanagedFunctionPointer(CallingConvention.Winapi)] public delegate int ResizeFn(IntPtr hpc, COORD size);
[UnmanagedFunctionPointer(CallingConvention.Winapi)] public delegate void CloseFn(IntPtr hpc);

public static class K {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern IntPtr LoadLibraryExW(string p, IntPtr h, uint f);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi, BestFitMapping = false)] public static extern IntPtr GetProcAddress(IntPtr m, string n);
    [DllImport("kernel32.dll")] public static extern int CreatePseudoConsole(COORD s, IntPtr i, IntPtr o, uint f, out IntPtr h);
    [DllImport("kernel32.dll")] public static extern int ResizePseudoConsole(IntPtr h, COORD s);
    [DllImport("kernel32.dll")] public static extern void ClosePseudoConsole(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CreatePipe(out IntPtr r, out IntPtr w, IntPtr sa, int size);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool InitializeProcThreadAttributeList(IntPtr l, int n, int f, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool UpdateProcThreadAttribute(IntPtr l, uint f, IntPtr attr, IntPtr val, IntPtr size, IntPtr prev, IntPtr retsize);
    [DllImport("kernel32.dll")] public static extern void DeleteProcThreadAttributeList(IntPtr l);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool WriteFile(IntPtr h, byte[] b, int n, out int w, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool ReadFile(IntPtr h, byte[] b, int n, out int r, IntPtr ov);
}

public class Session {
    static Dictionary<string, IntPtr> modules = new Dictionary<string, IntPtr>();
    CreateFn create; ResizeFn resize; CloseFn close;
    IntPtr hpc, inW, outR, attrs;
    PROCESS_INFORMATION pi;
    readonly List<byte> buf = new List<byte>();
    readonly object gate = new object();
    readonly object writeGate = new object();
    int scanned;
    int kqScanned;
    // "" = do not answer Kitty a=q; "plain" = ESC _ G i=31;OK ESC \ ; "w32im" = the same
    // characters as win32-input-mode key-down records CSI 0;0;<unit>;1;0;1 _
    public string ReplyForm = "";
    // "" ; "k5522" = answer DECRQM ?5522 and a 5522 read request ; "vis" = answer ?2033h, ?998n and DECRQM ?2033
    public string Mode = "";
    public int ReplyBytes = 4096;
    public long ReplyT0 = -1, ReplyT1 = -1;
    public string LastReply = "";
    int rqScanned;
    string bigReply;
    long lastTicks;
    Thread reader;
    public readonly Stopwatch Clock = Stopwatch.StartNew();
    public readonly List<string> Replies = new List<string>();
    public int Hr;
    public int ChildPid { get { return pi.dwProcessId; } }

    public Session(string dll) {
        if (string.IsNullOrEmpty(dll)) {
            create = K.CreatePseudoConsole; resize = K.ResizePseudoConsole; close = K.ClosePseudoConsole;
            return;
        }
        IntPtr m;
        if (!modules.TryGetValue(dll, out m)) {
            // LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32
            m = K.LoadLibraryExW(dll, IntPtr.Zero, 0x100 | 0x800);
            if (m == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            modules[dll] = m;
        }
        create = (CreateFn)Marshal.GetDelegateForFunctionPointer(Proc(m, "CreatePseudoConsole"), typeof(CreateFn));
        resize = (ResizeFn)Marshal.GetDelegateForFunctionPointer(Proc(m, "ResizePseudoConsole"), typeof(ResizeFn));
        close = (CloseFn)Marshal.GetDelegateForFunctionPointer(Proc(m, "ClosePseudoConsole"), typeof(CloseFn));
    }

    static IntPtr Proc(IntPtr m, string name) {
        IntPtr p = K.GetProcAddress(m, name);
        if (p == IntPtr.Zero) throw new Exception("missing export " + name);
        return p;
    }

    public bool Start(uint flags, string cmdline, short cols, short rows) {
        IntPtr inR, outW;
        if (!K.CreatePipe(out inR, out inW, IntPtr.Zero, 0)) throw new System.ComponentModel.Win32Exception();
        if (!K.CreatePipe(out outR, out outW, IntPtr.Zero, 0)) throw new System.ComponentModel.Win32Exception();
        COORD size; size.X = cols; size.Y = rows;
        Hr = create(size, inR, outW, flags, out hpc);
        if (Hr != 0) { K.CloseHandle(inR); K.CloseHandle(outW); return false; }

        IntPtr n = IntPtr.Zero;
        K.InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref n);
        attrs = Marshal.AllocHGlobal(n);
        if (!K.InitializeProcThreadAttributeList(attrs, 1, 0, ref n)) throw new System.ComponentModel.Win32Exception();
        // PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
        if (!K.UpdateProcThreadAttribute(attrs, 0, (IntPtr)0x20016, hpc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
            throw new System.ComponentModel.Win32Exception();
        STARTUPINFOEX si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        // STARTF_USESTDHANDLES with no handles: the child must not pick up this host's redirected std handles.
        si.StartupInfo.dwFlags = 0x100;
        si.lpAttributeList = attrs;
        // EXTENDED_STARTUPINFO_PRESENT
        if (!K.CreateProcessW(null, new StringBuilder(cmdline), IntPtr.Zero, IntPtr.Zero, false, 0x80000, IntPtr.Zero, null, ref si, out pi))
            throw new System.ComponentModel.Win32Exception();
        K.CloseHandle(inR); K.CloseHandle(outW);
        reader = new Thread(Read); reader.IsBackground = true; reader.Start();
        return true;
    }

    void Read() {
        byte[] tmp = new byte[65536];
        int n;
        while (K.ReadFile(outR, tmp, tmp.Length, out n, IntPtr.Zero) && n > 0) {
            List<string> answers = new List<string>();
            lock (gate) {
                for (int i = 0; i < n; i++) buf.Add(tmp[i]);
                lastTicks = Clock.ElapsedTicks;
                Answer("\x1b[c", "\x1b[?62;22c", answers);
                Answer("\x1b[0c", "\x1b[?62;22c", answers);
                Answer("\x1b[6n", "\x1b[24;77R", answers);
                AnswerKitty(answers);
                if (Mode == "k5522") {
                    // \x24 is the dollar sign: this source sits in a PowerShell expandable here-string
                    Answer("\x1b[?5522\x24p", "\x1b[?5522;1\x24y", answers);
                    Answer5522Read(answers);
                } else if (Mode == "vis") {
                    Answer("\x1b[?2033h", "\x1b[?999;1n", answers);
                    Answer("\x1b[?998n", "\x1b[?999;1n", answers);
                    Answer("\x1b[?2033\x24p", "\x1b[?2033;2\x24y", answers);
                }
                scanned = buf.Count;
                Monitor.PulseAll(gate);
            }
            foreach (string a in answers) Write(a);
            if (bigReply != null) {
                string big = bigReply; bigReply = null;
                Thread th = new Thread(delegate() { WriteChunks(big); });
                th.IsBackground = true; th.Start();
            }
        }
        lock (gate) { lastTicks = Clock.ElapsedTicks; Monitor.PulseAll(gate); }
    }

    // A complete `ESC _ G ... a=q ... ESC \` in the output gets the OK reply.
    void AnswerKitty(List<string> answers) {
        if (ReplyForm == "") return;
        while (true) {
            int s = -1;
            for (int i = kqScanned; i + 3 <= buf.Count; i++)
                if (buf[i] == 0x1b && buf[i + 1] == (byte)'_' && buf[i + 2] == (byte)'G') { s = i; break; }
            if (s < 0) return;
            int e = -1;
            for (int i = s + 3; i + 2 <= buf.Count; i++)
                if (buf[i] == 0x1b && buf[i + 1] == (byte)'\\') { e = i + 2; break; }
            if (e < 0) { kqScanned = s; return; }
            string body = Encoding.ASCII.GetString(buf.GetRange(s, e - s).ToArray());
            kqScanned = e;
            if (!body.Contains("a=q")) continue;
            string reply = "\x1b_Gi=31;OK\x1b\\";
            if (ReplyForm == "w32im") {
                StringBuilder w = new StringBuilder();
                foreach (char c in reply) w.Append("\x1b[0;0;" + (int)c + ";1;0;1_");
                reply = w.ToString();
            }
            answers.Add(reply);
            Replies.Add("kitty-a=q@" + s + "->" + ReplyForm);
        }
    }

    static string B64(string s) { return Convert.ToBase64String(Encoding.ASCII.GetBytes(s)); }
    static string Osc5522(string meta, string payload) {
        return "\x1b]5522;" + meta + (payload == null ? "" : ";" + payload) + "\x1b\\";
    }

    // The fixed reply to a read request: OK, the listing, DATA chunks of at most 4096
    // base64 bytes (ReplyBytes in all), DONE.
    string BuildReply() {
        StringBuilder r = new StringBuilder();
        r.Append(Osc5522("type=read:status=OK", null));
        r.Append(Osc5522("type=read:status=DATA:mime=" + B64("."), B64("text/plain text/html")));
        string alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        string meta = "type=read:status=DATA:mime=" + B64("text/plain");
        int left = ReplyBytes - ReplyBytes % 4, pos = 0;
        while (left > 0) {
            int n = Math.Min(left, 4096);
            StringBuilder c = new StringBuilder(n);
            for (int i = 0; i < n; i++) c.Append(alpha[(pos + i) % 64]);
            r.Append(Osc5522(meta, c.ToString()));
            pos += n; left -= n;
        }
        r.Append(Osc5522("type=read:status=DONE", null));
        return r.ToString();
    }

    // A complete `ESC ] 5522 ; type=read ; ... (ESC \ | BEL)` in the output gets the fixed reply.
    void Answer5522Read(List<string> answers) {
        byte[] pre = Encoding.ASCII.GetBytes("\x1b]5522;type=read;");
        while (true) {
            int s = -1;
            for (int i = rqScanned; i + pre.Length <= buf.Count && s < 0; i++) {
                bool hit = true;
                for (int j = 0; j < pre.Length && hit; j++) hit = buf[i + j] == pre[j];
                if (hit) s = i;
            }
            if (s < 0) return;
            int e = -1;
            for (int i = s + pre.Length; i < buf.Count && e < 0; i++) {
                if (buf[i] == 7) e = i + 1;
                else if (buf[i] == 0x1b && i + 1 < buf.Count && buf[i + 1] == (byte)'\\') e = i + 2;
            }
            if (e < 0) { rqScanned = s; return; }
            rqScanned = e;
            string reply = BuildReply();
            LastReply = reply;
            ReplyT0 = Clock.ElapsedMilliseconds; ReplyT1 = -1;
            Replies.Add("5522-read@" + s + "->" + reply.Length + " bytes");
            if (reply.Length > 200000) bigReply = reply; else answers.Add(reply);
        }
    }

    void WriteChunks(string s) {
        byte[] b = Encoding.ASCII.GetBytes(s);
        for (int off = 0; off < b.Length; off += 32768) {
            int n = Math.Min(32768, b.Length - off), w;
            byte[] c = new byte[n];
            Array.Copy(b, off, c, 0, n);
            bool ok;
            lock (writeGate) ok = K.WriteFile(inW, c, n, out w, IntPtr.Zero);
            if (!ok) return;
        }
        ReplyT1 = Clock.ElapsedMilliseconds;
    }

    // A query that ends in the bytes read just now (not in bytes scanned before).
    void Answer(string query, string reply, List<string> answers) {
        int from = Math.Max(0, scanned - query.Length + 1);
        for (int i = from; i + query.Length <= buf.Count; i++) {
            bool hit = true;
            for (int j = 0; j < query.Length && hit; j++) hit = buf[i + j] == (byte)query[j];
            if (hit && i + query.Length > scanned) {
                answers.Add(reply);
                Replies.Add(Esc(Encoding.ASCII.GetBytes(query), 0, query.Length, 32) + "@" + i);
            }
        }
    }

    public void Write(string s) {
        byte[] b = Encoding.UTF8.GetBytes(s);
        int w;
        lock (writeGate) K.WriteFile(inW, b, b.Length, out w, IntPtr.Zero);
    }

    public int Length { get { lock (gate) return buf.Count; } }
    public byte[] Bytes() { lock (gate) return buf.ToArray(); }

    // Index of the first `pattern` at or after `from`, or -1 after `ms`.
    public int WaitFor(string pattern, int from, int ms) {
        byte[] p = Encoding.UTF8.GetBytes(pattern);
        long deadline = Clock.ElapsedMilliseconds + ms;
        lock (gate) {
            while (true) {
                for (int i = from; i + p.Length <= buf.Count; i++) {
                    bool hit = true;
                    for (int j = 0; j < p.Length && hit; j++) hit = buf[i + j] == p[j];
                    if (hit) return i;
                }
                long left = deadline - Clock.ElapsedMilliseconds;
                if (left <= 0) return -1;
                Monitor.Wait(gate, (int)left);
            }
        }
    }

    // Waits until no byte arrived for `ms` (at most `maxMs`).
    public void WaitQuiet(int ms, int maxMs) {
        long end = Clock.ElapsedMilliseconds + maxMs;
        lock (gate) {
            while (Clock.ElapsedMilliseconds < end) {
                long idle = (Clock.ElapsedTicks - lastTicks) * 1000 / Stopwatch.Frequency;
                if (idle >= ms) return;
                Monitor.Wait(gate, (int)Math.Max(1, ms - idle));
            }
        }
    }

    public int Resize(short cols, short rows) { COORD c; c.X = cols; c.Y = rows; return resize(hpc, c); }

    public void Stop() {
        if (hpc != IntPtr.Zero) { close(hpc); hpc = IntPtr.Zero; }
        if (pi.hProcess != IntPtr.Zero) {
            if (K.WaitForSingleObject(pi.hProcess, 3000) != 0) K.TerminateProcess(pi.hProcess, 1);
            K.CloseHandle(pi.hProcess); K.CloseHandle(pi.hThread); pi.hProcess = IntPtr.Zero;
        }
        if (reader != null) reader.Join(3000);
        if (inW != IntPtr.Zero) { K.CloseHandle(inW); inW = IntPtr.Zero; }
        if (outR != IntPtr.Zero) { K.CloseHandle(outR); outR = IntPtr.Zero; }
        if (attrs != IntPtr.Zero) { K.DeleteProcThreadAttributeList(attrs); Marshal.FreeHGlobal(attrs); attrs = IntPtr.Zero; }
    }

    public static string Esc(byte[] b, int start, int end, int max) {
        StringBuilder s = new StringBuilder();
        for (int i = Math.Max(0, start); i < Math.Min(end, b.Length) && s.Length < max; i++) {
            byte c = b[i];
            if (c == 0x1b) s.Append("\\e");
            else if (c == 7) s.Append("\\a");
            else if (c == '\r') s.Append("\\r");
            else if (c == '\n') s.Append("\\n");
            else if (c == '\\') s.Append("\\\\");
            else if (c < 0x20 || c >= 0x7f || c == '"' || c == ',') s.AppendFormat("\\x{0:x2}", c);
            else s.Append((char)c);
        }
        return s.ToString();
    }
}
}
"@
}

$latin1 = [Text.Encoding]::GetEncoding(28591)

function Get-Slice([string]$Text, [string]$Name) {
    $a = $Text.IndexOf("<<$Name")
    if ($a -lt 0) { return $null }
    $b = $Text.IndexOf("$Name>>", $a)
    if ($b -lt 0) { return $null }
    $Text.Substring($a + $Name.Length + 2, $b - $a - $Name.Length - 2)
}

function Esc([string]$s, [int]$max = 160) {
    if ($null -eq $s) { return '<no slice>' }
    $b = $latin1.GetBytes($s)
    [CpProbe.Session]::Esc($b, 0, $b.Length, $max)
}

function Get-Hosts {
    @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$PID" |
        Where-Object { $_.Name -in 'conhost.exe', 'OpenConsole.exe' } | ForEach-Object { $_.Name }) -join '+'
}

# One run of the sequence case: returns rows (name, verdict, evidence).
function Invoke-SeqRun([string]$Dll, [uint32]$F) {
    $s = New-Object CpProbe.Session -ArgumentList @(, $Dll)
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        if (-not $s.Start($F, ('"{0}" --noprofile --norc "{1}"' -f $Bash, ($case -replace '\\', '/')), 80, 25)) {
            $rows.Add(@('start', 'failed', ('CreatePseudoConsole hr=0x{0:x8}' -f $s.Hr)))
            return , $rows
        }
        $ready = $s.WaitFor('READY-RESIZE', 0, 20000)
        $hosts = Get-Hosts
        $rows.Add(@('host', $(if ($hosts) { 'seen' } else { 'none' }), "child processes of the probe: $hosts"))
        if ($ready -lt 0) {
            $rows.Add(@('start', 'failed', ('no READY-RESIZE; output: ' + [CpProbe.Session]::Esc($s.Bytes(), 0, 4096, 600))))
            return , $rows
        }
        Start-Sleep -Milliseconds 200
        $hr = $s.Resize(100, 30)
        Start-Sleep -Milliseconds 400
        $s.Write("go`r")
        $done = $s.WaitFor('PROBE-DONE', $ready, 10000)
        $s.WaitQuiet(300, 2000)
        $bytes = $s.Bytes()
        [IO.File]::WriteAllBytes((Join-Path $OutDir ('{0}-{1}.bin' -f $script:Variant, $script:RunNo)), $bytes)
        $text = $latin1.GetString($bytes)

        $start = $text.IndexOf('<<apc')
        $rows.Add(@('startup', 'info', ('before the case: ' + (Esc $(if ($start -gt 0) { $text.Substring(0, $start) } else { '' }) 300) +
            ' ; host replies: ' + ($s.Replies -join ' '))))

        $apc = Get-Slice $text 'apc'
        $n = if ($apc) { ([regex]::Matches($apc, [regex]::Escape("$([char]27)_G"))).Count } else { 0 }
        $rows.Add(@('apc', $(if ($n -ge 2) { 'arrived' } elseif ($n) { 'partial' } else { 'dropped' }), "$n of 2 APC G; slice: $(Esc $apc 300)"))

        $sgr = Get-Slice $text 'sgr58'
        $sgrs = if ($sgr) { @([regex]::Matches($sgr, "$([char]27)\[[0-9:;]*m") | ForEach-Object { $_.Value }) } else { @() }
        $with58 = @($sgrs | Where-Object { $_ -match '(^|[\[;])58[:;]' })
        $rows.Add(@('sgr58', $(if ($with58.Count -ge 3) { 'arrived' } elseif ($with58.Count) { 'partial' } else { 'dropped' }),
            "$($with58.Count) of 3 SGR with 58; SGRs: $(Esc ($sgrs -join ' ') 300)"))

        # Regexes. OSC 8 may come back with parameters (the inbox console adds `id=`).
        $e = '\x1b'
        foreach ($o in @(@('osc133', "$e\]133;", 4), @('osc7', "$e\]7;file://probehost/c/probe/dir", 1),
                @('osc8', "$e\]8;[^;\x07\x1b]*;https://example\.com/probe", 1), @('osc52', "$e\]52;c;cHJvYmU=", 1),
                @('osc9', "$e\]9;probe-note", 1))) {
            # The inbox console re-emits OSCs when it flushes, not where the text put them:
            # count the whole output after the start, and say whether it sat in its slice.
            $sl = Get-Slice $text $o[0]
            $all = if ($start -ge 0) { ([regex]::Matches($text.Substring($start), $o[1])).Count } else { 0 }
            $inPlace = if ($sl) { ([regex]::Matches($sl, $o[1])).Count } else { 0 }
            $v = if ($all -ge $o[2]) { 'arrived' } elseif ($all) { 'partial' } else { 'dropped' }
            $rows.Add(@($o[0], $v, "$all of $($o[2]) ($inPlace in place); slice: $(Esc $sl 200)"))
        }

        $dsr = Get-Slice $text 'dsr'
        $m = if ($dsr) { [regex]::Match($dsr, 'DSR=([^\r\n]*)') } else { $null }
        $rep = if ($m -and $m.Success) { $m.Groups[1].Value } else { '' }
        $who = if ($rep -match '24;77''?$') { 'forwarded to the host' } elseif ($rep -match '\[(\d+);(\d+)''?$') { "console answered row=$($Matches[1]) col=$($Matches[2])" } else { 'no answer' }
        $q = ([regex]::Matches($text, [regex]::Escape("$([char]27)[6n"))).Count
        $rows.Add(@('dsr', 'info', "$who; reply $(Esc $rep 60); CSI 6 n in the output: $q; slice: $(Esc $dsr 200)"))

        $sz = Get-Slice $text 'size'
        $rows.Add(@('size', $(if ($sz -match '30 100') { 'ok' } else { 'wrong' }), ('resize hr=0x{0:x8}; stty: {1}; done={2}' -f $hr, (Esc $sz 120), ($done -ge 0))))
    } finally {
        $s.Stop()
    }
    , $rows
}

# Key echo latency through the pseudo console (cmd.exe cooked-mode echo).
function Invoke-Latency([string]$Dll, [uint32]$F) {
    $s = New-Object CpProbe.Session -ArgumentList @(, $Dll)
    try {
        if (-not $s.Start($F, ('"{0}\System32\cmd.exe" /d /q /k prompt $G' -f $env:SystemRoot), 80, 25)) { return 'start failed' }
        if ($s.WaitFor('>', 0, 10000) -lt 0) { return 'no prompt' }
        $s.WaitQuiet(300, 3000)
        $ms = New-Object System.Collections.Generic.List[double]
        $letters = 'abcdefghijklmnopqrstuvwxyz'
        for ($i = 0; $i -lt $Samples; $i++) {
            if ($i -gt 0 -and $i % 40 -eq 0) { $s.Write([string][char]27); $s.WaitQuiet(80, 1000) }
            $ch = [string]$letters[$i % 26]
            $from = $s.Length
            $t0 = $s.Clock.ElapsedTicks
            $s.Write($ch)
            if ($s.WaitFor($ch, $from, 2000) -lt 0) { return "echo of '$ch' missing after $i samples" }
            $ms.Add(($s.Clock.ElapsedTicks - $t0) * 1000.0 / [Diagnostics.Stopwatch]::Frequency)
            $s.WaitQuiet(5, 200)
        }
        $sorted = @($ms | Sort-Object)
        'n={0} p50={1:N2}ms p95={2:N2}ms max={3:N2}ms' -f $sorted.Count, $sorted[[int]($sorted.Count * 0.5)], $sorted[[int][Math]::Min($sorted.Count - 1, $sorted.Count * 0.95)], $sorted[-1]
    } finally {
        $s.Write("exit`r")
        $s.Stop()
    }
}

# One run of the Kitty a=q reply case: the host answers the query in <Form> and
# the client (Git Bash `read`, or the native vtreader exe) reports what reached
# its input. Returns rows (name, verdict, evidence).
function Invoke-KittyQRun([string]$Dll, [uint32]$F, [string]$Form, [string]$Client) {
    $s = New-Object CpProbe.Session -ArgumentList @(, $Dll)
    $s.ReplyForm = $Form
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        if ($Client -eq 'bash') {
            $cmd = '"{0}" --noprofile --norc "{1}"' -f $Bash, ($kqCase -replace '\\', '/')
        } else {
            $cmd = '"{0}"' -f $kqExe
        }
        if (-not $s.Start($F, $cmd, 80, 25)) {
            $rows.Add(@('start', 'failed', ('CreatePseudoConsole hr=0x{0:x8}' -f $s.Hr)))
            return , $rows
        }
        $done = $s.WaitFor("GOT:", 0, 15000)
        if ($done -ge 0) { $s.WaitFor("`n", $done, 8000) | Out-Null }
        $s.WaitQuiet(300, 2000)
        $bytes = $s.Bytes()
        [IO.File]::WriteAllBytes((Join-Path $OutDir ('{0}-{1}-{2}-{3}.bin' -f $script:Variant, $Form, $Client, $script:RunNo)), $bytes)
        $text = $latin1.GetString($bytes)
        $m = [regex]::Match($text, 'GOT:([0-9a-f]*)')
        if (-not $m.Success) {
            $rows.Add(@('kittyq', 'failed', ('no GOT line; output: ' + [CpProbe.Session]::Esc($bytes, 0, 4096, 600))))
            return , $rows
        }
        $hex = $m.Groups[1].Value
        $got = [byte[]]@(for ($i = 0; $i + 1 -lt $hex.Length; $i += 2) { [Convert]::ToByte($hex.Substring($i, 2), 16) })
        $e = [CpProbe.Session]::Esc($got, 0, $got.Length, 400)
        $str = $latin1.GetString($got)
        $v = if ($got.Length -eq 0) { 'nothing' }
            elseif ($str.Contains("$([char]27)_Gi=31;OK")) { 'plain arrives' }
            elseif ($str.Contains('i=31;OK')) { 'arrives, envelope lost' }
            else { 'other' }
        $rows.Add(@('kittyq', $v, "reply form $Form; client $Client; $($got.Length) bytes: $e; hex $hex; host replies: $($s.Replies -join ' ')"))
    } finally {
        $s.Stop()
    }
    , $rows
}

# ---- M8: OSC 5522 and mode 2033 -------------------------------------------------

$ESC = [string][char]27
$ST = $ESC + '\'

function ConvertTo-B64([string]$s) { [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($s)) }
function ConvertTo-HexString([string]$s) { (($latin1.GetBytes($s) | ForEach-Object { $_.ToString('x2') }) -join '') }
function ConvertFrom-HexString([string]$hex) {
    $hex = $hex -replace '\s', ''
    , [byte[]]@(for ($i = 0; $i + 1 -lt $hex.Length; $i += 2) { [Convert]::ToByte($hex.Substring($i, 2), 16) })
}
function Get-FreeMB { [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024) }

# Console host processes started by this probe (children of this PowerShell).
function Get-HostPids {
    @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$PID" |
        Where-Object { $_.Name -in 'conhost.exe', 'OpenConsole.exe' } | ForEach-Object { [int]$_.ProcessId })
}
function Get-PrivateBytes([int[]]$ProcIds) {
    $sum = 0L
    foreach ($i in $ProcIds) {
        try { $p = [Diagnostics.Process]::GetProcessById($i); $sum += $p.PrivateMemorySize64; $p.Dispose() } catch { }
    }
    $sum
}

# Start a headless client on the pseudo console. Native clients read their query from
# $QueryFile and stop at $Until (C-escaped for the vtreader exe).
function Start-Client($S, [uint32]$F, [string]$Client, [string]$Case, [string]$QueryFile, [string]$Until, [int]$WaitMs, [int]$GotMax) {
    if ($Client -eq 'bash') {
        $cmd = '"{0}" --noprofile --norc "{1}"' -f $Bash, ($Case -replace '\\', '/')
    } else {
        $env:FAKE_QUERY = ''
        $env:FAKE_QUERY_FILE = $QueryFile
        $env:FAKE_UNTIL = $Until
        $env:FAKE_WAIT_MS = [string]$WaitMs
        if ($GotMax -ge 0) { $env:FAKE_GOT_MAX = [string]$GotMax } else { Remove-Item Env:FAKE_GOT_MAX -ErrorAction SilentlyContinue }
        $cmd = '"{0}"' -f $vtExe
    }
    $S.Start($F, $cmd, 80, 25)
}

function Clear-FakeEnv { foreach ($n in 'FAKE_QUERY', 'FAKE_QUERY_FILE', 'FAKE_UNTIL', 'FAKE_WAIT_MS', 'FAKE_GOT_MAX') { Remove-Item "Env:$n" -ErrorAction SilentlyContinue } }

# Waits for the client's GOT: line while sampling the private bytes of the console hosts.
function Wait-Got($S, [int]$LimitMs, [string]$Final = 'GOT:') {
    Start-Sleep -Milliseconds 300
    $hostPids = Get-HostPids
    $names = @($hostPids | ForEach-Object { try { (Get-Process -Id $_ -ErrorAction Stop).ProcessName } catch { '?' } }) -join '+'
    $base = Get-PrivateBytes $hostPids
    $peak = $base
    $deadline = $S.Clock.ElapsedMilliseconds + $LimitMs
    $got = -1; $tGot = -1; $aborted = $false
    while ($true) {
        $got = $S.WaitFor($Final, 0, 200)
        $m = Get-PrivateBytes $hostPids
        if ($m -gt $peak) { $peak = $m }
        if ($got -ge 0) { $tGot = $S.Clock.ElapsedMilliseconds; break }
        if ($peak -gt 3GB) { $aborted = $true; break }
        if ($S.Clock.ElapsedMilliseconds -gt $deadline) { break }
    }
    if ($got -ge 0) { $S.WaitFor("`n", $got, 8000) | Out-Null }
    $S.WaitQuiet(300, 2000)
    $m = Get-PrivateBytes $hostPids
    if ($m -gt $peak) { $peak = $m }
    @{ got = $got; tGot = $tGot; peak = $peak; base = $base; aborted = $aborted; hosts = $names }
}

function Get-Verdict([bool]$Arrived, [bool]$Partial) { if ($Arrived) { 'arrived' } elseif ($Partial) { 'partial' } else { 'dropped' } }

# One run of the OSC 5522 case. $Client: bash | native. $Bytes: base64 bytes of the DATA reply.
# $Timing: native client, only the length and the head of the reply are printed; time and memory are rows.
function Invoke-K5522Run([string]$Dll, [uint32]$F, [string]$Client, [int]$Bytes, [bool]$Timing) {
    $rows = New-Object System.Collections.Generic.List[object]
    if ($Timing -and (Get-FreeMB) -lt 4096) { $rows.Add(@('timing', 'skipped', ('free RAM {0} MB < 4096' -f (Get-FreeMB)))); return , $rows }
    $s = New-Object CpProbe.Session -ArgumentList @(, $Dll)
    $s.Mode = 'k5522'
    $s.ReplyBytes = $Bytes
    $limit = if ($Timing) { $TimingLimitSec * 1000 } else { 25000 }
    $gotMax = if ($Timing) { 48 } else { -1 }
    try {
        if (-not (Start-Client $s $F $Client $k5522Case $k5522Query '\e]5522;type=read:status=DONE\e\\' $limit $gotMax)) {
            $rows.Add(@('start', 'failed', ('CreatePseudoConsole hr=0x{0:x8}' -f $s.Hr)))
            return , $rows
        }
        $w = Wait-Got $s $limit
        $raw = $s.Bytes()
        [IO.File]::WriteAllBytes((Join-Path $OutDir ('{0}-5522-{1}-{2}-{3}.bin' -f $script:Variant, $Client, $Bytes, $script:RunNo)), $raw)
        $text = $latin1.GetString($raw)
        $gotIdx = $text.IndexOf('GOT:')
        if ($gotIdx -lt 0) {
            $rows.Add(@('reply', 'failed', ('no GOT line{0}; output: {1}' -f $(if ($w.aborted) { ' (aborted, host memory over 3 GB)' } else { '' }), [CpProbe.Session]::Esc($raw, 0, 4096, 500))))
            if ($Timing) {
                $wr = if ($s.ReplyT1 -ge 0) { 'done in {0} ms' -f ($s.ReplyT1 - $s.ReplyT0) } else { 'not finished' }
                $rows.Add(@('timing', 'info', ('peak host private {0:N0} MB, base {1:N0} MB, hosts {2}; reply write {3}' -f ($w.peak / 1MB), ($w.base / 1MB), $w.hosts, $wr)))
            }
            return , $rows
        }
        # What the console passed on: the case's slice (bash), or all output before the GOT line (native).
        $scope = if ($Client -eq 'bash') { Get-Slice $text 'k5522' } else { $text.Substring(0, $gotIdx) }
        if ($null -eq $scope) { $scope = '' }
        $dbg = { param($pat) $m = [regex]::Matches($scope, $pat); (($m | ForEach-Object { Esc $_.Value 120 }) -join ' | ') }

        $d1 = $scope.Contains($ESC + '[?5522h')
        $rows.Add(@('decset', (Get-Verdict $d1 $false), ('ESC[?5522h in the output: {0}; ?-sequences seen: {1}' -f $d1, (& $dbg ($ESC + '\[\?[0-9;]*[hl]')))))
        $d2 = $scope.Contains($ESC + '[?5522$p')
        $rows.Add(@('decrqm', (Get-Verdict $d2 $false), ('ESC[?5522$p in the output: {0}; $p seen: {1}' -f $d2, (& $dbg ($ESC + '\[\?[0-9]*\$p')))))

        $wr = @(
            ($ESC + ']5522;type=write' + $ST),
            ($ESC + ']5522;type=wdata:mime=' + $k.mt + ';' + $k.dt + $ST),
            ($ESC + ']5522;type=wdata:mime=' + $k.mh + ';' + $k.dh + $ST),
            ($ESC + ']5522;type=wdata' + $ST))
        $nw = @($wr | Where-Object { $scope.Contains($_) }).Count
        $oscPat = $ESC + '\]5522[^\x07' + $ESC + ']*(' + $ESC + '\\|\x07)?'
        $rows.Add(@('osc-write', (Get-Verdict ($nw -eq 4) ($nw -gt 0)), ('{0} of 4 write/wdata OSCs byte-identical; OSC 5522 seen: {1}' -f $nw, (& $dbg $oscPat))))
        $rq = $ESC + ']5522;type=read;' + $k.rq + $ST
        $nr = $scope.Contains($rq)
        $rows.Add(@('osc-read', (Get-Verdict $nr ($scope.Contains($ESC + ']5522;type=read'))), ('read request byte-identical: {0}; host replies: {1}' -f $nr, ($s.Replies -join ' '))))

        # What the client read.
        $dec = @($s.Replies | Where-Object { $_ -like '*5522$p@*' })
        $decReply = if ($dec.Count) { $ESC + '[?5522;1$y' } else { '' }
        if (-not $s.LastReply) {
            $rows.Add(@('reply', 'nothing', 'the read request never reached the host, so no reply was written'))
        } elseif ($Client -eq 'bash') {
            $md = [regex]::Match($text, 'DECRQM:([0-9a-f]*)')
            $mg = [regex]::Match($text, 'GOT:([0-9a-f]*)')
            $expD = if ($dec.Count) { ConvertTo-HexString ($ESC + '[?5522;1$') } else { 'none' }
            $expG = ConvertTo-HexString ($s.LastReply.Replace($ST, $ESC))
            $gotG = $mg.Groups[1].Value
            $v = if ($gotG -eq $expG) { 'intact' } elseif ($gotG.Length -eq 0) { 'nothing' } else { 'altered' }
            $head = Esc ($latin1.GetString((ConvertFrom-HexString $gotG.Substring(0, [Math]::Min(120, $gotG.Length))))) 120
            $rows.Add(@('reply', $v, ('Git Bash read; DECRQM reply {0} (expected {1}); {2} of {3} expected bytes; head {4}' -f $(if ($md.Success -and $md.Groups[1].Value) { $md.Groups[1].Value } else { 'none' }), $expD, ($gotG.Length / 2), ($expG.Length / 2), $head)))
        } else {
            $mg = [regex]::Match($text, 'GOT:([0-9a-f]*)')
            $ml = [regex]::Match($text, 'LEN:(\d+)')
            $expLen = $decReply.Length + $s.LastReply.Length
            if ($Timing) {
                $len = if ($ml.Success) { [int]$ml.Groups[1].Value } else { -1 }
                $head = $latin1.GetString((ConvertFrom-HexString $mg.Groups[1].Value))
                $expHead = ($decReply + $s.LastReply).Substring(0, [Math]::Min(48, $expLen))
                $v = if ($len -eq $expLen -and $head -eq $expHead) { 'intact' } elseif ($len -le 0) { 'nothing' } else { 'altered' }
                $rows.Add(@('reply', $v, ('native read; {0} of {1} expected bytes; head {2}' -f $len, $expLen, (Esc $head 100))))
            } else {
                $got = $latin1.GetString((ConvertFrom-HexString $mg.Groups[1].Value))
                $v = if ($got -eq ($decReply + $s.LastReply)) { 'intact' } elseif ($got.Length -eq 0) { 'nothing' } else { 'altered' }
                $rows.Add(@('reply', $v, ('native read; {0} of {1} expected bytes; head {2}' -f $got.Length, $expLen, (Esc $got 120))))
            }
        }
        if ($Timing) {
            $writeMs = if ($s.ReplyT1 -ge 0) { $s.ReplyT1 - $s.ReplyT0 } else { -1 }
            $doneMs = if ($w.tGot -ge 0) { $w.tGot - $s.ReplyT0 } else { -1 }
            $rows.Add(@('timing', 'info', ('{0} reply bytes ({1} on the wire); host write finished {2} ms, client had everything {3} ms after the read request; peak host private {4:N0} MB (before {5:N0} MB); hosts {6}' -f $Bytes, $s.LastReply.Length, $writeMs, $doneMs, ($w.peak / 1MB), ($w.base / 1MB), $w.hosts)))
        }
    } finally {
        Clear-FakeEnv
        $s.Stop()
    }
    , $rows
}

# One run of the mode 2033 case.
function Invoke-VisRun([string]$Dll, [uint32]$F, [string]$Client) {
    $rows = New-Object System.Collections.Generic.List[object]
    $s = New-Object CpProbe.Session -ArgumentList @(, $Dll)
    $s.Mode = 'vis'
    try {
        if (-not (Start-Client $s $F $Client $visCase $visQuery '\x24y' 6000 -1)) {
            $rows.Add(@('start', 'failed', ('CreatePseudoConsole hr=0x{0:x8}' -f $s.Hr)))
            return , $rows
        }
        $w = Wait-Got $s 20000 $(if ($Client -eq 'bash') { 'GOT3:' } else { 'GOT:' })
        $raw = $s.Bytes()
        [IO.File]::WriteAllBytes((Join-Path $OutDir ('{0}-vis-{1}-{2}.bin' -f $script:Variant, $Client, $script:RunNo)), $raw)
        $text = $latin1.GetString($raw)
        $gotIdx = $text.IndexOf('GOT:')
        if ($gotIdx -lt 0) {
            $rows.Add(@('reply', 'failed', ('no GOT line; output: ' + [CpProbe.Session]::Esc($raw, 0, 4096, 500))))
            return , $rows
        }
        $scope = if ($Client -eq 'bash') { Get-Slice $text 'vis' } else { $text.Substring(0, $gotIdx) }
        if ($null -eq $scope) { $scope = '' }
        $a2033 = $scope.Contains($ESC + '[?2033h')
        $a998 = $scope.Contains($ESC + '[?998n')
        $aq = $scope.Contains($ESC + '[?2033$p')
        $qs = ([regex]::Matches($scope, $ESC + '\[\?[0-9;]*[hln]|' + $ESC + '\[\?[0-9]*\$p') | ForEach-Object { Esc $_.Value 40 }) -join ' '
        $rows.Add(@('decset-2033', (Get-Verdict $a2033 $false), ('ESC[?2033h in the output: {0}; ?-sequences seen: {1}' -f $a2033, $qs)))
        $rows.Add(@('dsr-998', (Get-Verdict $a998 $false), ('ESC[?998n in the output: {0}; host replies: {1}' -f $a998, ($s.Replies -join ' '))))
        $rows.Add(@('decrqm-2033', (Get-Verdict $aq $false), ('ESC[?2033$p in the output: {0}' -f $aq)))

        $exp = ''
        if ($a2033) { $exp += $ESC + '[?999;1n' }
        if ($a998) { $exp += $ESC + '[?999;1n' }
        if ($aq) { $exp += $ESC + '[?2033;2$y' }
        if ($Client -eq 'bash') {
            $parts = @(foreach ($n in 'GOT', 'GOT2', 'GOT3') { $m = [regex]::Match($text, "(?m)^${n}:([0-9a-f ]*)\r?$"); if ($m.Success) { $m.Groups[1].Value -replace '\s', '' } else { '' } })
            $all = $latin1.GetString((ConvertFrom-HexString ($parts[0] + '6e' + $parts[1] + '6e' + $parts[2] + '79')))
            $ev = 'Git Bash read; GOT {0} | GOT2 {1} | GOT3 {2}' -f (Esc ($latin1.GetString((ConvertFrom-HexString $parts[0]))) 60), (Esc ($latin1.GetString((ConvertFrom-HexString $parts[1]))) 60), (Esc ($latin1.GetString((ConvertFrom-HexString $parts[2]))) 60)
            $v = if ($exp -and $all -eq $exp) { 'intact' } elseif (-not ($parts -join '')) { 'nothing' } else { 'altered' }
            $rows.Add(@('reply', $v, ($ev + '; expected ' + (Esc $exp 80))))
        } else {
            $mg = [regex]::Match($text, 'GOT:([0-9a-f]*)')
            $got = $latin1.GetString((ConvertFrom-HexString $mg.Groups[1].Value))
            $v = if ($exp -and $got -eq $exp) { 'intact' } elseif ($got.Length -eq 0) { 'nothing' } else { 'altered' }
            $rows.Add(@('reply', $v, ('native read: {0}; expected {1}' -f (Esc $got 120), (Esc $exp 80))))
        }
    } finally {
        Clear-FakeEnv
        $s.Stop()
    }
    , $rows
}

$variants = @()
foreach ($f in $Flags) { $variants += , @("inbox-f$f", $null, $f) }
if ($dll) { foreach ($f in $Flags) { $variants += , @("bundled-f$f", $dll, $f) } }

if ($KittyQ) {
    $kqCase = Join-Path $PSScriptRoot 'cases\headless-kittyq.sh'
    Import-Module (Join-Path $PSScriptRoot '..\lib\FakeExe.psm1') -Force
    $kqExe = New-FakeExe -Path (Join-Path $OutDir 'vtreader.exe') -Kind vtreader
    # \e _ G ... a=q ... \e \ : the shape of a Kitty graphics support query
    $env:FAKE_QUERY = '\e_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\e\\'
    $env:FAKE_WAIT_MS = '2000'
    $csv = Join-Path $OutDir 'headless-kittyq.csv'
    Set-Content -LiteralPath $csv -Value 'variant,run,form,client,verdict,evidence' -Encoding UTF8
    $failed = 0
    foreach ($v in $variants) {
        $script:Variant = $v[0]
        foreach ($form in $ReplyForm) {
            foreach ($client in 'bash', 'native') {
                for ($run = 1; $run -le $Repeat; $run++) {
                    $script:RunNo = $run
                    foreach ($r in (Invoke-KittyQRun $v[1] $v[2] $form $client)) {
                        if ($r[1] -eq 'failed') { $failed++ }
                        Add-Content -LiteralPath $csv -Value ('{0},{1},{2},{3},{4},"{5}"' -f $v[0], $run, $form, $client, $r[1], ($r[2] -replace '"', "'")) -Encoding UTF8
                        Write-Output ('ROW {0} run={1} form={2} client={3} -> {4} | {5}' -f $v[0], $run, $form, $client, $r[1], $r[2])
                    }
                }
            }
        }
    }
    exit $(if ($failed) { 1 } else { 0 })
}


if ($Kitty5522 -or $Visibility) {
    Import-Module (Join-Path $PSScriptRoot '..\lib\FakeExe.psm1') -Force
    # always rebuilt: the vtreader needs FAKE_QUERY_FILE, FAKE_UNTIL and FAKE_GOT_MAX
    $vtExe = Join-Path $OutDir 'vtreader-m8.exe'
    Remove-Item -LiteralPath $vtExe -Force -ErrorAction SilentlyContinue
    $vtExe = New-FakeExe -Path $vtExe -Kind vtreader
    $k = @{
        mt = ConvertTo-B64 'text/plain'; mh = ConvertTo-B64 'text/html'
        dt = ConvertTo-B64 'probe-text'; dh = ConvertTo-B64 '<b>probe-html</b>'; rq = ConvertTo-B64 'text/plain .'
    }
    $k5522Case = Join-Path $PSScriptRoot 'cases\headless-5522.sh'
    $visCase = Join-Path $PSScriptRoot 'cases\probe-2033.sh'
    $k5522Query = Join-Path $OutDir 'query-5522.bin'
    [IO.File]::WriteAllBytes($k5522Query, $latin1.GetBytes(
            ($ESC + '[?5522h' + $ESC + '[?5522$p' +
                $ESC + ']5522;type=write' + $ST +
                $ESC + ']5522;type=wdata:mime=' + $k.mt + ';' + $k.dt + $ST +
                $ESC + ']5522;type=wdata:mime=' + $k.mh + ';' + $k.dh + $ST +
                $ESC + ']5522;type=wdata' + $ST +
                $ESC + ']5522;type=read;' + $k.rq + $ST)))
    $visQuery = Join-Path $OutDir 'query-2033.bin'
    [IO.File]::WriteAllBytes($visQuery, $latin1.GetBytes($ESC + '[?2033h' + $ESC + '[?998n' + $ESC + '[?2033$p'))
    $csv = Join-Path $OutDir 'headless-m8.csv'
    Set-Content -LiteralPath $csv -Value 'mode,variant,run,client,bytes,sequence,verdict,evidence' -Encoding UTF8
    $failed = 0
    function Write-ProbeRows($Mode, $V, $Run, $Client, $Bytes, $Rows) {
        foreach ($r in $Rows) {
            if ($r[1] -eq 'failed') { $script:failed++ }
            Add-Content -LiteralPath $csv -Value ('{0},{1},{2},{3},{4},{5},{6},"{7}"' -f $Mode, $V, $Run, $Client, $Bytes, $r[0], $r[1], ($r[2] -replace '"', "'")) -Encoding UTF8
            Write-Output ('ROW {0} {1} run={2} client={3} bytes={4} {5} -> {6} | {7}' -f $Mode, $V, $Run, $Client, $Bytes, $r[0], $r[1], $r[2])
        }
    }
    Write-Output ('INFO build {0}; free RAM {1} MB; bundled {2}' -f [Environment]::OSVersion.Version, (Get-FreeMB), $(if ($dll) { $dll } else { 'none' }))
    foreach ($v in $variants) {
        $script:Variant = $v[0]
        for ($run = 1; $run -le $Repeat; $run++) {
            $script:RunNo = $run
            if ($Kitty5522) {
                foreach ($client in 'bash', 'native') {
                    Write-ProbeRows '5522' $v[0] $run $client $ReplyBytes (Invoke-K5522Run $v[1] $v[2] $client $ReplyBytes $false)
                }
                foreach ($n in $TimingBytes) {
                    Write-ProbeRows '5522' $v[0] $run 'native' $n (Invoke-K5522Run $v[1] $v[2] 'native' $n $true)
                }
            }
            if ($Visibility) {
                foreach ($client in 'bash', 'native') {
                    Write-ProbeRows 'vis' $v[0] $run $client 0 (Invoke-VisRun $v[1] $v[2] $client)
                }
            }
        }
    }
    exit $(if ($failed) { 1 } else { 0 })
}
$csv = Join-Path $OutDir 'headless.csv'
Set-Content -LiteralPath $csv -Value 'variant,run,sequence,verdict,evidence' -Encoding UTF8
$failed = 0
foreach ($v in $variants) {
    $script:Variant = $v[0]
    for ($run = 1; $run -le $Repeat; $run++) {
        $script:RunNo = $run
        foreach ($r in (Invoke-SeqRun $v[1] $v[2])) {
            if ($r[1] -eq 'failed') { $failed++ }
            Add-Content -LiteralPath $csv -Value ('{0},{1},{2},{3},"{4}"' -f $v[0], $run, $r[0], $r[1], ($r[2] -replace '"', "'")) -Encoding UTF8
            Write-Output ('ROW {0} run={1} {2} -> {3} | {4}' -f $v[0], $run, $r[0], $r[1], $r[2])
        }
    }
    if ($Samples -gt 0) {
        $lat = Invoke-Latency $v[1] $v[2]
        Add-Content -LiteralPath $csv -Value ('{0},1,latency,info,"{1}"' -f $v[0], $lat) -Encoding UTF8
        Write-Output ('ROW {0} latency -> {1}' -f $v[0], $lat)
    }
}
exit $(if ($failed) { 1 } else { 0 })
