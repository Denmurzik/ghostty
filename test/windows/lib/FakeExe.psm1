# Fake console programs for scenarios (Windows PowerShell 5.1): C# compiled
# once per sandbox with Add-Type -OutputType ConsoleApplication, so a run
# needs no Zig and no installed tool. Importers: Import-Module <this> -Force.
#
#   New-FakeExe -Path <exe> -Kind argv
#       prints a line "ARGV:" and then every argv element on its own line, "CWD:<cwd>",
#       "TERM:<TERM>", then the first stdin line as "STDIN:<line>"; the exit
#       code is the env var FAKE_EXIT (default 0).
#   New-FakeExe -Path <exe> -Kind osc7
#       writes ESC ] 7 ; file://fake/<FAKE_OSC7_PATH> BEL, then behaves as
#       argv (the stdin line is the wait).
#   New-FakeExe -Path <exe> -Kind vtreader
#       sets ENABLE_VIRTUAL_TERMINAL_INPUT on raw input, writes FAKE_QUERY
#       (C-escaped: \e \a \r \n \t \\ \xNN) to stdout, reads stdin for
#       FAKE_WAIT_MS (default 2000), prints "GOT:" + the hex of what arrived.
#   New-FakeExe -SelfTest
#       compiles the three kinds into %TEMP% and runs argv once; no window.
Set-StrictMode -Version Latest

$script:ArgvSource = @'
using System;
using System.IO;
using System.Text;

public static class FakeExeProgram {
    static readonly bool Osc7 = KIND_IS_OSC7;

    public static int Main(string[] args) {
        Stream o = Console.OpenStandardOutput();
        if (Osc7) {
            string p = Environment.GetEnvironmentVariable("FAKE_OSC7_PATH") ?? "";
            Write(o, "\u001b]7;file://fake/" + p + "\u0007");
        }
        StringBuilder sb = new StringBuilder();
        sb.Append("ARGV:\n");
        foreach (string a in args) sb.Append(a + "\n");
        sb.Append("CWD:" + Environment.CurrentDirectory + "\n");
        sb.Append("TERM:" + (Environment.GetEnvironmentVariable("TERM") ?? "") + "\n");
        Write(o, sb.ToString());
        string line = null;
        try { line = Console.In.ReadLine(); } catch (Exception) { }
        Write(o, "STDIN:" + (line ?? "") + "\n");
        int code = 0;
        int.TryParse(Environment.GetEnvironmentVariable("FAKE_EXIT"), out code);
        return code;
    }

    static void Write(Stream o, string s) {
        byte[] b = new UTF8Encoding(false).GetBytes(s);
        o.Write(b, 0, b.Length);
        o.Flush();
    }
}
'@

$script:VtReaderSource = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class FakeExeProgram {
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint m);
    [DllImport("kernel32.dll")] static extern bool ReadFile(IntPtr h, byte[] buf, uint n, out uint got, IntPtr ov);

    static readonly object Lock = new object();
    static readonly MemoryStream Got = new MemoryStream();

    public static int Main(string[] args) {
        IntPtr hin = GetStdHandle(-10);
        uint mode;
        if (GetConsoleMode(hin, out mode)) {
            // raw: no echo (4), no line input (2), no processed input (1); VT input (0x200)
            mode = (mode & ~(uint)7) | 0x200u;
            SetConsoleMode(hin, mode);
        }

        string q = Environment.GetEnvironmentVariable("FAKE_QUERY") ?? "";
        Stream o = Console.OpenStandardOutput();
        byte[] qb = Encoding.UTF8.GetBytes(Unescape(q));
        o.Write(qb, 0, qb.Length);
        o.Flush();

        int wait = 2000;
        int.TryParse(Environment.GetEnvironmentVariable("FAKE_WAIT_MS"), out wait);
        if (wait <= 0) wait = 2000;

        Thread t = new Thread(delegate() {
            byte[] buf = new byte[256];
            while (true) {
                uint n;
                if (!ReadFile(hin, buf, (uint)buf.Length, out n, IntPtr.Zero) || n == 0) return;
                lock (Lock) { Got.Write(buf, 0, (int)n); }
            }
        });
        t.IsBackground = true;
        t.Start();
        Thread.Sleep(wait);

        byte[] all;
        lock (Lock) { all = Got.ToArray(); }
        StringBuilder sb = new StringBuilder("GOT:");
        foreach (byte b in all) sb.Append(b.ToString("x2"));
        sb.Append("\n");
        byte[] ob = Encoding.UTF8.GetBytes(sb.ToString());
        o.Write(ob, 0, ob.Length);
        o.Flush();
        Environment.Exit(0);
        return 0;
    }

    static string Unescape(string s) {
        StringBuilder r = new StringBuilder();
        for (int i = 0; i < s.Length; i++) {
            char c = s[i];
            if (c != '\\' || i + 1 >= s.Length) { r.Append(c); continue; }
            char n = s[++i];
            switch (n) {
                case 'e': r.Append('\u001b'); break;
                case 'a': r.Append('\u0007'); break;
                case 'r': r.Append('\r'); break;
                case 'n': r.Append('\n'); break;
                case 't': r.Append('\t'); break;
                case '\\': r.Append('\\'); break;
                case 'x':
                    if (i + 2 < s.Length && Uri.IsHexDigit(s[i + 1]) && Uri.IsHexDigit(s[i + 2])) {
                        r.Append((char)Convert.ToInt32(s.Substring(i + 1, 2), 16));
                        i += 2;
                    } else r.Append("\\x");
                    break;
                default: r.Append('\\').Append(n); break;
            }
        }
        return r.ToString();
    }
}
'@

