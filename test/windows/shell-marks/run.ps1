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
  bash-zdotdir-env a ZDOTDIR from the environment survives `exec zsh`
  bash-zdotdir-rc  so does `export ZDOTDIR="${ZDOTDIR:-...}"` in ~/.bashrc
  bash-zdotdir-leak  what ~/.bashrc starts sees no ZDOTDIR
  bash-trap-gone   the handoff trap is gone after the startup files
  bash-trap-chained  a user DEBUG trap chaining ours survives, no errors
  bash-last-arg    `cd "$_"` in ~/.bashrc still works under the trap
  bash-exec-zsh    ~/.bashrc ends in `exec zsh` (the usual way to get zsh in
                   Git Bash): the zsh inherits the zsh integration
  zsh-drive        zsh with ZDOTDIR=C:/.../shell-integration/zsh
  zsh-backslash    zsh with ZDOTDIR=C:\...\shell-integration\zsh
  zsh-path         the path feature adds no `C:/...` dir to PATH under MSYS
  pwsh             pwsh -NoProfile with the ghostty.ps1 -Command
  pwsh-exit        the 133;D codes: a native exit 3 twice (both 3), a cmdlet
                   failure (1), success (0); $LASTEXITCODE stays the user's
  pwsh-strict      Set-StrictMode before any native command: no prompt error
  pwsh-noreadline  no PSReadLine: A..B, no D, $LASTEXITCODE untouched
  pwsh-userprompt  a user prompt running a native command is chained
  powershell-*     the pwsh cases on Windows PowerShell 5.1 (PSReadLine 2.0)
  cmd             cmd.exe with the marked PROMPT
  cmd-busy         cmd running `ping -t`: the ping is the shell's only child,
                   the idle prompt has none (what Exec.shellBusy counts)
  pwsh-cursor     the cursor feature: ESC[5 q before 133;B, ESC[0 q after 133;C
  pwsh-ssh-env     ssh-env: `ssh -p 2222 'host one'` reaches a fake ssh.exe through
                   `ghostty +ssh` with SendEnv options and unsplit arguments
  pwsh-ssh-terminfo  ssh-terminfo: the terminfo goes to the first call's stdin,
                   the second call is cached (TERM=xterm-ghostty)
  pwsh-no-ssh      no ssh feature: ssh is the fake itself, no wrapper
  cmd-cursor       the cursor feature in the cmd PROMPT
  cmd-ssh-env      ssh-env: shell-integration\cmd\ssh.cmd shadows ssh
  (the ssh cases need zig-out\bin\ghostty.exe; the fakes are FakeExe.psm1's
  argv program and a small logging one, compiled with Windows PowerShell 5.1)

Cases whose shell is missing are skipped. Exit code 1 when a case fails.
Keep this file ASCII only.
#>
param(
    [string]$GitDir = 'C:\Program Files\Git',
    [int]$WaitMs = 5000,
    # Run only the cases whose name matches this wildcard.
    [string]$Only = '*',
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

    // What `probe` said about the shell right before the input and at the
    // end, as "<before>|<after>".
    public static string Probed;

    public static byte[] Run(string cmdline, string env, string cwd, string input, int waitMs) {
        return Run(cmdline, env, cwd, input, waitMs, null);
    }

    // Runs `cmdline` in an 80x24 pseudoconsole, types `input` after `waitMs`
    // and returns everything the pseudoconsole wrote by `waitMs` later.
    // `probe` (may be null) gets the shell's process id before the input and
    // at the end.
    public static byte[] Run(string cmdline, string env, string cwd, string input, int waitMs, Func<int, string> probe) {
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
        string before = probe == null ? "" : probe(pi.pid);
        // U+0001 in the input is a pause: what follows is typed after waitMs
        // (a fake ssh.exe reading a stdin line gets it past the line editor).
        var chunks = input.Split('\u0001');
        for (int i = 0; i < chunks.Length; i++) {
            if (i > 0) Thread.Sleep(waitMs);
            var b = Encoding.UTF8.GetBytes(chunks[i]);
            inFs.Write(b, 0, b.Length);
            inFs.Flush();
        }
        Thread.Sleep(waitMs);
        Probed = probe == null ? null : before + "|" + probe(pi.pid);
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
$winps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
# The PROMPT setupCmd builds with the title feature.
$cmdPrompt = '$e]133;D$e\$e]133;A$e\$e]2;$P$e\$e]7;kitty-shell-cwd:///$P$e\$P$G$e]133;B$e\'
# The same with the cursor feature (setupCmd puts the bar before the B mark).
$cmdPromptBar = $cmdPrompt.Replace('$e]133;B', '$e[5 q$e]133;B')
$ghosttyBin = Join-Path $repo 'zig-out\bin'
$ghosttyExe = Join-Path $ghosttyBin 'ghostty.exe'
$winpsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# The images of the shell's child processes other than console hosts, as
# Ghostty's close confirmation counts them for cmd (Exec.shellBusy).
$childProbe = [Func[int, string]] {
    param([int]$ShellPid)
    $names = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ShellPid" |
            Where-Object { $_.Name -notin 'conhost.exe', 'OpenConsole.exe' } |
            ForEach-Object { $_.Name.ToLowerInvariant() })
    ($names | Sort-Object) -join ','
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("ghostty-shell-marks-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandbox | Out-Null

# Fake ssh.exe programs for the ssh cases, built once with Windows PowerShell
# 5.1 (Add-Type -OutputAssembly does not exist in pwsh 7). The directory of
# each goes first on the case's PATH, where `ghostty +ssh` finds it as `ssh`.
#   argv: FakeExe.psm1's program; prints ARGV:, CWD:, TERM:, STDIN: and exits
#         with FAKE_EXIT.
#   log:  answers `ssh -G` (user, hostname, port), and appends every other
#         call to FAKE_LOG: "CALL", the argv, "TERM:<TERM>" and, when stdin
#         is a pipe (the terminfo install), "STDIN:<first line>".
$logFakeSource = @'
using System;
using System.IO;
using System.Text;

public static class FakeSsh {
    public static int Main(string[] args) {
        if (args.Length > 0 && args[0] == "-G") {
            Console.Out.Write("user fakeuser\nhostname fakehost\nport 22\n");
            return 0;
        }
        string stdin = null;
        try { if (Console.IsInputRedirected) stdin = Console.In.ReadLine(); } catch (Exception) { }
        StringBuilder sb = new StringBuilder("CALL\nARGV:\n");
        foreach (string a in args) sb.Append(a + "\n");
        sb.Append("TERM:" + (Environment.GetEnvironmentVariable("TERM") ?? "") + "\n");
        if (stdin != null) sb.Append("STDIN:" + stdin + "\n");
        File.AppendAllText(Environment.GetEnvironmentVariable("FAKE_LOG"), sb.ToString());
        return 0;
    }
}
'@

function New-FakeSshDir([string]$Kind) {
    $dir = Join-Path $sandbox "fake-$Kind"
    $exe = Join-Path $dir 'ssh.exe'
    if (Test-Path -LiteralPath $exe) { return $dir }
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script = Join-Path $sandbox "build-fake-$Kind.ps1"
    if ($Kind -eq 'argv') {
        $module = Join-Path $repo 'test\windows\lib\FakeExe.psm1'
        $body = "Import-Module '$module' -Force; New-FakeExe -Path '$exe' -Kind argv | Out-Null"
    } else {
        $srcFile = Join-Path $sandbox 'fake-ssh-log.cs'
        [IO.File]::WriteAllText($srcFile, $logFakeSource)
        $body = "Add-Type -TypeDefinition ([IO.File]::ReadAllText('$srcFile')) -Language CSharp -OutputType ConsoleApplication -OutputAssembly '$exe'"
    }
    [IO.File]::WriteAllText($script, "`$ErrorActionPreference = 'Stop'`r`n$body`r`n")
    & $winpsExe -NoProfile -ExecutionPolicy Bypass -File $script | Out-Null
    if (-not (Test-Path -LiteralPath $exe)) { throw "could not build the fake ssh ($Kind)" }
    $dir
}

# The lines between "ARGV:" and "CWD:" of a fake argv program's output.
function Get-FakeArgv([string]$Text) {
    $lines = @($Text -split "`r?`n")
    $i = -1
    for ($k = 0; $k -lt $lines.Count; $k++) { if ($lines[$k].EndsWith('ARGV:')) { $i = $k; break } }
    if ($i -lt 0) { return $null }
    $out = @()
    for ($j = $i + 1; $j -lt $lines.Count -and -not $lines[$j].StartsWith('CWD:'); $j++) { $out += $lines[$j] }
    , $out
}

$sendEnv = @('-o', 'SendEnv=COLORTERM', '-o', 'SendEnv=TERM_PROGRAM', '-o', 'SendEnv=TERM_PROGRAM_VERSION')

# A Check returns the problems of a case: it gets the output text and the home.
function Test-SshArgv([string]$Text, [string[]]$Want, [string]$Term) {
    $got = Get-FakeArgv $Text
    if ($null -eq $got) { return @('no ARGV: from the fake ssh') }
    $p = @()
    if (($got -join '|') -ne ($Want -join '|')) { $p += "fake argv is '$($got -join '|')', expected '$($Want -join '|')'" }
    if ($Term -and $Text.IndexOf("TERM:$Term") -lt 0) { $p += "no TERM:$Term from the fake ssh" }
    $p
}

function New-Home([string]$Name, [hashtable]$Files) {
    $h = Join-Path $sandbox $Name
    New-Item -ItemType Directory -Path $h | Out-Null
    foreach ($k in $Files.Keys) {
        $p = Join-Path $h $k
        New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
        [IO.File]::WriteAllText($p, $Files[$k].Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
    }
    $h
}

# A zsh config in ZDOTDIR=<home>/zd: its own prompt and a marker.
$zdFiles = @{ 'zd/.zshrc' = "PROMPT='zd%% '`nexport ZD_MARK=yes`n" }

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
        Name = 'bash-zdotdir-env'; Exe = $bash; Args = '--posix'; Input = "echo zd-`$ZD_MARK`r"
        Home = @{ '.bashrc' = "if [ -t 1 ]; then exec zsh; fi`n" } + $zdFiles
        Env = (Get-BashEnv) + @{ ZDOTDIR = ((Join-Path $sandbox 'bash-zdotdir-env\zd') -replace '\\', '/') }
        Expect = 'zd-yes'; Needs = $zsh
    },
    @{
        Name = 'bash-zdotdir-rc'; Exe = $bash; Args = '--posix'; Input = "echo zd-`$ZD_MARK`r"
        Home = @{ '.bashrc' = 'export ZDOTDIR="${ZDOTDIR:-$HOME/zd}"' + "`nif [ -t 1 ]; then exec zsh; fi`n" } + $zdFiles
        Env = (Get-BashEnv); Expect = 'zd-yes'; Needs = $zsh
    },
    @{
        # What a startup file starts (a tmux server, an agent) gets neither
        # ZDOTDIR nor GHOSTTY_ZSH_ZDOTDIR.
        Name = 'bash-zdotdir-leak'; Exe = $bash; Args = '--posix'
        Input = "echo leak-`$(grep -c -e ZDOTDIR -e GHOSTTY_ZSH `"`$HOME/env.txt`")`r"
        Home = @{ '.bashrc' = 'env > "$HOME/env.txt"' + "`nPS1='bash$ '`n" }; Env = (Get-BashEnv); Expect = 'leak-0'
    },
    @{
        # The handoff trap is gone once the startup files ran. The quotes keep
        # the typed line from matching the expected output.
        Name = 'bash-trap-gone'; Exe = $bash; Args = '--posix'
        Input = "echo n-`$(trap -p DEBUG | grep -c zsh_hand`"`"off)`r"
        Home = @{ '.bashrc' = "PS1='bash$ '`n" }; Env = (Get-BashEnv); Expect = 'n-0'
    },
    @{
        # A user DEBUG trap that chains the one before it keeps working.
        Name = 'bash-trap-chained'; Exe = $bash; Args = '--posix'
        Input = "echo t-`$(trap -p DEBUG | grep -c my_d`"`"bg)`r"
        Home = @{ '.bashrc' = (@(
                    'prev=$(trap -p DEBUG); prev=${prev#trap -- \''}; prev=${prev%\'' DEBUG}'
                    '__my_dbg() { :; }'
                    'trap "${prev:+$prev; }__my_dbg" DEBUG'
                    "PS1='bash$ '"
                ) -join "`n") + "`n"
        }
        Env = (Get-BashEnv); Expect = 't-1'
    },
    @{
        # `$_` survives the trap that runs before every startup command.
        Name = 'bash-last-arg'; Exe = $bash; Args = '--posix'; Input = "echo at-`${PWD##*/}`r"
        Home = @{ '.bashrc' = 'mkdir -p "$HOME/under"' + "`n" + 'cd "$_"' + "`nPS1='bash$ '`n" }
        Env = (Get-BashEnv); Expect = 'at-under'
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
        Name = 'cmd'; Exe = $cmd; Args = ''; Input = "echo cmd-%OS%`r"; Home = @{}; Expect = 'cmd-Windows_NT'
        Env = @{ PROMPT = $cmdPrompt }
    },
    @{
        # cmd marks no command start: Ghostty asks the process list instead.
        # A running ping is the shell's child, an idle prompt has none.
        Name = 'cmd-busy'; Exe = $cmd; Args = ''; Input = "ping -t 127.0.0.1`r"; Home = @{}; Expect = '127.0.0.1'
        Env = @{ PROMPT = $cmdPrompt }; Children = '|ping.exe'
    }
)

# PowerShell: `Marks` is the exit code of every 133;D in order. The quotes
# keep the typed lines from matching the expected output.
foreach ($ps in @(@{ Prefix = 'pwsh'; Exe = $pwsh }, @{ Prefix = 'powershell'; Exe = $winps })) {
    $integrate = ". ([scriptblock]::Create([IO.File]::ReadAllText('$resWin\shell-integration\pwsh\ghostty.ps1')))"
    $psArgs = "-NoLogo -NoProfile -NoExit -Command `"$integrate`""
    $cases += @(
        @{
            Name = $ps.Prefix; Exe = $ps.Exe; Args = $psArgs; Input = "'ps-' + (40+2)`r"; Home = @{}; Env = @{}
            Expect = 'ps-42'; Marks = '0'
        },
        @{
            # The same native exit code twice is reported twice, the user's
            # $LASTEXITCODE is the last native code, a cmdlet failure is 1.
            Name = "$($ps.Prefix)-exit"; Exe = $ps.Exe; Args = $psArgs; Home = @{}; Env = @{}
            Input = (@(
                    'cmd /c exit 3', 'cmd /c exit 3', '"le$()c-$LASTEXITCODE"', 'Get-Item nope-missing-item',
                    'cmd /c exit 0', 'cmd /c exit 5', 'cmd /c exit 5', '$LASTEXITCODE = 7', '"le$()c-$LASTEXITCODE"'
                ) -join "`r") + "`r"
            Expect = 'lec-3'; Expect2 = 'lec-7'; Marks = '3,3,0,1,0,5,5,0,0'
        },
        @{
            # StrictMode before any native command: no $LASTEXITCODE yet.
            Name = "$($ps.Prefix)-strict"; Exe = $ps.Exe; Args = $psArgs; Home = @{}; Env = @{}
            Input = "Set-StrictMode -Version Latest`rGet-Item nope-missing-item`rcmd /c exit 3`rcmd /c exit 3`r'st' + 'rict-ok'`r"
            Expect = 'strict-ok'; Marks = '0,1,3,3,0'; NoError = 'has not been set'
        },
        @{
            # Without PSReadLine there is no C and no D.
            Name = "$($ps.Prefix)-noreadline"; Exe = $ps.Exe; Home = @{}; Env = @{}
            Args = "-NoLogo -NoProfile -NoExit -Command `"Remove-Module PSReadLine; $integrate`""
            Input = "cmd /c exit 3`r`"le`$()c-`$LASTEXITCODE`"`r"; Expect = 'lec-3'; Marks = ''
        },
        @{
            # A user prompt that runs a native command and puts $LASTEXITCODE
            # back (as starship and oh-my-posh do) is chained.
            Name = "$($ps.Prefix)-userprompt"; Exe = $ps.Exe; Home = @{}; Env = @{}
            Args = "-NoLogo -NoProfile -NoExit -Command `"function global:prompt { `$c = `$global:LASTEXITCODE; cmd /c exit 9; `$global:LASTEXITCODE = `$c; 'my> ' }; $integrate`""
            Input = "cmd /c exit 3`rcmd /c exit 3`r`"le`$()c-`$LASTEXITCODE`"`r"; Expect = 'lec-3'; Expect2 = 'my> '; Marks = '3,3,0'
        }
    )
}

# cursor: the bar goes out right before B (prompt) and is reset right after C.
# ConPTY re-orders the bar within the prompt, so it only has to come after A
# and before the next A/C.
$barBeforeB = "(?s)`e\]133;A(\x07|`e[\\])((?!`e\]133;B).)*?`e\[5 q"
$resetAfterC = "`e\]133;C\a`e\[0 q"
$cases += @(
    @{
        Name = 'cmd-cursor'; Exe = $cmd; Args = ''; Input = "echo cmd-%OS%`r"; Home = @{}; Expect = 'cmd-Windows_NT'
        Env = @{ PROMPT = $cmdPromptBar; GHOSTTY_SHELL_FEATURES = 'cursor:blink,title' }
        Check = { param($t, $h) if ($t -notmatch $barBeforeB) { 'no ESC[5 q before 133;B' } }
    }
)
foreach ($ps in @(@{ Prefix = 'pwsh'; Exe = $pwsh }, @{ Prefix = 'powershell'; Exe = $winps })) {
    $integrate = ". ([scriptblock]::Create([IO.File]::ReadAllText('$resWin\shell-integration\pwsh\ghostty.ps1')))"
    $psArgs = "-NoLogo -NoProfile -NoExit -Command `"$integrate`""
    $cases += @{
        Name = "$($ps.Prefix)-cursor"; Exe = $ps.Exe; Args = $psArgs; Input = "'ps-' + (40+2)`r"; Home = @{}
        Env = @{ GHOSTTY_SHELL_FEATURES = 'cursor:blink,title' }; Expect = 'ps-42'
        Check = {
            param($t, $h)
            if ($t -notmatch $barBeforeB) { 'no ESC[5 q before 133;B' }
            if ($t -notmatch $resetAfterC) { 'no ESC[0 q after 133;C' }
        }
    }
}

