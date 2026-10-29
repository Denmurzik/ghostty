# Local release of Ghostty for Windows (Windows PowerShell 5.1, ASCII only).
# R-M6-6 / R-M6-7 / R-M6-11 / R-M6-12. Read docs\windows\RELEASING.md first.
#
#   release.ps1 -N <string> [-ConptyPackage <nupkg or dir>] [-Rehearsal] [-V1]
#               [-OutDir <dir>] [-Force] [-SignCommand '<cmd with {file}>']
#               [-Arm64Abi gnu|msvc] [-Arm64TestExe] [-Arm64Result <text>]
#               [-SkipTests] [-DryRun] [-Zig <path>] [-Lock <path>]
#               [-MinFreeGB <n>] [-Jobs <n>]
#
# Steps (each prints "== n/9 name", appends to <OutDir>\release.log, and the
# first failure stops the run naming the step):
#   1 Preflight  2 Unit tests  3 Build x64  4 Build arm64  5 Package
#   6 Check  7 Sums  8 Notes  9 Publish commands
#
# The script makes no network call and runs no git tag, git push or gh
# command: step 9 only PRINTS them (and writes publish.txt) for the owner.
# -DryRun runs the preflight and prints steps 2-9 with their command lines.
# -ConptyPackage omitted: the vendored copy under vendor\conpty is used.
[CmdletBinding()]
param(
    [string]$N = '',
    [string]$ConptyPackage = '',
    [switch]$Rehearsal,
    [switch]$V1,
    [string]$OutDir = '',
    [switch]$Force,
    [string]$SignCommand = '',
    [ValidateSet('gnu', 'msvc')][string]$Arm64Abi = 'gnu',
    [switch]$Arm64TestExe,
    [string]$Arm64Result = '',
    [switch]$SkipTests,
    [switch]$DryRun,
    [switch]$SelfTest,
    [string]$Zig = '',
    [string]$Lock = '',
    # Free physical memory required before each heavy step. G1 measured a
    # 4.9 GB peak for the -Dstrip=false x64 build (-j4); 7 GB is that peak
    # plus 2 GB, rounded up.
    [double]$MinFreeGB = 7,
    # Parallel jobs for every zig build and test step. 2 keeps the test
    # groups (which link several test exes) inside 16 GB machines; the
    # first rehearsal with -j6 ran out of memory.
    [ValidateRange(1, 64)][int]$Jobs = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\Native.psm1') -Force -DisableNameChecking
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$total = 9
$stepNames = @('Preflight', 'Unit tests', 'Build x64', 'Build arm64', 'Package', 'Check', 'Sums', 'Notes', 'Publish commands')
$conptyVersion = '1.25.260930003'
$ghRepo = 'Denmurzik/ghostty'

$script:LogPath = Join-Path ([IO.Path]::GetTempPath()) ('ghostty-release-' + [guid]::NewGuid().ToString('N') + '.log')
$script:CurStep = 0
$script:TempDirs = New-Object System.Collections.Generic.List[string]

# ---- small helpers -------------------------------------------------------

function Write-Log([string]$text) {
    [IO.File]::AppendAllText($script:LogPath, $text + "`r`n")
}

function Start-Step([int]$n) {
    $script:CurStep = $n
    $line = "== $n/$total $($stepNames[$n - 1])"
    Write-Host $line
    Write-Log $line
}

function Format-Arg([string]$a) {
    if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { return $a }
    return '"' + ($a -replace '"', '\"') + '"'
}

function Format-Cmd([string]$exe, [string[]]$argList) {
    return ((@($exe) + @($argList | ForEach-Object { Format-Arg ([string]$_) })) -join ' ')
}

function ConvertTo-Posix([string]$p) { return $p.Replace('\', '/') }

function Quote-Ps([string]$s) { return "'" + $s.Replace("'", "''") + "'" }

# Runs a native command through Invoke-Native with a private log, appends
# that log to release.log, and returns @{ Code; Text }.
function Invoke-Logged {
    param(
        [string]$Exe,
        [string[]]$ArgList = @(),
        [int]$TimeoutSec = 0,
        [switch]$Quiet,
        [switch]$HideCmdLine
    )
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ghostty-rel-' + [guid]::NewGuid().ToString('N') + '.log')
    try {
        $p = @{ Exe = $Exe; Args = $ArgList; Log = $tmp; TimeoutSec = $TimeoutSec }
        if ($Quiet) { $p.Quiet = $true }
        if ($HideCmdLine) { $p.HideCmdLine = $true }
        $code = Invoke-Native @p
        $text = ''
        if (Test-Path -LiteralPath $tmp) { $text = [IO.File]::ReadAllText($tmp) }
        [IO.File]::AppendAllText($script:LogPath, $text)
        return @{ Code = [int]$code; Text = $text }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Wait-RamGate([string]$what) {
    $need = [int]($MinFreeGB * 1024)
    $waited = 0
    while ($true) {
        $free = Get-FreeMemoryMB
        if ($free -ge $need) {
            Write-Log "ram gate ok before ${what}: $free MB free (gate $need MB)"
            return
        }
        if ($waited -ge 900) {
            throw "free memory $free MB is below the gate of $need MB before $what (waited 15 min); close other programs or pass a lower -MinFreeGB"
        }
        if ($waited -eq 0) { Write-Host "  waiting for memory: $free MB free, gate $need MB" }
        Start-Sleep -Seconds 15
        $waited += 15
    }
}

function Get-TestCounts([string]$text) {
    $ms = [regex]::Matches($text, '(\d+)/(\d+) tests passed(?: \(([^)]*)\))?')
    if ($ms.Count -eq 0) { return $null }
    $m = $ms[$ms.Count - 1]
    $extra = $m.Groups[3].Value
    $skip = 0
    $fail = 0
    if ($extra -match '(\d+) skipped') { $skip = [int]$Matches[1] }
    if ($extra -match '(\d+) failed') { $fail += [int]$Matches[1] }
    if ($extra -match '(\d+) crashed') { $fail += [int]$Matches[1] }
    if ($extra -match '(\d+) timed out') { $fail += [int]$Matches[1] }
    return @{ Pass = [int]$m.Groups[1].Value; Total = [int]$m.Groups[2].Value; Skip = $skip; Fail = $fail }
}

# Counts of fresh test runs, per commit and group, so that a re-run that
# comes from the zig cache can still report them. Not published.
$countsFile = Join-Path $repo 'zig-out\release\test-counts.txt'

function Get-RecordedCounts([string]$s, [string]$id) {
    if (-not (Test-Path -LiteralPath $countsFile)) { return $null }
    $hit = $null
    foreach ($l in [IO.File]::ReadAllLines($countsFile)) {
        $f = $l -split "`t"
        if ($f.Count -eq 6 -and $f[0] -eq $s -and $f[1] -eq $id) {
            $hit = @{ Pass = [int]$f[2]; Total = [int]$f[3]; Skip = [int]$f[4]; Fail = [int]$f[5] }
        }
    }
    return $hit
}

function Set-RecordedCounts([string]$s, [string]$id, $c) {
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $countsFile)
    $keep = @()
    if (Test-Path -LiteralPath $countsFile) {
        $keep = @([IO.File]::ReadAllLines($countsFile) | Where-Object { $_ -and -not $_.StartsWith("$s`t$id`t") })
    }
    $keep += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f $s, $id, $c.Pass, $c.Total, $c.Skip, $c.Fail)
    [IO.File]::WriteAllLines($countsFile, [string[]]$keep)
}

# A cached run step is a "run test" line of the summary tree that ends in
# "cached" (fixtures: dist\windows\testdata\zig-summary-*.txt).
function Test-CachedRun([string]$text) {
    return [bool]($text -match '(?m)^\s*\+- run test .*\bcached\b')
}

# test-lock prints only the tail of the zig output, and the Build Summary is
# near the top of a long tree; the full log's path is on its last line.
function Get-FullZigText([string]$text) {
    if ($text -match 'full log: (\S+)') {
        $f = $Matches[1]
        if (Test-Path -LiteralPath $f -PathType Leaf) { return [IO.File]::ReadAllText($f) }
    }
    return $text
}

function Invoke-ReleaseSelfTest {
    $d = Join-Path $PSScriptRoot 'testdata'
    $fresh = [IO.File]::ReadAllText((Join-Path $d 'zig-summary-fresh.txt'))
    $cached = [IO.File]::ReadAllText((Join-Path $d 'zig-summary-cached.txt'))
    $fail = @()
    $c = Get-TestCounts $fresh
    if (-not $c -or $c.Pass -ne 89 -or $c.Total -ne 90 -or $c.Skip -ne 1 -or $c.Fail -ne 0) { $fail += 'fresh counts' }
    if (Test-CachedRun $fresh) { $fail += 'fresh text taken as cached' }
    if ($null -ne (Get-TestCounts $cached)) { $fail += 'cached text has counts' }
    if (-not (Test-CachedRun $cached)) { $fail += 'cached text not detected' }
    $ba = Get-BuildArgs 'x86_64-windows-msvc' 'P' 'B'
    if ($ba -notcontains "-Dconpty-dir=B") { $fail += "conpty-dir is not the root passed in" }
    if ($fail.Count -gt 0) { Write-Host ('release self-test FAIL: ' + ($fail -join '; ')); return $false }
    Write-Host 'release self-test: 5 checks passed'
    return $true
}

# ---- state filled by the preflight ---------------------------------------

$bash = ''
$tic = ''
$zigExe = ''
$lockPath = ''
$serial = $false
$zon = ''
$verStr = ''
$tag = ''
$sha = ''
$conpty = $null
$globalCache = Join-Path $repo 'zig-out\zig-global'

$testFiltersG1 = @('-Dtest-filter=win32 ')
$testFiltersG2 = @('-Dtest-filter=windows ', '-Dtest-filter=tmux shim ', '-Dtest-filter=Exec: w', '-Dtest-filter=d3d11 ')
$testFiltersG3 = @('-Dtest-filter=terminal', '-Dtest-filter=config', '-Dtest-filter=input', '-Dtest-filter=font')

# One heavy zig command, through the test-lock when there is one.
function Get-ZigCommand([string[]]$zigArgs, [int]$timeoutSec) {
    if ($serial) {
        return @{ Exe = $zigExe; Args = $zigArgs; Timeout = $timeoutSec }
    }
    $a = @((ConvertTo-Posix $lockPath), '--min-gb', $MinFreeGB.ToString([Globalization.CultureInfo]::InvariantCulture), '--tail', '400', '--', 'timeout', [string]$timeoutSec, (ConvertTo-Posix $zigExe)) + $zigArgs
    # No outer timeout: the lock wait must not count (the inner timeout bounds zig).
    return @{ Exe = $bash; Args = $a; Timeout = 0 }
}

function Invoke-Zig([string]$what, [string[]]$zigArgs, [int]$timeoutSec) {
    Wait-RamGate $what
    $c = Get-ZigCommand $zigArgs $timeoutSec
    $r = Invoke-Logged -Exe $c.Exe -ArgList $c.Args -TimeoutSec $c.Timeout
    $r.FullText = Get-FullZigText $r.Text
    return $r
}

function Show-ZigCommand([string[]]$zigArgs, [int]$timeoutSec) {
    $c = Get-ZigCommand $zigArgs $timeoutSec
    Write-Host ('  $ ' + (Format-Cmd $c.Exe $c.Args))
}

# -Dconpty-dir is the root that holds <arch>\<file> (what Initialize-Conpty lays out), not an arch folder.
function Get-BuildArgs([string]$target, [string]$prefix, [string]$conptyDir) {
    return @('build', "-j$Jobs", '-Doptimize=ReleaseFast', '-Demit-themes=true', '-Demit-terminfo=true', '-Dstrip=false',
        "-Dtic=$tic", "-Dversion-string=$verStr", "-Dconpty-dir=$conptyDir", "-Dtarget=$target", '--prefix', $prefix)
}

# ---- the bundled ConPTY (R-M6-12) -----------------------------------------

function Initialize-Conpty {
    param([string]$Source, [string]$Work)
    $map = @(
        @('x64', 'conpty.dll', 'runtimes/win-x64/native/conpty.dll'),
        @('x64', 'OpenConsole.exe', 'build/native/runtimes/x64/OpenConsole.exe'),
        @('arm64', 'conpty.dll', 'runtimes/win-arm64/native/conpty.dll'),
        @('arm64', 'OpenConsole.exe', 'build/native/runtimes/arm64/OpenConsole.exe')
    )
    $label = ''
    $version = ''
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        $label = 'package ' + (Split-Path -Leaf $Source)
        $zip = [IO.Compression.ZipFile]::OpenRead($Source)
        try {
            $nuspec = $zip.Entries | Where-Object { $_.FullName -like '*.nuspec' } | Select-Object -First 1
            if (-not $nuspec) { throw "$Source has no .nuspec (not a NuGet package)" }
            $rd = New-Object IO.StreamReader($nuspec.Open())
            try { $spec = $rd.ReadToEnd() } finally { $rd.Dispose() }
            if ($spec -notmatch '<id>\s*Microsoft\.Windows\.Console\.ConPTY\s*</id>') { throw "$Source is not Microsoft.Windows.Console.ConPTY" }
            if ($spec -match '<version>\s*([^<\s]+)\s*</version>') { $version = $Matches[1] }
            foreach ($m in $map) {
                $e = $zip.GetEntry($m[2])
                if (-not $e) { throw "$Source lacks $($m[2])" }
                $dst = Join-Path $Work (Join-Path $m[0] $m[1])
                $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst)
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dst, $true)
            }
        } finally { $zip.Dispose() }
    } elseif (Test-Path -LiteralPath $Source -PathType Container) {
        $label = 'folder ' + (Split-Path -Leaf $Source)
        $nus = @(Get-ChildItem -LiteralPath $Source -Filter '*.nuspec' -File -ErrorAction SilentlyContinue)
        $readme = Join-Path $Source 'README.md'
        if ($nus.Count -gt 0) {
            $spec = [IO.File]::ReadAllText($nus[0].FullName)
            if ($spec -match '<version>\s*([^<\s]+)\s*</version>') { $version = $Matches[1] }
        } elseif (Test-Path -LiteralPath $readme) {
            if ([IO.File]::ReadAllText($readme) -match 'Console\.ConPTY`?\s+(\d+\.\d+\.\d+)') { $version = $Matches[1] }
        }
        foreach ($m in $map) {
            $flat = Join-Path $Source (Join-Path $m[0] $m[1])
            $nug = Join-Path $Source $m[2].Replace('/', '\')
            $from = ''
            if (Test-Path -LiteralPath $flat -PathType Leaf) { $from = $flat }
            elseif (Test-Path -LiteralPath $nug -PathType Leaf) { $from = $nug }
            else { throw "$Source lacks $($m[0])\$($m[1]) (or the package path $($m[2]))" }
            $dst = Join-Path $Work (Join-Path $m[0] $m[1])
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst)
            Copy-Item -LiteralPath $from -Destination $dst
        }
    } else {
        throw "ConPTY package not found: $Source"
    }
    if (-not $version) { throw "cannot read the ConPTY package version from $Source" }
    if ($version -ne $conptyVersion) { throw "ConPTY package version is $version, need $conptyVersion" }

    $pinned = @{}
    $pinReadme = Join-Path $repo 'vendor\conpty\README.md'
    if (Test-Path -LiteralPath $pinReadme) {
        foreach ($m in [regex]::Matches([IO.File]::ReadAllText($pinReadme),
                '\|\s*`(x64|arm64)/(conpty\.dll|OpenConsole\.exe)`\s*\|[^|]*\|\s*`([0-9a-f]{64})`\s*\|')) {
            $pinned[$m.Groups[1].Value + '/' + $m.Groups[2].Value] = $m.Groups[3].Value
        }
    }
    $hashes = New-Object System.Collections.Generic.List[string]
    foreach ($m in $map) {
        $key = $m[0] + '/' + $m[1]
        $f = Join-Path $Work (Join-Path $m[0] $m[1])
        $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($pinned.ContainsKey($key) -and $pinned[$key] -ne $h) { throw "$key differs from the hash pinned in vendor\conpty\README.md" }
        $sig = Get-AuthenticodeSignature -LiteralPath $f
        if ($sig.Status -ne 'Valid') { throw "$key signature is $($sig.Status), need Valid" }
        if ($sig.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') {
            throw "$key signer is not Microsoft Corporation"
        }
        $hashes.Add("$key sha256 $h")
    }
    return @{ Version = $version; Label = $label; Hashes = $hashes.ToArray() }
}

