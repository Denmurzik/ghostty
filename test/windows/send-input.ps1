<#
.SYNOPSIS
Sends keyboard input to a Ghostty window through SendInput.

.DESCRIPTION
Takes the window to the foreground through the harness and types into it.
Input goes to whatever has the foreground, so every key is preceded by a
check that the target window still does; if it lost the foreground the
script stops instead of typing into another application. A locked or
non-interactive session prints "SKIP send-input: <reason>" and exits 0.

  -Text       KEYEVENTF_UNICODE per UTF-16 unit: the VK_PACKET path, any
              character, no layout involved.
  -Keys       The real typing path: virtual key plus scancode, translated by
              the foreground window's keyboard layout. Each item is either a
              single character ("a", "%", "\"), a name (enter, tab, space,
              esc, backspace, delete, insert, home, end, pageup, pagedown,
              up, down, left, right, f1..f12, plus) or a chord of
              modifiers and one of those joined by "+": "ctrl+shift+c",
              "alt+f4". "+" itself is spelled "plus".
  -Scancodes  Hardware scancodes ("0x1E", or "0xE048" for an extended key),
              sent with KEYEVENTF_SCANCODE: the layout still decides the
              character.

.PARAMETER Hwnd
Top-level window handle: decimal or 0x-prefixed hex, as launch.ps1 prints.

.EXAMPLE
send-input.ps1 -Hwnd 0x1A2B3C -Keys e,c,h,o,space,h,i,enter
.EXAMPLE
send-input.ps1 -Hwnd 0x1A2B3C -Text 'echo Жж😀'
#>
param(
    [Parameter(Mandatory)][string]$Hwnd,
    [string]$Text,
    [string[]]$Keys,
    [string[]]$Scancodes,
    [int]$DelayMs = 15
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'lib\Harness.psm1') -Force

if (-not (Test-InteractiveSession)) {
    Write-Output "SKIP send-input: $(Get-SkipReason)"
    return
}

$modes = @(@([bool]$Text, [bool]$Keys, [bool]$Scancodes) | Where-Object { $_ }).Count
if ($modes -ne 1) { throw 'give exactly one of -Text, -Keys, -Scancodes' }