# ssh features against a fake ssh.exe (needs the built ghostty.exe: +ssh).
if (Test-Path -LiteralPath $ghosttyExe) {
    $argvDir = New-FakeSshDir 'argv'
    $logDir = New-FakeSshDir 'log'
    function Get-SshEnv([string]$Dir, [string]$Features, [string]$HomeName, [hashtable]$Extra = @{}) {
        $h = Join-Path $sandbox $HomeName
        @{
            PATH = "$Dir;$env:PATH"; GHOSTTY_BIN_DIR = $ghosttyBin; GHOSTTY_SHELL_FEATURES = $Features
            LOCALAPPDATA = $h; XDG_STATE_HOME = $h; XDG_CACHE_HOME = $h
        } + $Extra
    }
    foreach ($ps in @(@{ Prefix = 'pwsh'; Exe = $pwsh }, @{ Prefix = 'powershell'; Exe = $winps })) {
        $integrate = ". ([scriptblock]::Create([IO.File]::ReadAllText('$resWin\shell-integration\pwsh\ghostty.ps1')))"
        $psArgs = "-NoLogo -NoProfile -NoExit -Command `"$integrate`""
        $cases += @{
            # The second line of input is the fake's stdin; FAKE_EXIT is $LASTEXITCODE.
            Name = "$($ps.Prefix)-ssh-env"; Exe = $ps.Exe; Args = $psArgs; Home = @{}; Needs = $ghosttyExe
            Input = "ssh -p 2222 'host one'`r$([char]1)`r$([char]1)'le' + 'c-' + `$LASTEXITCODE`r"
            Env = (Get-SshEnv $argvDir 'cursor,title,ssh-env' "$($ps.Prefix)-ssh-env" @{ FAKE_EXIT = '7' })
            Expect = 'lec-7'
            Check = { param($t, $h) Test-SshArgv $t ($sendEnv + @('-p', '2222', 'host one')) 'xterm-256color' }
        }
        $cases += @{
            Name = "$($ps.Prefix)-no-ssh"; Exe = $ps.Exe; Args = $psArgs; Home = @{}; Needs = $ghosttyExe
            Input = "ssh -p 1 hostx`r$([char]1)`r$([char]1)'ty-' + (Get-Command ssh).CommandType`r"
            Env = (Get-SshEnv $argvDir 'cursor,title' "$($ps.Prefix)-no-ssh" @{ TERM = 'xterm-256color' })
            Expect = 'ty-Application'
            Check = { param($t, $h) Test-SshArgv $t @('-p', '1', 'hostx') $null }
        }
    }
    $cases += @{
        # The first call installs the terminfo (its stdin) and is cached; the
        # second connection to the same host is a session only.
        Name = 'pwsh-ssh-terminfo'; Exe = $pwsh; Args = "-NoLogo -NoProfile -NoExit -Command `". ([scriptblock]::Create([IO.File]::ReadAllText('$resWin\shell-integration\pwsh\ghostty.ps1')))`""
        Home = @{}; Needs = $ghosttyExe
        Input = "ssh hostx`r'one' + '-done'`rssh hostx`r'two' + '-done'`r"
        Env = (Get-SshEnv $logDir 'cursor,title,ssh-terminfo' 'pwsh-ssh-terminfo' @{ FAKE_LOG = (Join-Path $sandbox 'pwsh-ssh-terminfo.log') })
        Expect = 'two-done'
        Check = {
            param($t, $h)
            $log = Join-Path $sandbox 'pwsh-ssh-terminfo.log'
            if (-not (Test-Path -LiteralPath $log)) { return 'the fake ssh logged nothing' }
            $calls = @((Get-Content -Raw -LiteralPath $log) -split "CALL`r?`n" | Where-Object { $_ })
            $p = @()
            $installs = @($calls | Where-Object { $_ -match '(?m)^STDIN:' })
            if ($installs.Count -ne 1) { $p += "$($installs.Count) terminfo installs, expected 1" }
            elseif ($installs[0] -notmatch '(?m)^STDIN:xterm-ghostty\|') { $p += 'the install stdin does not start with the terminfo source' }
            if ($calls.Count -ne 3) { $p += "$($calls.Count) ssh calls, expected 3 (install, session, cached session)" }
            elseif ($calls[2] -notmatch '(?m)^TERM:xterm-ghostty') { $p += 'the cached session has no TERM=xterm-ghostty' }
            $p
        }
    }
    $sshCmdDir = "$resWin\shell-integration\cmd"
    $cases += @{
        Name = 'cmd-ssh-env'; Exe = $cmd; Args = ''; Home = @{}; Needs = $ghosttyExe
        Input = "ssh host`r$([char]1)`r$([char]1)echo cmd-%OS%`r"; Expect = 'cmd-Windows_NT'
        Env = (Get-SshEnv "$sshCmdDir;$argvDir" 'title,ssh-env' 'cmd-ssh-env' @{ PROMPT = $cmdPrompt })
        Check = { param($t, $h) Test-SshArgv $t ($sendEnv + @('host')) 'xterm-256color' }
    }
}