# ---- step 1: preflight ------------------------------------------------------

function Invoke-Preflight {
    $problems = New-Object System.Collections.Generic.List[string]

    # release-version.ps1 (tag rules)
    $rvArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'release-version.ps1'), '-N', $N, '-RepoRoot', $repo)
    if ($Rehearsal) { $rvArgs += '-Rehearsal' }
    $rv = Invoke-Logged -Exe 'powershell.exe' -ArgList $rvArgs -TimeoutSec 120 -Quiet
    if ($rv.Code -ne 0) {
        foreach ($l in ($rv.Text -split "`r?`n")) { if ($l -like 'release-version:*') { $problems.Add($l) } }
        if ($problems.Count -eq 0) { $problems.Add("release-version.ps1 failed (exit $($rv.Code))") }
    } else {
        foreach ($l in ($rv.Text -split "`r?`n")) {
            if ($l -match '^zon=(.+)$') { $script:zon = $Matches[1].Trim() }
            elseif ($l -match '^version-string=(.+)$') { $script:verStr = $Matches[1].Trim() }
            elseif ($l -match '^tag=(.+)$') { $script:tag = $Matches[1].Trim() }
            elseif ($l -match '^sha=(.+)$') { $script:sha = $Matches[1].Trim() }
        }
        if (-not $script:verStr -or -not $script:tag -or -not $script:sha) { $problems.Add('release-version.ps1 printed no version/tag/sha') }
    }

    # OutDir
    if ($script:verStr) {
        if (-not $OutDir) {
            $leaf = if ($Rehearsal) { "rehearsal-$($script:zon)" } else { $script:verStr }
            $script:OutDir = Join-Path $repo "zig-out\release\$leaf"
        } else {
            $script:OutDir = if ([IO.Path]::IsPathRooted($OutDir)) { [IO.Path]::GetFullPath($OutDir) } else { [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutDir)) }
        }
        $repoPrefix = $repo.TrimEnd('\') + '\'
        if (-not $script:OutDir.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $problems.Add("OutDir $($script:OutDir) is outside the repository")
        } else {
            $rel = (ConvertTo-Posix $script:OutDir.Substring($repoPrefix.Length))
            $ig = Invoke-Logged -Exe 'git' -ArgList @('-C', $repo, 'check-ignore', '-q', '--', $rel) -TimeoutSec 30 -Quiet
            if ($ig.Code -ne 0) { $problems.Add("OutDir $($script:OutDir) is not ignored by git (it must be under zig-out\)") }
            if (Test-Path -LiteralPath $script:OutDir) {
                if (-not $Force) {
                    $problems.Add("OutDir $($script:OutDir) already exists; pass -Force to replace it")
                } elseif (-not $script:OutDir.StartsWith((Join-Path $repo 'zig-out').TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    $problems.Add("-Force only replaces folders under $repo\zig-out\")
                }
            }
        }
    }

    # Zig
    $z = $Zig
    if (-not $z) {
        $z = 'C:\tools\zig-x86_64-windows-0.17.0\zig.exe'
        if (-not (Test-Path -LiteralPath $z)) {
            $cmd = Get-Command zig.exe -ErrorAction SilentlyContinue
            if ($cmd) { $z = $cmd.Source }
        }
    }
    if (-not (Test-Path -LiteralPath $z -PathType Leaf)) {
        $problems.Add('zig.exe not found (pass -Zig <path>); Zig 0.17.0 is required')
    } else {
        $script:zigExe = (Resolve-Path -LiteralPath $z).Path
        $zv = Invoke-Logged -Exe $script:zigExe -ArgList @('version') -TimeoutSec 60 -Quiet
        if ($zv.Code -ne 0 -or $zv.Text -notmatch '(?m)^0\.17\.\d+') { $problems.Add("zig version is not 0.17.x (exit $($zv.Code))") }
    }

    # Git Bash, tic, test-lock
    try {
        $script:bash = Find-GitBash
        $gitRoot = Split-Path -Parent (Split-Path -Parent $script:bash)
        if ((Split-Path -Leaf (Split-Path -Parent $script:bash)) -eq 'bin' -and (Split-Path -Leaf $gitRoot) -eq 'usr') { $gitRoot = Split-Path -Parent $gitRoot }
        $t = Join-Path $gitRoot 'usr\bin\tic.exe'
        if (Test-Path -LiteralPath $t -PathType Leaf) { $script:tic = $t } else { $problems.Add("tic.exe not found at $t (Git for Windows)") }
    } catch {
        $problems.Add($_.Exception.Message)
    }
    $lk = $Lock
    if (-not $lk) { $lk = Join-Path $env:USERPROFILE '.claude\mods\teamlead\skills\teamlead\scripts\test-lock' }
    if ($script:bash -and (Test-Path -LiteralPath $lk -PathType Leaf)) {
        $script:lockPath = $lk
        Write-Log "test-lock: $lk"
    } else {
        $script:serial = $true
        Write-Host "  test-lock not found ($lk): serial mode (the RAM gate still applies)"
        Write-Log "test-lock not found ($lk): serial mode"
    }

    # ISCC
    $probe = Invoke-Logged -Exe 'powershell.exe' -ArgList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'installer\build.ps1'), '-Probe') -TimeoutSec 60 -Quiet
    if ($probe.Code -ne 0) {
        $msg = (($probe.Text -split "`r?`n") | Where-Object { $_ -like 'ISCC.exe not found*' } | Select-Object -First 1)
        if (-not $msg) { $msg = 'ISCC.exe not found; install Inno Setup 6 or set ISCC' }
        $problems.Add($msg)
    }

    # makeappx (the sparse package of the Explorer menu)
    $sp = Invoke-Logged -Exe 'powershell.exe' -ArgList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'sparse\build-sparse.ps1'), '-Probe') -TimeoutSec 60 -Quiet
    if ($sp.Code -ne 0) {
        $msg = (($sp.Text -split "`r?`n") | Where-Object { $_ -like 'makeappx.exe not found*' } | Select-Object -First 1)
        if (-not $msg) { $msg = 'makeappx.exe not found; install the Windows SDK or set MAKEAPPX' }
        $problems.Add($msg)
    }

    # ConPTY
    $src = $ConptyPackage
    if (-not $src) {
        $src = Join-Path $repo 'vendor\conpty'
        Write-Host '  -ConptyPackage omitted: using the vendored copy under vendor\conpty'
    }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('ghostty-conpty-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $work
    $script:TempDirs.Add($work)
    try {
        $script:conpty = Initialize-Conpty -Source $src -Work $work
        $script:conpty.Work = $work
    } catch {
        $problems.Add('ConPTY: ' + $_.Exception.Message)
    }

    # VS ARM64 component (msvc only)
    if ($Arm64Abi -eq 'msvc') {
        $vsw = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        $have = ''
        if (Test-Path -LiteralPath $vsw) {
            $vr = Invoke-Logged -Exe $vsw -ArgList @('-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64', '-property', 'installationPath') -TimeoutSec 60 -Quiet
            if ($vr.Code -eq 0) { $have = (($vr.Text -split "`r?`n") | Where-Object { $_ -and $_ -notlike '> *' -and $_ -notlike '[[]exit*' } | Select-Object -First 1) }
        }
        if (-not $have) { $problems.Add('-Arm64Abi msvc needs the Visual Studio component Microsoft.VisualStudio.Component.VC.Tools.ARM64 (MSVC ARM64 build tools; admin install), or use the default -Arm64Abi gnu') }
    }

    # RAM
    $free = Get-FreeMemoryMB
    $need = [int]($MinFreeGB * 1024)
    if ($free -lt $need) { $problems.Add("free memory is $free MB, below the gate of $need MB; close other programs") }
    Write-Log "free memory $free MB, gate $need MB"

    if ($problems.Count -gt 0) {
        foreach ($p in $problems) { Write-Host "  MISSING/BAD: $p" }
        throw ("preflight found {0} problem(s)" -f $problems.Count)
    }
    Write-Host "  version-string $verStr, tag $tag, sha $sha"
    Write-Host "  zig $zigExe; tic $tic; ConPTY $($conpty.Version) ($($conpty.Label)); Arm64 ABI $Arm64Abi"
    Write-Log "version-string $verStr tag $tag sha $sha"
    foreach ($h in $conpty.Hashes) { Write-Log "conpty $h" }
}

