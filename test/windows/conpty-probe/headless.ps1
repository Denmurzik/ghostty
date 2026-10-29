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
                scanned = buf.Count;
                Monitor.PulseAll(gate);
            }
            foreach (string a in answers) Write(a);
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
