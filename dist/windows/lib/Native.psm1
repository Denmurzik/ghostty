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
        [string]$CmdLine = ''
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
        [IO.File]::AppendAllText($Log, '> ' + $Exe + ' ' + $line + "`r`n" + $all + "[exit $code]`r`n")
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
    // Needles are given lower-cased; the data is compared with A-Z folded.
    public static long Find(byte[] data, byte[] needle, long start) {
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
    param([string]$UserName, [string]$UserProfile)
    $texts = New-Object System.Collections.Generic.List[string]
    if ($UserName) {
        if ($UserName.Length -ge 4) {
            $texts.Add($UserName)
        } else {
            $texts.Add('\Users\' + $UserName)
            $texts.Add('/Users/' + $UserName)
        }
    }
    if ($UserProfile) {
        $texts.Add($UserProfile)
        $texts.Add($UserProfile.Replace('\', '/'))
    }
    $needles = New-Object System.Collections.Generic.List[byte[]]
    foreach ($t in ($texts | Select-Object -Unique)) {
        $lower = $t.ToLowerInvariant()
        $needles.Add([Text.Encoding]::ASCII.GetBytes($lower))
        $needles.Add([Text.Encoding]::Unicode.GetBytes($lower))
    }
    return , $needles.ToArray()
}

function Format-PrivacyContext {
    param([byte[]]$Data, [long]$Offset)
    $from = [int][math]::Max(0, $Offset - 10)
    $len = [int][math]::Min(40, $Data.Length - $from)
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $len; $i++) {
        $b = $Data[$from + $i]
        if ($b -eq 0) { continue }          # UTF-16LE padding
        if ($b -ge 0x20 -and $b -lt 0x7F) { [void]$sb.Append([char]$b) } else { [void]$sb.Append('.') }
    }
    return $sb.ToString()
}

function Test-Privacy {
    <#
    Scans one file for the Windows user name and %USERPROFILE%, as ASCII and
    UTF-16LE, case-insensitively. A name shorter than 4 characters is searched
    only as \Users\<name>. Returns $null, or "<offset>: <context>".
    -SelfTest runs the built-in checks and returns $true or throws.
    #>
    param(
        [string]$Path,
        [string]$UserName = $env:USERNAME,
        [string]$UserProfile = $env:USERPROFILE,
        [switch]$SelfTest
    )
    if ($SelfTest) { return Invoke-PrivacySelfTest }
    Initialize-PrivacyScan
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Test-Privacy: no such file: $Path" }
    $needles = Get-PrivacyNeedle -UserName $UserName -UserProfile $UserProfile
    $data = [IO.File]::ReadAllBytes($Path)
    $best = -1L
    foreach ($n in $needles) {
        $o = [GhosttyPrivacyScan]::Find($data, $n, 0)
        if ($o -ge 0 -and ($best -lt 0 -or $o -lt $best)) { $best = $o }
    }
    if ($best -lt 0) { return $null }
    return ('{0}: {1}' -f $best, (Format-PrivacyContext -Data $data -Offset $best))
}

function Invoke-PrivacySelfTest {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('ghostty-privacy-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $fail = New-Object System.Collections.Generic.List[string]
    try {
        $pad = [byte[]](@(0x41) * 64)
        $cases = @(
            @{ n = 'ascii';  b = [Text.Encoding]::ASCII.GetBytes('xx sampleuser yy'); user = 'SampleUser'; prof = 'Z:\x1'; hit = $true },
            @{ n = 'utf16';  b = [Text.Encoding]::Unicode.GetBytes('SampleUser'); user = 'SampleUser'; prof = 'Z:\x1'; hit = $true },
            @{ n = 'mixed';  b = [Text.Encoding]::ASCII.GetBytes('sAmPlEuSeR'); user = 'SampleUser'; prof = 'Z:\x1'; hit = $true },
            @{ n = 'clean';  b = [Text.Encoding]::ASCII.GetBytes('nothing to see here'); user = 'SampleUser'; prof = 'Z:\x1'; hit = $false },
            @{ n = 'profile-slash'; b = [Text.Encoding]::ASCII.GetBytes('see c:/users/qqqqq/appdata'); user = 'zzzzzz'; prof = 'C:\Users\qqqqq'; hit = $true },
            @{ n = 'short-bare'; b = [Text.Encoding]::ASCII.GetBytes('the word abc alone'); user = 'abc'; prof = 'Z:\x1'; hit = $false },
            @{ n = 'short-users'; b = [Text.Encoding]::ASCII.GetBytes('D:\uSERS\ABC\x'); user = 'abc'; prof = 'Z:\x1'; hit = $true },
            @{ n = 'short-users16'; b = [Text.Encoding]::Unicode.GetBytes('\Users\abc'); user = 'abc'; prof = 'Z:\x1'; hit = $true }
        )
        foreach ($c in $cases) {
            $p = Join-Path $dir $c.n
            [IO.File]::WriteAllBytes($p, [byte[]]($pad + [byte[]]$c.b + $pad))
            $r = Test-Privacy -Path $p -UserName $c.user -UserProfile $c.prof
            if (($null -ne $r) -ne $c.hit) { $fail.Add(('case {0}: expected hit={1}, got [{2}]' -f $c.n, $c.hit, $r)) }
            if ($c.hit -and $r -and $r -notmatch '^\d+: ') { $fail.Add("case $($c.n): bad result format [$r]") }
        }
        $r = Test-Privacy -Path (Join-Path $dir 'ascii') -UserName 'SampleUser' -UserProfile 'Z:\x1'
        if ($r -notmatch '^(6[4-9]|7\d): ') { $fail.Add("offset of the ascii hit looks wrong: [$r]") }
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($fail.Count -gt 0) { throw ('Test-Privacy self-test failed: ' + ($fail -join '; ')) }
    return $true
}

Export-ModuleMember -Function Find-GitBash, Invoke-Native, Get-FreeMemoryMB, Test-Privacy
