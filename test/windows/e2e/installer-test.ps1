# e2e: milestone=M6 timeout=300 order=1001
# installer-test: installs the /DGhosttyTest setup into a sandbox folder (a
# name with a Cyrillic letter and a space), checks the files, upgrades over
# it ([InstallDelete] drops stale files of the two Ghostty-owned folders and
# keeps the user's file), seeds an application hive (GHOSTTY_WIN32_TEST_HIVE)
# with the verbs of the installed exe plus an AUMID key, uninstalls, and
# checks that the uninstaller's --only-this-exe step emptied the hive, removed
# the toast icon, left the user's files alone and that the real HKCU, the
# Start menu and the uninstall list are unchanged (read-only snapshots).
#
# Input: GHOSTTY_E2E_SETUP=<...-setup-test.exe>. The guards make sure it is
# never the real installer (only the /DGhosttyTest variant writes no
# registry and no shortcuts). Optional: GHOSTTY_E2E_STAGE_ZIP=<package zip>
# for an exact file-list comparison.
#
# The running-Ghostty guards of the [Code] section are in the test variant too
# (they write nothing): with a scenario-launched Ghostty running, a silent
# setup and a silent uninstall must fail and change nothing. The interactive
# Retry click is a manual check.
. (Join-Path $PSScriptRoot '_common.ps1')