# ---- plan values that the dry run and the real run share --------------------

function Get-ArtifactNames {
    $x = "ghostty-$verStr-windows-x64"
    $a = "ghostty-$verStr-windows-arm64"
    return @("$x.zip", "$x-setup.exe", "$x-symbols.zip", "$a.zip", "$a-setup.exe", "$a-symbols.zip")
}

function Get-PublishLines {
    param([bool]$NoArm64Symbols)
    $names = @(Get-ArtifactNames)
    if ($NoArm64Symbols) { $names = @($names | Where-Object { $_ -notlike '*arm64-symbols.zip' }) }
    $pre = if ($Rehearsal) { '# REHEARSAL: ' } else { '' }
    $notes = Join-Path $OutDir 'release-notes.md'
    $files = @($names | ForEach-Object { Quote-Ps (Join-Path $OutDir $_) }) + @(Quote-Ps (Join-Path $OutDir 'SHA256SUMS.txt'))
    $t = Quote-Ps $tag
    $title = "Ghostty $verStr (unofficial Windows port)"
    $chk = '; if ($LASTEXITCODE -ne 0) { throw ''failed'' }'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Run in PowerShell from the repo root, one line at a time. Stop at the first failing line.')
    if ($Rehearsal) { $lines.Add('# REHEARSAL - do not run: every command below is commented out (rehearsal build, N = 0)') }
    $lines.Add($pre + "if (git ls-remote --tags origin $(Quote-Ps "refs/tags/$tag")) { throw 'the tag is already on origin' }")
    $lines.Add($pre + "git tag -a $t $(Quote-Ps $sha) -m $(Quote-Ps "Ghostty $verStr")$chk")
    $lines.Add($pre + "git push origin $t$chk")
    $lines.Add('# the release below is created only after the push above succeeded')
    $lines.Add($pre + "gh release create $t --repo $ghRepo --prerelease --draft --verify-tag --title $(Quote-Ps $title) --notes-file $(Quote-Ps $notes) $($files -join ' ')$chk")
    $lines.Add('# after checking the draft page')
    $lines.Add($pre + "gh release edit $t --repo $ghRepo --draft=false")
    return $lines.ToArray()
}