$failed = 0
try {
    foreach ($c in $cases) {
        if ($c.Name -notlike $Only) { continue }
        $need = if ($c.Needs) { $c.Needs } else { $c.Exe }
        if (-not (Test-Path -LiteralPath $c.Exe) -or -not (Test-Path -LiteralPath $need)) {
            Write-Host "SKIP $($c.Name): $need not found"
            continue
        }
        $h = New-Home $c.Name $c.Home
        $probe = if ($c.Children) { $childProbe } else { $null }
        $bytes = [ShellMarksPty]::Run("`"$($c.Exe)`" $($c.Args)", (Get-EnvBlock $h $c.Env), $h, $c.Input, $WaitMs, $probe)
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        [IO.File]::WriteAllBytes((Join-Path $sandbox "$($c.Name).bin"), $bytes)
        $problems = @()
        if ($c.Children -and [ShellMarksPty]::Probed -ne $c.Children) {
            $problems += "shell children (prompt|command) are '$([ShellMarksPty]::Probed)', expected '$($c.Children)'"
        }
        if ($text.IndexOf($c.Expect) -lt 0) { $problems += "no '$($c.Expect)' in the output" }
        if ($c.Expect2 -and $text.IndexOf($c.Expect2) -lt 0) { $problems += "no '$($c.Expect2)' in the output" }
        if ($c.NoError -and $text.IndexOf($c.NoError) -ge 0) { $problems += "'$($c.NoError)' in the output" }
        if ($c.ContainsKey('Marks')) {
            $marks = @([regex]::Matches($text, "`e]133;D;(\d+)") | ForEach-Object { $_.Groups[1].Value }) -join ','
            if ($marks -ne $c.Marks) { $problems += "133;D codes are '$marks', expected '$($c.Marks)'" }
        }
        if ($c.Check) { $problems += @(& $c.Check $text $h | Where-Object { $_ }) }
        if ($text -match "command not found") { $problems += "'command not found' in the output" }
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
