<#
.SYNOPSIS
Headless check that the shells Ghostty starts on Windows mark their prompt
with OSC 133 through the inbox ConPTY (no Ghostty window, no desktop).

.DESCRIPTION
Each case runs a shell in a pseudoconsole with the environment Ghostty's
shell integration gives it (src/termio/shell_integration.zig), a sandbox HOME
and the repo's src/ as GHOSTTY_RESOURCES_DIR, waits for the prompt, types one
line and reads the raw ConPTY output. A prompt counts as marked when the
output after the last 133;A holds a 133;B: that is what puts the cursor at a
prompt for `confirm-close-surface = true` (Terminal.cursorIsAtPrompt).

  bash             Git Bash with the bash integration (ENV + --posix)
  bash-zdotdir     the same, and ZDOTDIR is the user's again afterwards
  bash-exec-zsh    ~/.bashrc ends in `exec zsh` (the usual way to get zsh in
                   Git Bash): the zsh inherits the zsh integration
  zsh-drive        zsh with ZDOTDIR=C:/.../shell-integration/zsh
  zsh-backslash    zsh with ZDOTDIR=C:\...\shell-integration\zsh
  zsh-path         the path feature adds no `C:/...` dir to PATH under MSYS
  pwsh             pwsh -NoProfile with the ghostty.ps1 -Command
  cmd              cmd.exe with the marked PROMPT