if (-not ('GhosttyE2e.Hive' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Hive -MemberDefinition @"
[DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegLoadAppKeyW(string file, out IntPtr key, uint sam, uint opts, uint res);
[DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegOpenKeyExW(IntPtr k, string sub, uint opts, uint sam, out IntPtr res);
[DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegCreateKeyExW(IntPtr k, string sub, uint res, string cls, uint opts, uint sam, IntPtr sa, out IntPtr key, out uint disp);
[DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegSetValueExW(IntPtr k, string name, uint res, uint type, byte[] data, uint len);
[DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr k);

// KEY_ALL_ACCESS on the private hive file; 0 or a Win32 error code.
public static int Load(string file, out IntPtr key) { return RegLoadAppKeyW(file, out key, 0xF003F, 0, 0); }
public static void Close(IntPtr key) { RegCloseKey(key); }
public static bool Exists(IntPtr root, string sub) {
    IntPtr k;
    int rc = RegOpenKeyExW(root, sub, 0, 0x20019, out k);
    if (rc == 0) { RegCloseKey(k); return true; }
    return false;
}
public static int SetString(IntPtr root, string sub, string name, string value) {
    IntPtr k; uint disp;
    int rc = RegCreateKeyExW(root, sub, 0, null, 0, 0xF003F, IntPtr.Zero, out k, out disp);
    if (rc != 0) return rc;
    byte[] data = System.Text.Encoding.Unicode.GetBytes(value + "\0");
    rc = RegSetValueExW(k, name, 0, 1, data, (uint)data.Length);
    RegCloseKey(k);
    return rc;
}
"@
}

if (-not ('GhosttyE2e.TrayFind' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name TrayFind -MemberDefinition @"
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
"@
}
function Test-TrayWindow { [GhosttyE2e.TrayFind]::FindWindowW('GhosttyTray', [NullString]::Value) -ne [IntPtr]::Zero }

$script:VerbKeys = @(
    'Software\Classes\Directory\shell\GhosttyOpenHere',
    'Software\Classes\Directory\Background\shell\GhosttyOpenHere',
    'Software\Classes\Drive\shell\GhosttyOpenHere'
)
$script:AumidKeys = @(
    'Software\Classes\AppUserModelId\com.mitchellh.ghostty.windows-unofficial',
    'Software\Classes\AppUserModelId\com.mitchellh.ghostty.windows-unofficial-debug'
)

# Read-only snapshot of the owner's real state that a test install must not change.
function Get-RealSnapshot {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $r = @()
        $r += 'uninstall: ' + ((& reg.exe query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall' 2>&1 | Out-String) -replace '\s+', ' ')
        foreach ($k in 'Directory\shell', 'Directory\Background\shell', 'Drive\shell') {
            $out = & reg.exe query "HKCU\Software\Classes\$k\GhosttyOpenHere" /s 2>&1 | Out-String
            $r += "verb ${k}: $LASTEXITCODE $($out -replace '\s+', ' ')"
        }
        $aum = & reg.exe query 'HKCU\Software\Classes\AppUserModelId' 2>&1 | Out-String
        $r += 'aumid: ' + (($aum -split "`r?`n" | Where-Object { $_ -like '*com.mitchellh.ghostty.windows-unofficial*' }) -join '|')
        $sm = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
        $r += 'startmenu: ' + ((Get-ChildItem -LiteralPath $sm -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object) -join '|')
        $r -join "`n"
    } finally { $ErrorActionPreference = $eap }
}

# Runs a program with the sandbox env plus the test hive; returns code and output.
function Invoke-Sandboxed([string]$Exe, [string]$Arguments, [double]$TimeoutSec, [string]$Cwd) {
    $sbx = $script:Sbx
    $psi = [System.Diagnostics.ProcessStartInfo]::new($Exe)
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $Cwd
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $e = $psi.EnvironmentVariables
    $e['USERPROFILE'] = $sbx.Home
    $e['HOME'] = $sbx.Home
    $e['LOCALAPPDATA'] = $sbx.Local
    $e['APPDATA'] = $sbx.Roaming
    $e['TEMP'] = $sbx.Tmp
    $e['TMP'] = $sbx.Tmp
    $e['XDG_CONFIG_HOME'] = (Join-Path $sbx.Home '.config')
    $e['GHOSTTY_WIN32_TEST_IPC'] = '1'
    $e['GHOSTTY_WIN32_TEST_HIVE'] = $script:Hive
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit([int]($TimeoutSec * 1000))) {
        try { $p.Kill() } catch {}
        throw "$([IO.Path]::GetFileName($Exe)) $Arguments did not exit within $TimeoutSec s"
    }
    [pscustomobject]@{ Code = $p.ExitCode; Stdout = $out.Result; Stderr = $err.Result }
}

# Opens the hive for a moment (Windows lets go of a closed app hive a little late).
function Use-Hive([scriptblock]$Action) {
    $h = [IntPtr]::Zero
    $rc = -1
    $ok = Wait-Until -TimeoutSec 15 -PollMs 250 -Condition {
        $script:LoadH = [IntPtr]::Zero
        $script:LoadRc = [GhosttyE2e.Hive]::Load($script:Hive, [ref]$script:LoadH)
        $script:LoadRc -eq 0
    }
    if (-not $ok) { throw "the application hive cannot be opened (RegLoadAppKeyW $($script:LoadRc))" }
    $h = $script:LoadH
    try { & $Action $h } finally { [GhosttyE2e.Hive]::Close($h) }
}

function Get-RelFiles([string]$Root) {
    $r = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    @(Get-ChildItem -LiteralPath $r -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($r.Length + 1) } | Sort-Object)
}

Invoke-E2eScenario 'installer-test' {
    # ---- guards: never the real installer ----
    $setup = $env:GHOSTTY_E2E_SETUP
    if (-not $setup) { throw 'E2E-SKIP: GHOSTTY_E2E_SETUP is not set' }
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) { throw "E2E-SKIP: GHOSTTY_E2E_SETUP does not exist: $setup" }
    $setup = (Resolve-Path -LiteralPath $setup).Path
    if (-not $setup.EndsWith('-setup-test.exe', [StringComparison]::OrdinalIgnoreCase)) { throw 'E2E-SKIP: the setup name does not end in -setup-test.exe' }
    $desc = ([string][Diagnostics.FileVersionInfo]::GetVersionInfo($setup).FileDescription).Trim()  # Inno pads the string
    if ($desc -ne 'Ghostty test installer') { throw "E2E-SKIP: FileDescription is '$desc', not 'Ghostty test installer'" }

    # The setup's guard looks for any GhosttyTray window: a Ghostty of the owner's would block this run.
    if (Test-TrayWindow) { throw 'E2E-SKIP: a Ghostty tray window exists already (close Ghostty, then rerun)' }

    $sbx = $script:Sbx
    $script:Hive = Join-Path $sbx.Tmp 'hive.dat'
    $zhe = ConvertFrom-CodePoints @(0x0416)
    $inst = Join-Path $sbx.Root ('Inst ' + $zhe)
    $sentinel = Join-Path (Join-Path $sbx.Home '.config\ghostty') 'sentinel.txt'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sentinel) | Out-Null
    Set-Content -LiteralPath $sentinel -Value 'keep me' -Encoding ASCII

    # The hive must be usable, else this would prove nothing.
    Use-Hive { param($h) }
    Remove-Item -LiteralPath ($script:Hive + '*') -Force -ErrorAction SilentlyContinue

    $before = Get-RealSnapshot
    $setupArgs = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOICONS /DIR=`"$inst`" /LOG=`"$(Join-Path $sbx.Root 'setup.log')`""

    function Install-Once([string]$What) {
        $r = Invoke-Sandboxed $setup $setupArgs 120 $sbx.Root
        if ($r.Code -ne 0) { throw "$What : setup exited $($r.Code): $($r.Stdout) $($r.Stderr)" }
        if (-not (Test-Path -LiteralPath (Join-Path $inst 'ghostty.exe'))) { throw "$What : ghostty.exe is not in $inst" }
    }

    function Assert-Files([string]$What) {
        $have = @(Get-RelFiles $inst | Where-Object { $_ -ne 'user-note.txt' })
        foreach ($f in 'unins000.exe', 'unins000.dat', 'ghostty.exe', 'tmux.exe', 'LICENSE', 'README-windows.txt') {
            if ($have -notcontains $f) { throw "$What : $f is missing" }
        }
        if (@($have | Where-Object { $_ -like 'share\ghostty\themes\*' }).Count -eq 0) { throw "$What : no themes" }
        if (@($have | Where-Object { $_ -like 'share\ghostty\shell-integration\*' }).Count -eq 0) { throw "$What : no shell integration" }
        if ($have -contains 'share\ghostty\themes\zz-stale.txt' -or $have -contains 'share\ghostty\shell-integration\zz-stale.sh') { throw "$What : stale files were not removed" }
        if (@($have | Where-Object { $_ -like '*.pdb' }).Count) { throw "$What : a .pdb was installed" }
        if ($env:GHOSTTY_E2E_STAGE_ZIP) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $z = [IO.Compression.ZipFile]::OpenRead($env:GHOSTTY_E2E_STAGE_ZIP)
            try {
                $want = @($z.Entries | Where-Object { $_.FullName -notmatch '/$' } | ForEach-Object { $_.FullName.Substring($_.FullName.IndexOf('/') + 1).Replace('/', '\') })
            } finally { $z.Dispose() }
            $want = @($want + 'unins000.exe' + 'unins000.dat' | Sort-Object)
            $diff = Compare-Object $want $have
            if ($diff) { throw "$What : file list differs from the package: $(($diff | Select-Object -First 5 | ForEach-Object { $_.SideIndicator + ' ' + $_.InputObject }) -join '; ')" }
        }
    }

    # A Ghostty of this run (own sandbox) with its tray window.
    function Start-Blocker {
        $script:Blocker = Start-E2eGhostty
        if (-not (Wait-Until -TimeoutSec 15 -PollMs 200 -Condition { Test-TrayWindow })) { $lg = if (Test-Path -LiteralPath $script:Blocker.Log) { (Get-Content -LiteralPath $script:Blocker.Log -Tail 12) -join "`n" } else { '(no log)' }; $cls = @([GhosttyE2e.Win]::TopLevel([uint32]$script:Blocker.Pid, $null) | ForEach-Object { [GhosttyE2e.Win]::ClassOf($_) }) -join ","; throw "the test Ghostty has no GhosttyTray window; its windows: $cls; exited=$($script:Blocker.Process.HasExited) hwnd=$($script:Blocker.Hwnd); log:`n$lg" }
    }
    function Stop-Blocker {
        Stop-OwnGhostty
        $pid_ = $script:Blocker.Pid
        $null = Wait-Until -TimeoutSec 10 -PollMs 200 -Condition { -not (Get-Process -Id $pid_ -ErrorAction SilentlyContinue) }
        if (-not (Wait-Until -TimeoutSec 10 -PollMs 200 -Condition { -not (Test-TrayWindow) })) { throw 'the GhosttyTray window did not go away' }
    }

    # ---- a running Ghostty blocks a silent install, which changes nothing ----
    Start-Blocker
    $r = Invoke-Sandboxed $setup $setupArgs 120 $sbx.Root
    if ($r.Code -eq 0) { throw 'the silent setup succeeded while Ghostty was running' }
    if (Test-Path -LiteralPath (Join-Path $inst 'ghostty.exe')) { throw 'the blocked setup installed files' }
    Write-E2eInfo "blocked silent setup exit code $($r.Code)"
    Stop-Blocker

    # ---- install ----
    Install-Once 'install'
    Assert-Files 'after install'
    $exe = Join-Path $inst 'ghostty.exe'
    $v1 = Invoke-Sandboxed $exe '+version' 20 $inst
    $v0 = Invoke-Sandboxed $script:Exe '+version' 20 $script:Root
    if ($v1.Code -ne 0) { throw "+version exited $($v1.Code)" }
    if ($v1.Stdout -ne $v0.Stdout) { throw "installed +version differs from the build's:`n$($v1.Stdout)`n--`n$($v0.Stdout)" }

    # a GUI start from the installed folder shows a window, then closes
    $saveExe = $script:Exe
    try {
        $script:Exe = $exe
        $g = Start-E2eGhostty
    } finally { $script:Exe = $saveExe }
    if (-not $g.Hwnd -or $g.Hwnd -eq [IntPtr]::Zero) { throw 'the installed ghostty.exe showed no window' }
    Stop-OwnGhostty
    $null = Wait-Until -TimeoutSec 10 -PollMs 200 -Condition { -not (Get-Process -Id $g.Pid -ErrorAction SilentlyContinue) }

    # ---- upgrade: stale files in the two owned folders go, the user's file stays ----
    Set-Content -LiteralPath (Join-Path $inst 'share\ghostty\themes\zz-stale.txt') -Value x -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $inst 'share\ghostty\shell-integration\zz-stale.sh') -Value x -Encoding ASCII
    $note = Join-Path $inst 'user-note.txt'
    Set-Content -LiteralPath $note -Value 'mine' -Encoding ASCII
    Install-Once 'upgrade'
    Assert-Files 'after upgrade'
    if (-not (Test-Path -LiteralPath $note)) { throw 'the upgrade removed user-note.txt' }

    # ---- seed the hive and the sandbox ----
    $r = Invoke-Sandboxed $exe '+install-explorer-integration' 20 $inst
    if ($r.Code -ne 0) { throw "+install-explorer-integration exited $($r.Code): $($r.Stdout) $($r.Stderr)" }
    Use-Hive {
        param($h)
        foreach ($k in $script:VerbKeys) { if (-not [GhosttyE2e.Hive]::Exists($h, $k)) { throw "seed: $k is missing from the hive" } }
        foreach ($k in $script:AumidKeys) {
            $rc = [GhosttyE2e.Hive]::SetString($h, $k, 'DisplayName', 'Ghostty test')
            if ($rc -ne 0) { throw "seed: writing $k failed ($rc)" }
        }
    }
    $icon = Join-Path (Join-Path $sbx.Local 'ghostty') 'toast-icon.png'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $icon) | Out-Null
    Set-Content -LiteralPath $icon -Value 'png' -Encoding ASCII

    # ---- a running Ghostty blocks a silent uninstall, which changes nothing ----
    $unins = Join-Path $inst 'unins000.exe'
    $uninsArgs = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=`"$(Join-Path $sbx.Root 'unins.log')`""
    Start-Blocker
    $r = Invoke-Sandboxed $unins $uninsArgs 60 $inst
    if ($r.Code -eq 0) { throw 'the silent uninstall succeeded while Ghostty was running' }
    Start-Sleep -Seconds 2
    if (-not (Test-Path -LiteralPath $unins)) { throw 'the blocked uninstall removed unins000.exe' }
    Assert-Files 'after the blocked uninstall'
    if (-not (Test-Path -LiteralPath $icon)) { throw 'the blocked uninstall removed the toast icon' }
    Use-Hive {
        param($h)
        foreach ($k in $script:VerbKeys) { if (-not [GhosttyE2e.Hive]::Exists($h, $k)) { throw "the blocked uninstall removed $k" } }
    }
    Write-E2eInfo "blocked silent uninstall exit code $($r.Code)"
    Stop-Blocker

    # ---- uninstall ----
    $r = Invoke-Sandboxed $unins $uninsArgs 60 $inst
    if ($r.Code -ne 0) { $ul = Join-Path $sbx.Root "unins.log"; throw "uninstall exited $($r.Code): $($r.Stdout) $($r.Stderr) log: $(($t_ = (Get-Content -LiteralPath $ul -Tail 40 -ErrorAction SilentlyContinue) -join " | ").Substring([Math]::Max(0, $t_.Length - 1500)))" }
    # It re-launches itself from %TEMP%: wait until unins000.exe is gone.
    $gone = Wait-Until -TimeoutSec 60 -PollMs 500 -Condition { -not (Test-Path -LiteralPath $unins) }
    if (-not $gone) { throw 'unins000.exe is still there after 60 s' }
    $null = Wait-Until -TimeoutSec 15 -PollMs 250 -Condition { -not (Get-Process -Name 'unins000', '_u*' -ErrorAction SilentlyContinue) }

    # ---- after uninstall ----
    Use-Hive {
        param($h)
        foreach ($k in $script:VerbKeys) { if ([GhosttyE2e.Hive]::Exists($h, $k)) { throw "the hive still has $k" } }
        foreach ($k in $script:AumidKeys) { if ([GhosttyE2e.Hive]::Exists($h, $k)) { throw "the hive still has $k" } }
    }
    if (Test-Path -LiteralPath $icon) { throw 'the toast icon is still there' }
    $left = @(Get-RelFiles $inst)
    if ($left.Count -ne 1 -or $left[0] -ne 'user-note.txt') { throw "the install folder keeps: $($left -join ', ')" }
    if (-not (Test-Path -LiteralPath $sentinel) -or ((Get-Content -LiteralPath $sentinel -Raw).Trim() -ne 'keep me')) { throw 'the config sentinel changed' }
    $after = Get-RealSnapshot
    if ($after -ne $before) { throw "the real HKCU / Start menu state changed:`nbefore:`n$before`nafter:`n$after" }
    Write-E2eInfo 'install, upgrade (InstallDelete), hive seed, uninstall (--only-this-exe) checked; real HKCU unchanged'
}