function New-FakeExe {
    [CmdletBinding(DefaultParameterSetName = 'Build')]
    param(
        [Parameter(ParameterSetName = 'Build', Mandatory)][string]$Path,
        [Parameter(ParameterSetName = 'Build', Mandatory)][ValidateSet('argv', 'osc7', 'vtreader')][string]$Kind,
        [Parameter(ParameterSetName = 'SelfTest', Mandatory)][switch]$SelfTest
    )
    $ErrorActionPreference = 'Stop'

    if ($SelfTest) { return Invoke-FakeExeSelfTest }

    # Compiled once: an existing file is kept.
    if (Test-Path -LiteralPath $Path) { return $Path }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $src = switch ($Kind) {
        'argv'     { $script:ArgvSource.Replace('KIND_IS_OSC7', 'false') }
        'osc7'     { $script:ArgvSource.Replace('KIND_IS_OSC7', 'true') }
        'vtreader' { $script:VtReaderSource }
    }
    # OutputAssembly keeps the type out of this session; a second Add-Type of
    # the same class name would otherwise collide.
    Add-Type -TypeDefinition $src -Language CSharp -OutputType ConsoleApplication -OutputAssembly $Path
    if (-not (Test-Path -LiteralPath $Path)) { throw "New-FakeExe: $Path was not written" }
    $Path
}

function Invoke-FakeExeSelfTest {
    $root = Join-Path $env:TEMP ('fakeexe-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    try {
        foreach ($k in 'argv', 'osc7', 'vtreader') {
            $exe = New-FakeExe -Path (Join-Path $root "$k.exe") -Kind $k
            if (-not (Test-Path -LiteralPath $exe)) { throw "self-test: $k.exe missing" }
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $root 'argv.exe'
        $psi.Arguments = 'one "two words"'
        $psi.WorkingDirectory = $root
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.EnvironmentVariables['FAKE_EXIT'] = '3'
        $psi.EnvironmentVariables['TERM'] = 'xterm-fake'
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.WriteLine('hello')
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(10000)) { $p.Kill(); throw 'self-test: argv.exe did not exit' }

        $lines = @($out -split "`r?`n")
        foreach ($want in 'ARGV:', 'one', 'two words', 'TERM:xterm-fake', 'STDIN:hello') {
            if ($lines -notcontains $want) { throw "self-test: argv output lacks '$want': $out" }
        }
        if (-not ($lines | Where-Object { $_ -like 'CWD:*' })) { throw "self-test: no CWD line: $out" }
        if ($p.ExitCode -ne 3) { throw "self-test: exit code $($p.ExitCode), expected 3 (FAKE_EXIT)" }
        Write-Host 'FakeExe self-test: ok (argv, osc7 and vtreader compile; argv runs)'
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function New-FakeExe
