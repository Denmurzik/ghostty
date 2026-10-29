# Helpers shared by the Windows release scripts (Windows PowerShell 5.1).
# ASCII only. Import with: Import-Module <this file> -Force -DisableNameChecking
Set-StrictMode -Version Latest

function Find-GitBash {
    <# Git Bash by full path. A bare `bash` is WSL's on this machine. #>
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path $env:ProgramFiles 'Git\usr\bin\bash.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    throw ('Git Bash not found; looked for: ' + ($candidates -join ' and '))
}

function ConvertTo-NativeArg {
    param([string]$Arg)
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[\s"]') { return $Arg }
    # CommandLineToArgvW rules: double the backslashes before a quote and
    # before the closing quote, escape the quotes.
    $s = $Arg -replace '(\\*)"', '$1$1\"'
    $s = $s -replace '(\\+)$', '$1$1'
    return '"' + $s + '"'
}

function Invoke-Native {
    <#
    Runs a native command, tees stdout and stderr to -Log and to the host,
    and decides on the exit code only. A stderr line never aborts the caller.
    Returns the exit code (124 after -TimeoutSec, with the process tree killed).
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Args = @(),
        [Parameter(Mandatory)][string]$Log,
        [int]$TimeoutSec = 0,
        [switch]$Quiet,
        # A ready-made command line, used as it is instead of -Args (for
        # commands such as a signing line that carries its own quoting).
        [string]$CmdLine = '',
        # Log "command line hidden" instead of the line (secrets in a signing line).
        [switch]$HideCmdLine
    )
    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $line = if ($CmdLine.Length -gt 0) { $CmdLine } else { ($Args | ForEach-Object { ConvertTo-NativeArg ([string]$_) }) -join ' ' }
        $sp = @{
            FilePath               = $Exe
            NoNewWindow            = $true
            PassThru               = $true
            RedirectStandardOutput = $out
            RedirectStandardError  = $err
        }
        if ($line.Length -gt 0) { $sp.ArgumentList = $line }
        $p = Start-Process @sp
        $null = $p.Handle   # keeps ExitCode readable after exit
        $code = 0
        if ($TimeoutSec -gt 0) {
            if (-not $p.WaitForExit($TimeoutSec * 1000)) {
                & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null
                $null = $p.WaitForExit(5000)
                $code = 124
            } else {
                $p.WaitForExit()
                $code = $p.ExitCode
            }
        } else {
            $p.WaitForExit()
            $code = $p.ExitCode
        }
        $text = @()
        foreach ($f in @($out, $err)) {
            $t = [IO.File]::ReadAllText($f)
            if ($t.Length -gt 0) { $text += $t }
        }
        $all = ($text -join '')
        if ($code -eq 124) { $all += "`r`n[timeout after $TimeoutSec s]`r`n" }
        $logDir = Split-Path -Parent $Log
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        }
        $shown = if ($HideCmdLine) { '(command line hidden)' } else { $line }
        [IO.File]::AppendAllText($Log, '> ' + $Exe + ' ' + $shown + "`r`n" + $all + "[exit $code]`r`n")
        if (-not $Quiet -and $all.Length -gt 0) { Write-Host $all.TrimEnd() }
        return [int]$code
    } finally {
        $ErrorActionPreference = $saved
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    }
}

function Get-FreeMemoryMB {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    return [int]([math]::Floor($os.FreePhysicalMemory / 1024))
}

function Initialize-PrivacyScan {
    if ('GhosttyPrivacyScan' -as [type]) { return }
    Add-Type -TypeDefinition @'
public static class GhosttyPrivacyScan {
    // Data and needle are both compared with the bytes A-Z folded to a-z
    // (a stray 0x41-0x5A byte inside a UTF-16 or UTF-8 character folds alike).
    public static long Find(byte[] data, byte[] needleIn, long start) {
        byte[] needle = (byte[])needleIn.Clone();
        for (int k = 0; k < needle.Length; k++) if (needle[k] >= 0x41 && needle[k] <= 0x5A) needle[k] += 0x20;
        int n = needle.Length;
        if (n == 0) return -1;
        long last = (long)data.Length - n;
        byte first = needle[0];
        for (long i = start; i <= last; i++) {
            byte b = data[i];
            if (b >= 0x41 && b <= 0x5A) b = (byte)(b + 0x20);
            if (b != first) continue;
            int j = 1;
            for (; j < n; j++) {
                byte c = data[i + j];
                if (c >= 0x41 && c <= 0x5A) c = (byte)(c + 0x20);
                if (c != needle[j]) break;
            }
            if (j == n) return i;
        }
        return -1;
    }
}
'@
}

