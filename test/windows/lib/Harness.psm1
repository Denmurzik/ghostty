# Safety harness for the Windows GUI/e2e scripts. Everything that sends
# input, switches keyboard layouts or touches windows goes through here so
# that a run on an owner's real desktop:
#   - SKIPs (never FAILs) when the session is locked or non-interactive,
#   - restores the keyboard layouts it changed,
#   - kills only the Ghostty processes it started.

Set-StrictMode -Version Latest

if (-not ('GhosttyHarness.Native' -as [type])) {
    Add-Type -Namespace GhosttyHarness -Name Native -MemberDefinition @"
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(uint dwProcessId);
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
[DllImport("user32.dll")] public static extern IntPtr OpenInputDesktop(uint dwFlags, bool fInherit, uint dwDesiredAccess);
[DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr hDesktop);
[DllImport("user32.dll")] public static extern int GetKeyboardLayoutList(int nBuff, [Out] IntPtr[] lpList);
[DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint idThread);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr LoadKeyboardLayoutW(string pwszKLID, uint Flags);
[DllImport("user32.dll")] public static extern bool UnloadKeyboardLayout(IntPtr hkl);
[DllImport("user32.dll")] public static extern IntPtr ActivateKeyboardLayout(IntPtr hkl, uint Flags);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool PostMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
"@
}

$script:ASFW_ANY = [uint32]::MaxValue
$script:VK_MENU = 0x12
$script:KEYEVENTF_KEYUP = 0x2
$script:DESKTOP_SWITCHDESKTOP = 0x100
$script:WM_INPUTLANGCHANGEREQUEST = 0x50
$script:KLF_NOTELLSHELL = 0x80

$script:SkipReason = ''
$script:SavedLayouts = $null
$script:SavedActive = [IntPtr]::Zero
$script:OwnPids = [System.Collections.Generic.List[int]]::new()

function Get-ResultsPath {
    $dir = Join-Path $env:TEMP 'ghostty-e2e'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Join-Path $dir 'results.txt'
}

# --- desktop lock -------------------------------------------------------------
# Only one GUI test run may use the desktop at a time (Ghostty windows steal
# the foreground from every other run). The lock is the file
# %TEMP%\gui-e2e.lock, taken atomically (CreateNew); see test/windows/README.md
# for the protocol other sessions follow.

$script:LockStaleMinutes = 20

function Get-GuiLockPath { Join-Path $env:TEMP 'gui-e2e.lock' }

# The lock file as { Id; Pid; Owner; Time }, or $null when it is absent or
# unreadable (it may vanish between the check and the read).
function Read-GuiLock {
    try {
        $text = [IO.File]::ReadAllText((Get-GuiLockPath))
    } catch {
        return $null
    }
    $r = [pscustomobject]@{ Id = ''; Pid = 0; Owner = ''; Time = ''; Raw = $text.Trim() }
    foreach ($l in ($text -split "`r?`n")) {
        if ($l -match '^id=(.+)$') { $r.Id = $Matches[1].Trim() }
        elseif ($l -match '^pid=(\d+)$') { $r.Pid = [int]$Matches[1] }
        elseif ($l -match '^owner=(.*)$') { $r.Owner = $Matches[1].Trim() }
        elseif ($l -match '^time=(.*)$') { $r.Time = $Matches[1].Trim() }
    }
    $r
}

# Stale: not touched for $LockStaleMinutes, or written by a process that is
# gone. Returns the lock's content as judged (so the deleter can check it is
# still the same lock), or $null when the lock is absent or alive. A file that
# cannot be read is treated as held (a writer is mid-way).
function Get-StaleGuiLock {
    $path = Get-GuiLockPath
    try {
        $age = (Get-Date) - (Get-Item -LiteralPath $path -ErrorAction Stop).LastWriteTime
    } catch {
        return $null
    }
    $l = Read-GuiLock
    if ($null -eq $l) { return $null }
    if ($age.TotalMinutes -gt $script:LockStaleMinutes) { return $l }
    if ($l.Pid -gt 0 -and -not (Get-Process -Id $l.Pid -ErrorAction SilentlyContinue)) { return $l }
    $null
}