if (-not ('GhosttySendInput.Native' -as [type])) {
    Add-Type -Namespace GhosttySendInput -Name Native -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
[DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
public static uint Send(ushort[] vk, ushort[] scan, uint[] flags) {
    INPUT[] inputs = new INPUT[vk.Length];
    for (int i = 0; i < vk.Length; i++) {
        inputs[i].type = 1;
        inputs[i].u.ki.wVk = vk[i];
        inputs[i].u.ki.wScan = scan[i];
        inputs[i].u.ki.dwFlags = flags[i];
    }
    return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
}
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
[DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint thread);
[DllImport("user32.dll")] public static extern short VkKeyScanExW(char ch, IntPtr hkl);
[DllImport("user32.dll")] public static extern uint MapVirtualKeyExW(uint code, uint type, IntPtr hkl);
"@
}

$KEYEVENTF_EXTENDEDKEY = 0x1
$KEYEVENTF_KEYUP = 0x2
$KEYEVENTF_UNICODE = 0x4
$KEYEVENTF_SCANCODE = 0x8

$VK = @{
    shift = 0x10; ctrl = 0x11; alt = 0x12; win = 0x5B
    enter = 0x0D; tab = 0x09; space = 0x20; esc = 0x1B; backspace = 0x08
    delete = 0x2E; insert = 0x2D; home = 0x24; end = 0x23; pageup = 0x21; pagedown = 0x22
    left = 0x25; up = 0x26; right = 0x27; down = 0x28; plus = 0xBB
}
1..12 | ForEach-Object { $VK["f$_"] = 0x6F + $_ }
# Keys that carry the E0 prefix.
$EXTENDED = 'delete', 'insert', 'home', 'end', 'pageup', 'pagedown', 'left', 'up', 'right', 'down'

$target = [IntPtr][Convert]::ToInt64($Hwnd, $(if ($Hwnd -like '0x*') { 16 } else { 10 }))

# Sends `$events` in one SendInput call. Should that fail part-way, a key
# may be left pressed on the user's machine, so `$release` (the matching
# key-ups) is sent before the error propagates.
function Send-Events([object[]]$events, [object[]]$release = @()) {
    $ok = $false
    try {
        $vk = [uint16[]]@($events | ForEach-Object { $_.Vk })
        $scan = [uint16[]]@($events | ForEach-Object { $_.Scan })
        $flags = [uint32[]]@($events | ForEach-Object { $_.Flags })
        $sent = [GhosttySendInput.Native]::Send($vk, $scan, $flags)
        if ($sent -ne $events.Count) { throw "SendInput sent $sent of $($events.Count) events" }
        $ok = $true
    } finally {
        if (-not $ok -and $release.Count -gt 0) {
            try {
                [void][GhosttySendInput.Native]::Send(
                    [uint16[]]@($release | ForEach-Object { $_.Vk }),
                    [uint16[]]@($release | ForEach-Object { $_.Scan }),
                    [uint32[]]@($release | ForEach-Object { $_.Flags }))
            } catch { }
        }
    }
}

# Refuse to type anywhere but the target window.
function Assert-Foreground {
    if ([GhosttySendInput.Native]::GetForegroundWindow() -ne $target) {
        throw "target window $target lost the foreground to $([GhosttySendInput.Native]::GetForegroundWindow()); stopped typing"
    }
}

function New-Event($vk, $scan, $flags) { [pscustomobject]@{ Vk = $vk; Scan = $scan; Flags = $flags } }

function Get-TargetLayout {
    $pid_ = [uint32]0
    $thread = [GhosttySendInput.Native]::GetWindowThreadProcessId($target, [ref]$pid_)
    [GhosttySendInput.Native]::GetKeyboardLayout($thread)
}

function Resolve-Key([string]$name, [IntPtr]$hkl) {
    $lower = $name.ToLowerInvariant()
    if ($VK.ContainsKey($lower)) {
        $vk = $VK[$lower]
        $ext = if ($EXTENDED -contains $lower) { $KEYEVENTF_EXTENDEDKEY } else { 0 }
        $scan = [GhosttySendInput.Native]::MapVirtualKeyExW($vk, 0, $hkl)
        return [pscustomobject]@{ Vk = $vk; Scan = $scan; Flags = $ext; Shift = $false; Ctrl = $false; Alt = $false; AltGr = $false }
    }
    if ($name.Length -ne 1) { throw "unknown key '$name'" }

    $r = [GhosttySendInput.Native]::VkKeyScanExW($name[0], $hkl)
    if ($r -eq -1) { throw "'$name' is not typeable on the foreground layout" }
    $vk = $r -band 0xFF
    $state = ($r -shr 8) -band 0xFF
    [pscustomobject]@{
        Vk = $vk
        Scan = [GhosttySendInput.Native]::MapVirtualKeyExW($vk, 0, $hkl)
        Flags = 0
        Shift = [bool]($state -band 1)
        Ctrl = [bool](($state -band 6) -eq 2)
        Alt = [bool](($state -band 6) -eq 4)
        AltGr = [bool](($state -band 6) -eq 6)
    }
}

function Send-Chord([string]$spec, [IntPtr]$hkl) {
    $parts = @(if ($spec.Length -gt 1) { $spec -split '\+(?=.)' } else { $spec })
    $mods = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $parts.Count - 1; $i++) { $mods.Add($parts[$i].ToLowerInvariant()) }
    $k = Resolve-Key $parts[-1] $hkl

    $held = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $mods) {
        if ($m -notin 'shift', 'ctrl', 'alt', 'win') { throw "unknown modifier '$m' in '$spec'" }
        $held.Add((New-Event $VK[$m] ([GhosttySendInput.Native]::MapVirtualKeyExW($VK[$m], 0, $hkl)) 0))
    }
    # What the character itself needs: Windows turns right Alt into AltGr.
    if ($k.Shift -and $mods -notcontains 'shift') { $held.Add((New-Event $VK.shift 0x2A 0)) }
    if ($k.Ctrl -and $mods -notcontains 'ctrl') { $held.Add((New-Event $VK.ctrl 0x1D 0)) }
    if ($k.Alt -and $mods -notcontains 'alt') { $held.Add((New-Event $VK.alt 0x38 0)) }
    if ($k.AltGr) { $held.Add((New-Event 0xA5 0x38 $KEYEVENTF_EXTENDEDKEY)) }

    Assert-Foreground
    $events = @()
    foreach ($h in $held) { $events += $h }
    $events += New-Event $k.Vk $k.Scan $k.Flags
    $release = @()
    $release += New-Event $k.Vk $k.Scan ($k.Flags -bor $KEYEVENTF_KEYUP)
    for ($i = $held.Count - 1; $i -ge 0; $i--) {
        $release += New-Event $held[$i].Vk $held[$i].Scan ($held[$i].Flags -bor $KEYEVENTF_KEYUP)
    }
    Send-Events ($events + $release) -Release $release
}

if (-not (Set-ForegroundSafe -Hwnd $target)) {
    Write-Output 'SKIP send-input: could not take the foreground'
    return
}
Start-Sleep -Milliseconds 100

if ($Text) {
    # One unit at a time: surrogate halves are separate events, as an IME
    # or the touch keyboard sends them.
    foreach ($unit in $Text.ToCharArray()) {
        Assert-Foreground
        $up = New-Event 0 ([int]$unit) ($KEYEVENTF_UNICODE -bor $KEYEVENTF_KEYUP)
        Send-Events @((New-Event 0 ([int]$unit) $KEYEVENTF_UNICODE), $up) -Release @($up)
        Start-Sleep -Milliseconds $DelayMs
    }
} elseif ($Keys) {
    $hkl = Get-TargetLayout
    foreach ($spec in $Keys) {
        Send-Chord $spec $hkl
        Start-Sleep -Milliseconds $DelayMs
    }
} else {
    foreach ($s in $Scancodes) {
        $code = [Convert]::ToInt32($s, $(if ($s -like '0x*') { 16 } else { 10 }))
        $flags = $KEYEVENTF_SCANCODE
        if (($code -band 0xFF00) -eq 0xE000) { $flags = $flags -bor $KEYEVENTF_EXTENDEDKEY }
        Assert-Foreground
        $up = New-Event 0 ($code -band 0xFF) ($flags -bor $KEYEVENTF_KEYUP)
        Send-Events @((New-Event 0 ($code -band 0xFF) $flags), $up) -Release @($up)
        Start-Sleep -Milliseconds $DelayMs
    }
}