function Get-PackageArgs([string]$arch, [string]$prefix, [bool]$noPdb) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'package.ps1'),
        '-Prefix', $prefix, '-Version', $verStr, '-Arch', $arch, '-OutDir', $OutDir, '-Installer', '-Symbols')
    if ($noPdb) { $a += '-NoPdbOk' }
    if ($SignCommand) { $a += @('-SignCommand', $SignCommand) }
    return $a
}

# The run takes hours: HEAD and the tree must still be what the preflight saw.
function Assert-TreeUnchanged {
    if ($Rehearsal) { return }
    $h = Invoke-Logged -Exe 'git' -ArgList @('-C', $repo, 'rev-parse', 'HEAD') -TimeoutSec 30 -Quiet
    if ($h.Code -ne 0 -or $h.Text -notmatch [regex]::Escape($sha)) { throw "HEAD moved since the preflight (was $sha)" }
    $s = Invoke-Logged -Exe 'git' -ArgList @('-C', $repo, 'status', '--porcelain') -TimeoutSec 60 -Quiet
    $dirt = @(($s.Text -split "`r?`n") | Where-Object { $_ -and $_ -notlike '> *' -and $_ -notlike '[[]exit*' })
    if ($s.Code -ne 0 -or $dirt.Count -gt 0) { throw 'the working tree changed since the preflight (it must stay clean)' }
}