function Write-GuiLockContent([string]$Id, [int]$OwnerPid, [string]$Owner) {
    "id=$Id`r`npid=$OwnerPid`r`nowner=$Owner`r`ntime=$((Get-Date).ToString('s'))`r`n"
}

<#
.SYNOPSIS
Takes the desktop lock (waiting up to TimeoutMinutes) and returns a token for
Exit-GuiLock / Update-GuiLock. A run started by the e2e runner inherits the
runner's lock through GHOSTTY_E2E_LOCK_ID instead of taking another.
#>
function Enter-GuiLock {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [double]$TimeoutMinutes = 30
    )

    $path = Get-GuiLockPath
    $inherited = $env:GHOSTTY_E2E_LOCK_ID
    if ($inherited) {
        $l = Read-GuiLock
        if ($l -and $l.Id -eq $inherited) {
            # The runner's lock: never rewritten from here, its pid stays the
            # runner's, so it is not stale between two scenarios.
            return [pscustomobject]@{ Id = $inherited; Own = $false; Owner = $Owner }
        }
    }

    $id = [guid]::NewGuid().ToString()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $stream = $null
        try {
            $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $bytes = [Text.Encoding]::ASCII.GetBytes((Write-GuiLockContent $id $PID $Owner))
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Dispose()
            return [pscustomobject]@{ Id = $id; Own = $true; Owner = $Owner }
        } catch [IO.IOException], [UnauthorizedAccessException] {
            if ($stream) { $stream.Dispose(); Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }

        $stale = Get-StaleGuiLock
        if ($stale) {
            # Deleting is the stale rule; whoever wins the next CreateNew
            # owns the lock. Delete only the lock that was judged: if it
            # changed meanwhile (touched, or replaced by a new holder) it is
            # not ours to remove.
            $now = Read-GuiLock
            if ($now -and $now.Raw -ceq $stale.Raw) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
            continue
        }
        if ($sw.Elapsed.TotalMinutes -gt $TimeoutMinutes) {
            $l = Read-GuiLock
            $who = if ($l) { $l.Raw -replace '\s+', ' ' } else { 'unreadable' }
            throw "GUI lock $path still held after $TimeoutMinutes min: $who"
        }
        Start-Sleep -Seconds 5
    }
}

# Refreshes `time=` (and so LastWriteTime) of a lock this process took, so a
# long run is never stale. The id and pid in the file are kept; nothing is
# written unless the file holds our id AND our pid. An inherited lock (the
# runner's) is never rewritten here.
function Update-GuiLock {
    param($Token)
    if ($null -eq $Token -or -not $Token.Own) { return }
    $l = Read-GuiLock
    if ($l -and $l.Id -eq $Token.Id -and $l.Pid -eq $PID) {
        try { [IO.File]::WriteAllText((Get-GuiLockPath), (Write-GuiLockContent $l.Id $l.Pid $l.Owner)) } catch { }
    }
}