function Get-PrivacyNeedle {
    # Returns objects { Bytes; Class } for the identity strings in UTF-8 and
    # UTF-16LE. The data is folded A-Z only, so ASCII letters are lower-cased
    # here and non-ASCII letters get a lower, upper and title variant.
    param([string[]]$UserName, [string]$UserProfile)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($u in @($UserName | Where-Object { $_ })) {
        if ($u.Length -ge 4) {
            $items.Add(@{ Text = $u; Class = 'user name' })
        } else {
            $items.Add(@{ Text = '\Users\' + $u; Class = 'user name' })
            $items.Add(@{ Text = '/Users/' + $u; Class = 'user name' })
        }
    }
    if ($UserProfile) {
        $items.Add(@{ Text = $UserProfile; Class = 'profile path' })
        $items.Add(@{ Text = $UserProfile.Replace('\', '/'); Class = 'profile path' })
    }
    $seen = @{}
    $needles = New-Object System.Collections.Generic.List[object]
    foreach ($it in $items) {
        $t = [string]$it.Text
        # Title variant: the first letter of each path segment in upper case.
        $tb = New-Object System.Text.StringBuilder
        $atStart = $true
        foreach ($ch in $t.ToLowerInvariant().ToCharArray()) {
            if ($atStart) { [void]$tb.Append([char]::ToUpperInvariant($ch)) } else { [void]$tb.Append($ch) }
            $atStart = ($ch -eq [char]92 -or $ch -eq [char]47 -or $ch -eq [char]32)
        }
        $title = $tb.ToString()
        foreach ($v in @($t.ToLowerInvariant(), $t.ToUpperInvariant(), $title)) {
            $folded = New-Object System.Text.StringBuilder
            foreach ($ch in $v.ToCharArray()) {
                if ($ch -ge 'A' -and $ch -le 'Z') { [void]$folded.Append([char]([int]$ch + 32)) } else { [void]$folded.Append($ch) }
            }
            foreach ($enc in @([Text.Encoding]::UTF8, [Text.Encoding]::Unicode)) {
                $b = $enc.GetBytes($folded.ToString())
                $k = [BitConverter]::ToString($b)
                if (-not $seen.ContainsKey($k)) {
                    $seen[$k] = $true
                    $needles.Add([pscustomobject]@{ Bytes = [byte[]]$b; Class = $it.Class })
                }
            }
        }
    }
    return , $needles.ToArray()
}

function Test-Privacy {
    <#
    Scans one file for the Windows user name and %USERPROFILE%, as UTF-8 and
    UTF-16LE, case-insensitively. A name shorter than 4 characters is searched
    only as \Users\<name>. Returns $null, or "<offset>: <user name|profile path>".
    It never returns the bytes around the hit. With no identity to search for
    it throws (fail closed). -SelfTest runs the built-in checks.
    #>
    param(
        [string]$Path,
        [string]$UserName = $env:USERNAME,
        [string]$UserProfile = $env:USERPROFILE,
        [switch]$SelfTest
    )
    if ($SelfTest) { return Invoke-PrivacySelfTest }
    Initialize-PrivacyScan
    $names = @($UserName)
    if (-not $PSBoundParameters.ContainsKey('UserName')) { $names += [Environment]::UserName }
    $needles = Get-PrivacyNeedle -UserName $names -UserProfile $UserProfile
    if ($needles.Count -eq 0) { throw 'Test-Privacy: no user name or profile path to search for (refusing to report clean)' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Test-Privacy: no such file: $Path" }
    $data = [IO.File]::ReadAllBytes($Path)
    $best = -1L
    $class = ''
    foreach ($n in $needles) {
        $o = [GhosttyPrivacyScan]::Find($data, $n.Bytes, 0)
        if ($o -ge 0 -and ($best -lt 0 -or $o -lt $best)) { $best = $o; $class = $n.Class }
    }
    if ($best -lt 0) { return $null }
    return ('{0}: {1}' -f $best, $class)
}

function Invoke-PrivacySelfTest {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('ghostty-privacy-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $fail = New-Object System.Collections.Generic.List[string]
    try {
        $pad = [byte[]](@(0x41) * 64)
        # A Cyrillic name built from code points (the script stays ASCII).
        $cyr = -join ([char[]](0x041C, 0x0443, 0x0440, 0x0443, 0x0435, 0x0432))
        $u8 = [Text.Encoding]::UTF8
        $u16 = [Text.Encoding]::Unicode
        $asc = [Text.Encoding]::ASCII
        $cases = @(
            @{ n = 'ascii';  b = $asc.GetBytes('xx sampleuser yy'); user = 'SampleUser'; prof = 'Z:\x1'; hit = $true; cls = 'user name' },
            @{ n = 'utf16';  b = $u16.GetBytes('SampleUser'); user = 'SampleUser'; prof = 'Z:\x1'; hit = $true; cls = 'user name' },
            @{ n = 'mixed';  b = $asc.GetBytes('sAmPlEuSeR'); user = 'SampleUser'; prof = 'Z:\x1'; hit = $true; cls = 'user name' },
            @{ n = 'clean';  b = $asc.GetBytes('nothing to see here'); user = 'SampleUser'; prof = 'Z:\x1'; hit = $false },
            @{ n = 'profile-slash'; b = $asc.GetBytes('see c:/users/qqqqq/appdata'); user = 'zzzzzz'; prof = 'C:\Users\qqqqq'; hit = $true; cls = 'profile path' },
            @{ n = 'short-bare'; b = $asc.GetBytes('the word abc alone'); user = 'abc'; prof = 'Z:\x1'; hit = $false },
            @{ n = 'short-users'; b = $asc.GetBytes('D:\uSERS\ABC\x'); user = 'abc'; prof = 'Z:\x1'; hit = $true; cls = 'user name' },
            @{ n = 'short-users16'; b = $u16.GetBytes('\Users\abc'); user = 'abc'; prof = 'Z:\x1'; hit = $true; cls = 'user name' },
            @{ n = 'cyr-utf8'; b = $u8.GetBytes('C:\Users\' + $cyr + '\x'); user = $cyr; prof = 'Z:\x1'; hit = $true; cls = 'user name' },
            @{ n = 'cyr-utf16'; b = $u16.GetBytes($cyr); user = $cyr; prof = 'Z:\x1'; hit = $true; cls = 'user name' },
            @{ n = 'cyr-upper-utf8'; b = $u8.GetBytes($cyr.ToUpperInvariant()); user = $cyr; prof = 'Z:\x1'; hit = $true; cls = 'user name' },
            @{ n = 'cyr-lower-utf16'; b = $u16.GetBytes($cyr.ToLowerInvariant()); user = $cyr; prof = 'Z:\x1'; hit = $true; cls = 'user name' },
            @{ n = 'cyr-profile-utf8'; b = $u8.GetBytes('C:\Users\' + $cyr); user = 'zzzzzz'; prof = 'C:\Users\' + $cyr; hit = $true; cls = 'profile path' }
        )
        foreach ($c in $cases) {
            $p = Join-Path $dir $c.n
            [IO.File]::WriteAllBytes($p, [byte[]]($pad + [byte[]]$c.b + $pad))
            $r = Test-Privacy -Path $p -UserName $c.user -UserProfile $c.prof
            if (($null -ne $r) -ne $c.hit) { $fail.Add(('case {0}: expected hit={1}, got [{2}]' -f $c.n, $c.hit, $r)); continue }
            if ($c.hit) {
                if ($r -notmatch '^\d+: (user name|profile path)$') { $fail.Add("case $($c.n): bad result format [$r]") }
                elseif ($r -notlike ('*: ' + $c.cls)) { $fail.Add("case $($c.n): wrong class [$r]") }
                # The result must never carry the identity text itself.
                if ($r.ToLowerInvariant().Contains($c.user.ToLowerInvariant())) { $fail.Add("case $($c.n): result leaks the name [$r]") }
            }
        }
        $r = Test-Privacy -Path (Join-Path $dir 'ascii') -UserName 'SampleUser' -UserProfile 'Z:\x1'
        if ($r -notmatch '^(6[4-9]|7\d): ') { $fail.Add("offset of the ascii hit looks wrong: [$r]") }
        # Fail closed: nothing to search for must throw, never report clean.
        foreach ($empty in @(@{ u = ''; p = '' }, @{ u = $null; p = $null })) {
            $threw = $false
            try { $null = Test-Privacy -Path (Join-Path $dir 'clean') -UserName $empty.u -UserProfile $empty.p } catch { $threw = $true }
            if (-not $threw) { $fail.Add('empty identity did not throw') }
        }
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($fail.Count -gt 0) { throw ('Test-Privacy self-test failed: ' + ($fail -join '; ')) }
    return $true
}

function Read-PeHeader {
    # Parses a PE file's section table and data directories; throws on anything malformed.
    param([byte[]]$Bytes)
    $n = $Bytes.Length
    if ($n -lt 0x100 -or $Bytes[0] -ne 0x4D -or $Bytes[1] -ne 0x5A) { throw 'not a PE file (no MZ header)' }
    $pe = [BitConverter]::ToInt32($Bytes, 0x3C)
    if ($pe -lt 0 -or $pe + 24 -gt $n -or [BitConverter]::ToUInt32($Bytes, $pe) -ne 0x00004550) { throw 'not a PE file (no PE signature)' }
    $nsec = [BitConverter]::ToUInt16($Bytes, $pe + 6)
    $osz = [BitConverter]::ToUInt16($Bytes, $pe + 20)
    $opt = $pe + 24
    if ($opt + $osz + 40 * $nsec -gt $n) { throw 'PE headers run past the end of the file' }
    $magic = [BitConverter]::ToUInt16($Bytes, $opt)
    if ($magic -ne 0x20B -and $magic -ne 0x10B) { throw 'unknown PE optional header' }
    $dd = $opt + $(if ($magic -eq 0x20B) { 112 } else { 96 })
    $secs = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $nsec; $i++) {
        $o = $opt + $osz + 40 * $i
        $secs.Add([pscustomobject]@{
                VA  = [BitConverter]::ToUInt32($Bytes, $o + 12)
                VS  = [Math]::Max([BitConverter]::ToUInt32($Bytes, $o + 8), [BitConverter]::ToUInt32($Bytes, $o + 16))
                Raw = [BitConverter]::ToUInt32($Bytes, $o + 20)
            })
    }
    return [pscustomobject]@{
        Machine = [BitConverter]::ToUInt16($Bytes, $pe + 4)
        DataDir = $dd
        Count   = [BitConverter]::ToUInt32($Bytes, $dd - 4)
        Sections = $secs
    }
}

function ConvertTo-PeOffset {
    param($Hdr, [uint32]$Rva, [int]$Length)
    foreach ($s in $Hdr.Sections) {
        if ($Rva -ge $s.VA -and $Rva -lt ([uint64]$s.VA + $s.VS)) {
            $off = [uint64]$Rva - $s.VA + $s.Raw
            if ($off -lt $Length) { return [int]$off }
        }
    }
    throw ('PE address 0x{0:X} is outside every section' -f $Rva)
}

function Get-PeMachine {
    <# The PE machine type: 0x8664 (x64), 0xAA64 (arm64). Throws on a malformed file. #>
    param([Parameter(Mandatory)][string]$Path)
    return (Read-PeHeader ([IO.File]::ReadAllBytes($Path))).Machine
}

function Get-PeImports {
    <# Lower-case DLL names a PE file imports (normal and delay-load tables).
       Replaces dumpbin /imports; throws on anything malformed (fail closed). #>
    param([Parameter(Mandatory)][string]$Path)
    $b = [IO.File]::ReadAllBytes($Path)
    $h = Read-PeHeader $b
    $names = @{}
    # Directory 1 = import (20-byte descriptors, name at +12); 13 = delay import (32-byte, name at +4).
    foreach ($d in @(@{ Idx = 1; Size = 20; NameAt = 12 }, @{ Idx = 13; Size = 32; NameAt = 4 })) {
        if ($h.Count -le $d.Idx) { continue }
        $rva = [BitConverter]::ToUInt32($b, $h.DataDir + 8 * $d.Idx)
        if ($rva -eq 0) { continue }
        $o = ConvertTo-PeOffset $h $rva $b.Length
        for ($k = 0; $k -lt 4096; $k++) {
            if ($o + $d.Size -gt $b.Length) { throw 'import table runs past the end of the file' }
            $nameRva = [BitConverter]::ToUInt32($b, $o + $d.NameAt)
            if ($nameRva -eq 0) { break }
            $so = ConvertTo-PeOffset $h $nameRva $b.Length
            $e = $so
            while ($e -lt $b.Length -and $b[$e] -ne 0) { $e++ }
            if ($e -ge $b.Length -or $e -eq $so -or $e - $so -gt 255) { throw 'bad import name' }
            $names[[Text.Encoding]::ASCII.GetString($b, $so, $e - $so).ToLowerInvariant()] = $true
            $o += $d.Size
        }
        if ($k -ge 4096) { throw 'import table has no end' }
    }
    return @($names.Keys | Sort-Object)
}

Export-ModuleMember -Function Find-GitBash, Invoke-Native, Get-FreeMemoryMB, Test-Privacy, Get-PeImports, Get-PeMachine