Cases whose shell is missing are skipped. Exit code 1 when a case fails.
Keep this file ASCII only.
#>
param(
    [string]$GitDir = 'C:\Program Files\Git',
    [int]$WaitMs = 5000,
    # Keep the sandbox with the raw output of every case (<case>.bin).
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class ShellMarksPty {
    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO { public int cb; public string r, d, t; public int x, y, xs, ys, xc, yc, fa, fl; public short sw, cb2; public IntPtr r2, i, o, e; }
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFOEX { public STARTUPINFO si; public IntPtr attr; }
    [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr hp, ht; public int pid, tid; }
    [DllImport("kernel32.dll")] static extern int CreatePseudoConsole(COORD c, SafeFileHandle i, SafeFileHandle o, uint f, out IntPtr h);
    [DllImport("kernel32.dll")] static extern void ClosePseudoConsole(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out SafeFileHandle r, out SafeFileHandle w, IntPtr a, int s);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr l, int c, int f, ref IntPtr s);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr l, uint f, IntPtr a, IntPtr v, IntPtr s, IntPtr p, IntPtr r);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inh, uint flags, string env, string cwd, ref STARTUPINFOEX si, out PI pi);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint c);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    // Runs `cmdline` in an 80x24 pseudoconsole, types `input` after `waitMs`
    // and returns everything the pseudoconsole wrote by `waitMs` later.
    public static byte[] Run(string cmdline, string env, string cwd, string input, int waitMs) {
        SafeFileHandle inR, inW, outR, outW;
        CreatePipe(out inR, out inW, IntPtr.Zero, 0);
        CreatePipe(out outR, out outW, IntPtr.Zero, 0);
        IntPtr hpc;
        int hr = CreatePseudoConsole(new COORD { X = 80, Y = 24 }, inR, outW, 0, out hpc);
        if (hr != 0) throw new Exception("CreatePseudoConsole hr=" + hr);
        inR.Dispose(); outW.Dispose();
        IntPtr size = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        IntPtr list = Marshal.AllocHGlobal(size);
        InitializeProcThreadAttributeList(list, 1, 0, ref size);
        // PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
        UpdateProcThreadAttribute(list, 0, (IntPtr)0x20016, hpc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero);
        var si = new STARTUPINFOEX();
        si.si.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        // STARTF_USESTDHANDLES with no handles: the child must not inherit
        // this script's redirected stdio instead of the pseudoconsole.
        si.si.fl = 0x100;
        si.attr = list;
        PI pi;
        // EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT
        if (!CreateProcessW(null, new StringBuilder(cmdline), IntPtr.Zero, IntPtr.Zero, false, 0x00080400, env, cwd, ref si, out pi))
            throw new Exception("CreateProcess error=" + Marshal.GetLastWin32Error());
        var ms = new MemoryStream();
        var outFs = new FileStream(outR, FileAccess.Read);
        var inFs = new FileStream(inW, FileAccess.Write);
        var reader = new Thread(() => {
            var buf = new byte[65536];
            try { int n; while ((n = outFs.Read(buf, 0, buf.Length)) > 0) lock (ms) ms.Write(buf, 0, n); } catch { }
        });
        reader.IsBackground = true;
        reader.Start();
        Thread.Sleep(waitMs);
        var b = Encoding.UTF8.GetBytes(input);
        inFs.Write(b, 0, b.Length);
        inFs.Flush();
        Thread.Sleep(waitMs);
        byte[] result;
        lock (ms) result = ms.ToArray();
        TerminateProcess(pi.hp, 0);
        ClosePseudoConsole(hpc);
        CloseHandle(pi.hp);
        CloseHandle(pi.ht);
        Marshal.FreeHGlobal(list);
        return result;
    }
}
'@

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$resWin = Join-Path $repo 'src'
# The bash integration hands MSYS the mixed form (shell_integration.zig).
$resMixed = $resWin -replace '\\', '/'
$bash = Join-Path $GitDir 'bin\bash.exe'
$zsh = Join-Path $GitDir 'usr\bin\zsh.exe'
$pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = 'pwsh.exe' }
$cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("ghostty-shell-marks-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandbox | Out-Null

function New-Home([string]$Name, [hashtable]$Files) {
    $h = Join-Path $sandbox $Name
    New-Item -ItemType Directory -Path $h | Out-Null
    foreach ($k in $Files.Keys) {
        [IO.File]::WriteAllText((Join-Path $h $k), $Files[$k].Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
    }
    $h
}

function Get-EnvBlock([string]$HomeDir, [hashtable]$Extra) {
    $envs = @{}
    foreach ($e in [Environment]::GetEnvironmentVariables().GetEnumerator()) { $envs[$e.Key] = $e.Value }
    foreach ($k in 'ENV', 'ZDOTDIR', 'BASH_ENV', 'GHOSTTY_BASH_INJECT', 'GHOSTTY_ZSH_ZDOTDIR', 'HISTFILE') { $envs.Remove($k) }
    $envs['HOME'] = $HomeDir
    $envs['TERM'] = 'xterm-256color'
    $envs['TERM_PROGRAM'] = 'ghostty'
    $envs['GHOSTTY_SHELL_FEATURES'] = 'cursor,title'
    $envs['HISTFILE'] = Join-Path $HomeDir 'history'
    foreach ($k in $Extra.Keys) { $envs[$k] = $Extra[$k] }
    $sb = New-Object Text.StringBuilder
    foreach ($k in ($envs.Keys | Sort-Object)) { [void]$sb.Append("$k=$($envs[$k])`0") }
    [void]$sb.Append("`0")
    $sb.ToString()
}

function Get-BashEnv {
    @{ ENV = "$resMixed/shell-integration/bash/ghostty.bash"; GHOSTTY_BASH_INJECT = '1'; GHOSTTY_RESOURCES_DIR = $resMixed }
}

# Whether the last prompt in `text` is marked: a 133;A (or 133;P;k=i) and,
# after it, a 133;B.
function Test-PromptMarked([string]$Text) {
    $a = [Math]::Max($Text.LastIndexOf("`e]133;A"), $Text.LastIndexOf("`e]133;P;k=i"))
    if ($a -lt 0) { return $false }
    $Text.IndexOf("`e]133;B", $a) -ge 0
}

$cases = @(
    @{
        Name = 'bash'; Exe = $bash; Args = '--posix'; Input = "echo sum-`$((40+2))`r"
        Home = @{ '.bashrc' = 'PS1=''bash$ ''' + "`n" }; Env = (Get-BashEnv); Expect = 'sum-42'
    },
    @{
        Name = 'bash-zdotdir'; Exe = $bash; Args = '--posix'; Input = "echo Z=`${ZDOTDIR-unset}`r"
        Home = @{ '.bashrc' = 'PS1=''bash$ ''' + "`n" }; Env = (Get-BashEnv); Expect = 'Z=unset'
    },
    @{
        Name = 'bash-exec-zsh'; Exe = $bash; Args = '--posix'; Input = "echo in-`$ZSH_NAME`r"
        Home = @{ '.bashrc' = "if [ -t 1 ]; then exec zsh; fi`n"; '.zshrc' = "PROMPT='zsh%% '`n" }
        Env = (Get-BashEnv); Expect = 'in-zsh'; Needs = $zsh
    },
    @{
        Name = 'zsh-drive'; Exe = $zsh; Args = '-i'; Input = "echo in-`$ZSH_NAME`r"
        Home = @{ '.zshrc' = "PROMPT='zsh%% '`n" }
        Env = @{ ZDOTDIR = "$resMixed/shell-integration/zsh"; GHOSTTY_RESOURCES_DIR = $resWin }; Expect = 'in-zsh'
    },
    @{
        Name = 'zsh-backslash'; Exe = $zsh; Args = '-i'; Input = "echo in-`$ZSH_NAME`r"
        Home = @{ '.zshrc' = "PROMPT='zsh%% '`n" }
        Env = @{ ZDOTDIR = "$resWin\shell-integration\zsh"; GHOSTTY_RESOURCES_DIR = $resWin }; Expect = 'in-zsh'
    },
    @{
        # The quotes keep the typed line from matching the expected output.
        Name = 'zsh-path'; Exe = $zsh; Args = '-i'; Expect = 'path-ok'
        Input = "case :`$PATH: in *ghostty-bin-probe*) echo pa''th-bad;; *) echo pa''th-ok;; esac`r"
        Home = @{ '.zshrc' = "PROMPT='zsh%% '`n" }
        Env = @{
            ZDOTDIR = "$resMixed/shell-integration/zsh"; GHOSTTY_RESOURCES_DIR = $resMixed
            GHOSTTY_SHELL_FEATURES = 'cursor,title,path'; GHOSTTY_BIN_DIR = "$resMixed/ghostty-bin-probe"
        }
    },
    @{
        Name = 'pwsh'; Exe = $pwsh; Input = "'ps-' + (40+2)`r"; Home = @{}; Env = @{}; Expect = 'ps-42'
        Args = "-NoLogo -NoProfile -NoExit -Command `". ([scriptblock]::Create([IO.File]::ReadAllText('$resWin\shell-integration\pwsh\ghostty.ps1')))`""
    },
    @{
        # The PROMPT setupCmd builds with the title feature.
        Name = 'cmd'; Exe = $cmd; Args = ''; Input = "echo cmd-%OS%`r"; Home = @{}; Expect = 'cmd-Windows_NT'
        Env = @{ PROMPT = '$e]133;D$e\$e]133;A$e\$e]2;$P$e\$e]7;kitty-shell-cwd:///$P$e\$P$G$e]133;B$e\' }
    }
)

$failed = 0
try {
    foreach ($c in $cases) {
        $need = if ($c.Needs) { $c.Needs } else { $c.Exe }
        if (-not (Test-Path -LiteralPath $c.Exe) -or -not (Test-Path -LiteralPath $need)) {
            Write-Host "SKIP $($c.Name): $need not found"
            continue
        }
        $h = New-Home $c.Name $c.Home
        $bytes = [ShellMarksPty]::Run("`"$($c.Exe)`" $($c.Args)", (Get-EnvBlock $h $c.Env), $h, $c.Input, $WaitMs)
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        [IO.File]::WriteAllBytes((Join-Path $sandbox "$($c.Name).bin"), $bytes)
        $problems = @()
        if ($text.IndexOf($c.Expect) -lt 0) { $problems += "no '$($c.Expect)' in the output" }
        if (-not (Test-PromptMarked $text)) { $problems += 'the last prompt has no OSC 133 A..B' }
        if ($problems.Count) {
            $failed++
            Write-Host "FAIL $($c.Name): $($problems -join '; ') (raw: $sandbox\$($c.Name).bin)"
        } else {
            Write-Host "PASS $($c.Name)"
        }
    }
} finally {
    if ($Keep) { Write-Host "raw output: $sandbox" }
    elseif ($failed -eq 0) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($failed) { exit 1 }