# Releases the lock when this run took it and the file still holds its id.
function Exit-GuiLock {
    param($Token)
    if ($null -eq $Token -or -not $Token.Own) { return }
    $l = Read-GuiLock
    if ($l -and $l.Id -eq $Token.Id) {
        Remove-Item -LiteralPath (Get-GuiLockPath) -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
True when the desktop is unlocked, the session is interactive and a
foreground window exists. Otherwise false, with the reason available from
Get-SkipReason.
#>
function Test-InteractiveSession {
    if (-not [Environment]::UserInteractive) {
        $script:SkipReason = 'non-interactive session'
        return $false
    }

    # The input desktop cannot be opened while the secure (lock/UAC)
    # desktop is active.
    $desktop = [GhosttyHarness.Native]::OpenInputDesktop(0, $false, $script:DESKTOP_SWITCHDESKTOP)
    if ($desktop -eq [IntPtr]::Zero) {
        $script:SkipReason = 'desktop is locked'
        return $false
    }
    [void][GhosttyHarness.Native]::CloseDesktop($desktop)

    if ([GhosttyHarness.Native]::GetForegroundWindow() -eq [IntPtr]::Zero) {
        $script:SkipReason = 'no foreground window'
        return $false
    }

    $script:SkipReason = ''
    $true
}

function Get-SkipReason { $script:SkipReason }

<#
.SYNOPSIS
Runs a GUI scenario and records PASS, FAIL or SKIP. Layouts are restored
and own Ghostty processes are killed afterwards, whatever the outcome.
#>
function Invoke-GuiScenario {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    $line = $null
    $token = $null
    try {
        $token = Enter-GuiLock -Owner "scenario $Name"
    } catch {
        $line = "SKIP ${Name}: $($_.Exception.Message)"
    }
    if ($token) {
        try {
            if (-not (Test-InteractiveSession)) {
                $line = "SKIP ${Name}: $($script:SkipReason)"
            } else {
                Save-KeyboardLayouts
                try {
                    & $ScriptBlock | Out-Null
                    $line = "PASS $Name"
                } catch {
                    $line = "FAIL ${Name}: $($_.Exception.Message)"
                } finally {
                    Stop-OwnGhostty
                    Restore-KeyboardLayouts
                }
            }
        } finally {
            Exit-GuiLock $token
        }
    }

    Write-Output $line
    Add-Content -Path (Get-ResultsPath) -Value $line -Encoding UTF8
}

<#
.SYNOPSIS
Brings a window to the foreground even though Windows normally refuses
(foreground lock). Returns whether the window is now in the foreground.
#>
function Set-ForegroundSafe {
    param([Parameter(Mandatory)][IntPtr]$Hwnd)

    [void][GhosttyHarness.Native]::AllowSetForegroundWindow($script:ASFW_ANY)
    # A lone Alt tap lifts the foreground lock for the next call.
    [GhosttyHarness.Native]::keybd_event($script:VK_MENU, 0, 0, [UIntPtr]::Zero)
    [GhosttyHarness.Native]::keybd_event($script:VK_MENU, 0, $script:KEYEVENTF_KEYUP, [UIntPtr]::Zero)
    [void][GhosttyHarness.Native]::SetForegroundWindow($Hwnd)
    [GhosttyHarness.Native]::GetForegroundWindow() -eq $Hwnd
}

function Get-LayoutList {
    $count = [GhosttyHarness.Native]::GetKeyboardLayoutList(0, $null)
    $list = New-Object 'IntPtr[]' $count
    [void][GhosttyHarness.Native]::GetKeyboardLayoutList($count, $list)
    , $list
}

<# Remember the installed layouts and the active one. #>
function Save-KeyboardLayouts {
    $script:SavedLayouts = Get-LayoutList
    $script:SavedActive = [GhosttyHarness.Native]::GetKeyboardLayout(0)
}

<#
.SYNOPSIS
Unloads the layouts added since Save-KeyboardLayouts (and only those) and
re-activates the original one.
#>
function Restore-KeyboardLayouts {
    if ($null -eq $script:SavedLayouts) { return }

    $original = @($script:SavedLayouts)
    foreach ($hkl in (Get-LayoutList)) {
        if ($original -notcontains $hkl) {
            [void][GhosttyHarness.Native]::UnloadKeyboardLayout($hkl)
        }
    }
    if ($script:SavedActive -ne [IntPtr]::Zero) {
        [void][GhosttyHarness.Native]::ActivateKeyboardLayout($script:SavedActive, 0)
    }
    $script:SavedLayouts = $null
}

<#
.SYNOPSIS
Loads a keyboard layout (a KLID such as 00000407) and asks the window to
switch to it. Returns the layout handle.
#>
function Switch-GhosttyLayout {
    param(
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [Parameter(Mandatory)][string]$Klid
    )

    $hkl = [GhosttyHarness.Native]::LoadKeyboardLayoutW($Klid, $script:KLF_NOTELLSHELL)
    if ($hkl -eq [IntPtr]::Zero) { throw "LoadKeyboardLayoutW($Klid) failed" }
    [void][GhosttyHarness.Native]::PostMessageW(
        $Hwnd, $script:WM_INPUTLANGCHANGEREQUEST, [IntPtr]::Zero, $hkl)
    $hkl
}

<# Record a Ghostty process started by this run, so Stop-OwnGhostty kills it. #>
function Register-OwnGhostty {
    param([Parameter(Mandatory)][int]$ProcessId)
    $script:OwnPids.Add($ProcessId)
}

<# Kill the Ghostty processes (and their children) this run started. Nothing else. #>
function Stop-OwnGhostty {
    foreach ($id in $script:OwnPids) {
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($null -eq $p -or $p.ProcessName -notlike 'ghostty*') { continue }
        & taskkill.exe /PID $id /T /F 2>&1 | Out-Null
    }
    $script:OwnPids.Clear()
}

if (-not ('GhosttyHarness.Mem' -as [type])) {
    Add-Type -Namespace GhosttyHarness -Name Mem -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct MEMORYSTATUSEX {
    public uint dwLength; public uint dwMemoryLoad;
    public ulong ullTotalPhys; public ulong ullAvailPhys;
    public ulong ullTotalPageFile; public ulong ullAvailPageFile;
    public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
}
[DllImport("kernel32.dll", SetLastError = true)] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX s);
public static ulong AvailPhysBytes() {
    MEMORYSTATUSEX s = new MEMORYSTATUSEX();
    s.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
    if (!GlobalMemoryStatusEx(ref s)) throw new System.ComponentModel.Win32Exception();
    return s.ullAvailPhys;
}
"@
}

<#
Available physical memory in GB: GlobalMemoryStatusEx's ullAvailPhys, which
counts the standby list (cached pages the system gives back on demand) as
available, like Task Manager's "Available". Win32_OperatingSystem's
FreePhysicalMemory leaves the standby list out and under-reports on a machine
that has been up for a while.
#>
function Get-FreeRamGb {
    [math]::Round([GhosttyHarness.Mem]::AvailPhysBytes() / 1GB, 2)
}

<#
Throws `E2E-SKIP: <reason>` (a SKIP in a scenario, and in the runner) when less
than $Gb GB of RAM are free. Heavy scenarios call it before they start more
windows than the machine can take (a swapping desktop is worse than a SKIP).
#>
function Assert-FreeRam {
    param([Parameter(Mandatory)][double]$Gb)
    $free = Get-FreeRamGb
    if ($free -lt $Gb) {
        throw ('E2E-SKIP: only {0:N1} GB RAM free, {1:N1} GB needed' -f $free, $Gb)
    }
}

<#
The one writer of the config.ghostty text every test script uses: the Extra
lines, then `class = <Class>`, always. The class gives the instance an
identity of its own (window class, IPC pipe), so a test instance can never
reach another instance or the owner's.
#>
function New-GhosttyConfigText {
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Class,
        [string]$Extra
    )
    $text = if ($Extra) { ($Extra -replace "`r`n", "`n").TrimEnd("`n") + "`n" } else { '' }
    $text + "class = $Class`n"
}

Export-ModuleMember -Function New-GhosttyConfigText, Assert-FreeRam, Get-FreeRamGb, Enter-GuiLock, Exit-GuiLock, Update-GuiLock, Test-InteractiveSession, Get-SkipReason, Invoke-GuiScenario,
    Set-ForegroundSafe, Save-KeyboardLayouts, Restore-KeyboardLayouts, Switch-GhosttyLayout,
    Register-OwnGhostty, Stop-OwnGhostty