function Show-PackageCommand([string]$arch, [string]$prefix) {
    $a = Get-PackageArgs $arch $prefix $false
    if ($SignCommand) {
        for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -eq '-SignCommand') { $a[$i + 1] = '<sign command hidden>' } }
    }
    Write-Host ('  $ ' + (Format-Cmd 'powershell.exe' $a))
}

# ---- run --------------------------------------------------------------------

if ($SelfTest) { if (Invoke-ReleaseSelfTest) { exit 0 } else { exit 1 } }
$failed = $false
try {
    if ($SkipTests -and -not $Rehearsal) { throw '-SkipTests is only allowed with -Rehearsal (a release always runs the unit tests)' }
    if ($N -eq '') { throw '-N must not be empty' }
    if ($MinFreeGB -lt 3) { throw '-MinFreeGB must be at least 3 (the RAM gate has a 3 GB floor)' }

    Start-Step 1
    Invoke-Preflight

    if ($DryRun) {
        Write-Host "  (dry run: nothing below is executed; OutDir would be $OutDir)"
    } else {
        if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
        $null = New-Item -ItemType Directory -Force -Path $OutDir
        $final = Join-Path $OutDir 'release.log'
        Copy-Item -LiteralPath $script:LogPath -Destination $final
        Remove-Item -LiteralPath $script:LogPath -Force
        $script:LogPath = $final
        # Move the verified ConPTY files next to the outputs.
        $dst = Join-Path $OutDir 'conpty'
        Move-Item -LiteralPath $conpty.Work -Destination $dst
        $script:TempDirs.Remove($conpty.Work) | Out-Null
        $conpty.Work = $dst
    }
    $conptyBase = if ($DryRun) { Join-Path $OutDir 'conpty' } else { $conpty.Work }
    $null = New-Item -ItemType Directory -Force -Path $globalCache -ErrorAction SilentlyContinue
    $env:ZIG_GLOBAL_CACHE_DIR = $globalCache
    Write-Host "  ZIG_GLOBAL_CACHE_DIR=$globalCache"
    Write-Log "ZIG_GLOBAL_CACHE_DIR=$globalCache"
    Set-Location $repo

    $prefX64 = Join-Path $OutDir 'prefix-x64'
    $prefArm = Join-Path $OutDir 'prefix-arm64'
    $prefArmTests = Join-Path $OutDir 'prefix-arm64-tests'
    $armTarget = "aarch64-windows-$Arm64Abi"
    $testRecords = New-Object System.Collections.Generic.List[object]

    # ---- step 2: unit tests ------------------------------------------------
    Start-Step 2
    $groups = @(
        @{ Id = 'group1'; Label = 'win32'; Step = 'test'; Filters = $testFiltersG1 },
        @{ Id = 'group2'; Label = 'windows, tmux shim, Exec, d3d11'; Step = 'test'; Filters = $testFiltersG2 },
        @{ Id = 'group3'; Label = 'terminal, config, input, font'; Step = 'test'; Filters = $testFiltersG3 },
        @{ Id = 'tmux-shim'; Label = 'tmux.exe shim'; Step = 'test-tmux-shim'; Filters = @() },
        @{ Id = 'explorer-command'; Label = 'ghostty-explorer.dll'; Step = 'test-explorer-command'; Filters = @() }
    )
    if ($SkipTests) {
        Write-Host '  unit tests skipped (-SkipTests, rehearsal)'
        if (-not $DryRun) { [IO.File]::WriteAllText((Join-Path $OutDir 'tests.txt'), "tests: skipped (-SkipTests, rehearsal)`r`n") }
    } else {
        foreach ($g in $groups) {
            $za = @('build', $g.Step, "-j$Jobs", '--summary', 'all') + $g.Filters
            if ($DryRun) { Show-ZigCommand $za 1500; continue }
            Write-Host "  $($g.Id): $($g.Label)"
            $r = Invoke-Zig "tests $($g.Id)" $za 1500
            if ($r.Code -ne 0) { throw "unit tests $($g.Id) ($($g.Label)) failed (exit $($r.Code)); see release.log" }
            $c = Get-TestCounts $r.FullText
            if ($c -and $c.Fail -gt 0) { throw "unit tests $($g.Id): $($c.Fail) failed" }
            # A cached run step adds nothing to the summary: the whole group (no
            # counts) or a part of it (a smaller total) was cached. The counts of
            # an earlier fresh run at this sha are used instead.
            $cachedHint = Test-CachedRun $r.FullText
            $rec = Get-RecordedCounts $sha $g.Id
            if ($c -and -not $cachedHint) {
                Set-RecordedCounts $sha $g.Id $c
            } elseif ($rec -and (-not $c -or $rec.Total -ge $c.Total)) {
                Write-Host "  $($g.Id): cached run; using the counts recorded for this commit"
                Write-Log "$($g.Id): cached, recorded counts used"
                $c = $rec
            } elseif ($Rehearsal) {
                Write-Host "  WARNING: $($g.Id): cached run with no recorded counts (rehearsal: the notes will say so)"
                $c = $null
            } else {
                throw "unit tests $($g.Id) ran from the zig cache and no counts are recorded for commit $sha; delete .zig-cache and re-run, or run the group once with fresh output"
            }
            if ($null -eq $c) {
                $testRecords.Add(@{ Id = $g.Id; Label = $g.Label; Line = 'passed (cached run, counts not available)' })
            } else {
                $line = '{0}/{1} passed, {2} skipped, {3} failed' -f $c.Pass, $c.Total, $c.Skip, $c.Fail
                Write-Host "  $($g.Id): $line"
                $testRecords.Add(@{ Id = $g.Id; Label = $g.Label; Line = $line })
            }
        }
        if (-not $DryRun) {
            $tl = $testRecords | ForEach-Object { '{0}: {1}' -f $_.Id, $_.Line }
            [IO.File]::WriteAllText((Join-Path $OutDir 'tests.txt'), (($tl -join "`r`n") + "`r`n"))
        }
    }

    # ---- step 3: build x64 --------------------------------------------------
    Start-Step 3
    $ba = Get-BuildArgs 'x86_64-windows-msvc' $prefX64 $conptyBase
    if ($DryRun) { Show-ZigCommand $ba 3000 } else {
        $r = Invoke-Zig 'build x64' $ba 3000
        if ($r.Code -ne 0) { throw "x64 build failed (exit $($r.Code)); see release.log" }
        foreach ($f in 'ghostty.exe', 'tmux.exe', 'ghostty-explorer.dll', 'conpty.dll', 'OpenConsole.exe') {
            if (-not (Test-Path -LiteralPath (Join-Path $prefX64 "bin\$f"))) { throw "x64 prefix lacks bin\$f" }
        }
    }

    # ---- step 4: build arm64 ------------------------------------------------
    Start-Step 4
    $ba = Get-BuildArgs $armTarget $prefArm $conptyBase
    $noPdb = $false
    if ($DryRun) { Show-ZigCommand $ba 3000 } else {
        $r = Invoke-Zig 'build arm64' $ba 3000
        if ($r.Code -ne 0) { throw "arm64 build failed (exit $($r.Code)); see release.log" }
        foreach ($f in 'ghostty.exe', 'tmux.exe', 'ghostty-explorer.dll', 'conpty.dll', 'OpenConsole.exe') {
            if (-not (Test-Path -LiteralPath (Join-Path $prefArm "bin\$f"))) { throw "arm64 prefix lacks bin\$f" }
        }
        $pdbG = Test-Path -LiteralPath (Join-Path $prefArm 'bin\ghostty.pdb')
        $pdbT = Test-Path -LiteralPath (Join-Path $prefArm 'bin\tmux.pdb')
        if ($pdbG -ne $pdbT) { throw 'the arm64 build gave only one of ghostty.pdb and tmux.pdb' }
        if (-not $pdbG) {
            $noPdb = $true
            Write-Host '  arm64 build gave no PDB: -NoPdbOk (the arm64 symbols zip is left out)'
            Write-Log 'arm64 build gave no PDB: -NoPdbOk'
        }
    }
    $armTestZip = "ghostty-$verStr-windows-arm64-tests.zip"
    if ($Arm64TestExe) {
        $ta = @('build', 'test', "-j$Jobs", '-Demit-test-exe', "-Dtarget=$armTarget") + $testFiltersG1 + $testFiltersG2 + @('--prefix', $prefArmTests)
        if ($DryRun) {
            Show-ZigCommand $ta 3000
            Write-Host "  zip $prefArmTests\bin -> $(Join-Path $OutDir $armTestZip) (local only, not in SHA256SUMS.txt or publish.txt)"
        } else {
            $r = Invoke-Zig 'arm64 test exe' $ta 3000
            if ($r.Code -ne 0) { throw "arm64 test exe build failed (exit $($r.Code)); see release.log" }
            $tbin = Join-Path $prefArmTests 'bin'
            $files = @(Get-ChildItem -LiteralPath $tbin -File -ErrorAction SilentlyContinue)
            if (-not ($files | Where-Object { $_.Extension -eq '.exe' })) { throw "no test exe was installed in $tbin" }
            $zp = Join-Path $OutDir $armTestZip
            $top = "ghostty-$verStr-windows-arm64-tests"
            $za = [IO.Compression.ZipFile]::Open($zp, [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($f in $files) {
                    $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, $f.FullName, "$top/$($f.Name)", [IO.Compression.CompressionLevel]::Optimal)
                }
                $e = $za.CreateEntry("$top/RUN-ME.txt")
                $w = New-Object IO.StreamWriter($e.Open())
                try { $w.Write("Run the .exe on an ARM64 Windows device from a terminal.`r`nExit code 0 = PASS. A failure is an owner check result, not a release blocker.`r`n") } finally { $w.Dispose() }
            } finally { $za.Dispose() }
            Write-Host "  arm64 test exe: $zp (local only)"
        }
    }

    # ---- step 5: package ----------------------------------------------------
    Start-Step 5
    if (-not $DryRun) { Assert-TreeUnchanged }
    if ($DryRun) {
        Show-PackageCommand 'x64' $prefX64
        Show-PackageCommand 'arm64' $prefArm
    } else {
        foreach ($pair in @(@('x64', $prefX64, $false), @('arm64', $prefArm, $noPdb))) {
            $pa = Get-PackageArgs $pair[0] $pair[1] $pair[2]
            if ($SignCommand) {
                $r = Invoke-Logged -Exe 'powershell.exe' -ArgList $pa -TimeoutSec 1800 -Quiet -HideCmdLine
                foreach ($l in ($r.Text -split "`r?`n")) { if ($l -match '^(artifact:|package:)') { Write-Host "  $l" } }
            } else {
                $r = Invoke-Logged -Exe 'powershell.exe' -ArgList $pa -TimeoutSec 1800
            }
            if ($r.Code -eq 2) { throw 'package: ISCC.exe not found (installer step); install Inno Setup 6 or set ISCC' }
            if ($r.Code -ne 0) { throw "package.ps1 -Arch $($pair[0]) failed (exit $($r.Code)); see release.log and package.log" }
        }
        $want = @(Get-ArtifactNames)
        if ($noPdb) { $want = @($want | Where-Object { $_ -notlike '*arm64-symbols.zip' }) }
        foreach ($n in $want) {
            if (-not (Test-Path -LiteralPath (Join-Path $OutDir $n))) { throw "package did not produce $n" }
        }
    }

    # ---- step 6: check the built exe ---------------------------------------
    Start-Step 6
    $exe = Join-Path $prefX64 'bin\ghostty.exe'
    if ($DryRun) { Write-Host ('  $ ' + (Format-Cmd $exe @('+version')) + "   (must print $verStr)") } else {
        $r = Invoke-Logged -Exe $exe -ArgList @('+version') -TimeoutSec 60
        if ($r.Code -ne 0 -or $r.Text -notmatch [regex]::Escape($verStr)) { throw "ghostty.exe +version did not print $verStr (exit $($r.Code))" }
    }

    # ---- step 7: sums -------------------------------------------------------
    Start-Step 7
    $sumsPath = Join-Path $OutDir 'SHA256SUMS.txt'
    if ($DryRun) { Write-Host "  SHA256SUMS.txt (lower-case hex, two spaces, file name) for the artifacts in $OutDir" } else {
        $want = @(Get-ArtifactNames)
        if ($noPdb) { $want = @($want | Where-Object { $_ -notlike '*arm64-symbols.zip' }) }
        $sb = New-Object System.Text.StringBuilder
        foreach ($n in $want) {
            $h = (Get-FileHash -LiteralPath (Join-Path $OutDir $n) -Algorithm SHA256).Hash.ToLowerInvariant()
            [void]$sb.Append("$h  $n`n")
        }
        $tmpSums = $sumsPath + '.tmp'
        [IO.File]::WriteAllText($tmpSums, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmpSums -Destination $sumsPath -Force
        Write-Log ("SHA256SUMS.txt:`r`n" + $sb.ToString())
    }

    # ---- step 8: notes ------------------------------------------------------
    Start-Step 8
    $notesPath = Join-Path $OutDir 'release-notes.md'
    if ($DryRun) { Write-Host "  release-notes.md from dist\windows\release-notes.md, then a privacy scan of it and SHA256SUMS.txt" } else {
        $tpl = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'release-notes.md'))
        # Not `$v1`: PowerShell names are case-insensitive, and the [switch]$V1
        # parameter refuses a string.
        $v1Line = if ($V1) { 'Windows port v1.0' } else { '' }
        if ($SkipTests) {
            $testsText = 'Unit tests were skipped in this build (rehearsal).'
        } else {
            $testsText = (($testRecords | ForEach-Object { '- {0}: {1}' -f $_.Label, $_.Line }) -join "`n")
        }
        $armLine = "ARM64: built (``$armTarget``); unit tests are an owner check."
        if ($Arm64Result) { $armLine += " Owner result: $Arm64Result" }
        if ($noPdb) { $armLine += ' -NoPdbOk: this ABI gave no PDB, so there is no arm64 symbols zip.' }
        $cp = New-Object System.Text.StringBuilder
        [void]$cp.Append("Microsoft.Windows.Console.ConPTY $($conpty.Version) (MIT, signed by Microsoft). SHA-256:`n`n")
        foreach ($h in $conpty.Hashes) { [void]$cp.Append("- ``$h```n") }
        $notes = $tpl.Replace('{{VERSION}}', $verStr).Replace('{{TAG}}', $tag).Replace('{{V1_LINE}}', $v1Line).Replace('{{TESTS}}', $testsText).Replace('{{ARM64_LINE}}', $armLine).Replace('{{CONPTY}}', $cp.ToString().TrimEnd()).Replace('{{SHA256SUMS}}', ([IO.File]::ReadAllText($sumsPath).TrimEnd()))
        if ($notes -match '\{\{[A-Z0-9_]+\}\}') { throw "release-notes.md still has a placeholder: $($Matches[0])" }
        [IO.File]::WriteAllText($notesPath, $notes, (New-Object Text.UTF8Encoding($false)))
        foreach ($f in @($notesPath, $sumsPath)) {
            $hit = Test-Privacy -Path $f
            if ($hit) { throw "privacy scan: $(Split-Path -Leaf $f) contains the user name or profile path at $hit" }
        }
        Write-Host '  release-notes.md written; privacy scan clean'
    }

    # ---- step 9: publish commands ------------------------------------------
    Start-Step 9
    if (-not $DryRun) { Assert-TreeUnchanged }
    $pl = Get-PublishLines ([bool]($noPdb -and -not $DryRun))
    foreach ($l in $pl) { Write-Host $l }
    if (-not $DryRun) {
        [IO.File]::WriteAllText((Join-Path $OutDir 'publish.txt'), (($pl -join "`r`n") + "`r`n"))
        foreach ($d in $prefX64, $prefArm, $prefArmTests) {
            if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
        }
        Write-Host ''
        Write-Host "release: DONE. Artifacts, release-notes.md and publish.txt are in $OutDir"
        Write-Host 'release: nothing was tagged, pushed or published; run publish.txt yourself (RELEASING.md).'
    } else {
        Write-Host ''
        Write-Host 'release: DRY RUN done (preflight passed; no step was executed).'
    }
} catch {
    $failed = $true
    $stepName = if ($script:CurStep -ge 1) { $stepNames[$script:CurStep - 1] } else { 'start' }
    Write-Host ("release: FAIL step {0}/{1} ({2}): {3}" -f $script:CurStep, $total, $stepName, $_.Exception.Message)
    try { Write-Log ("FAIL step {0} ({1}): {2}" -f $script:CurStep, $stepName, $_.Exception.Message) } catch {}
} finally {
    foreach ($d in $script:TempDirs) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    if (($DryRun -or $script:LogPath.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) -and (Test-Path -LiteralPath $script:LogPath)) { Remove-Item -LiteralPath $script:LogPath -Force -ErrorAction SilentlyContinue }
}
if ($failed) { exit 1 }
exit 0
