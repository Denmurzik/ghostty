# Stages, verifies, privacy-scans and zips one portable Ghostty for Windows
# build (Windows PowerShell 5.1). ASCII only.
#
#   package.ps1 (-Prefix <dir with bin\ and share\> | -FromZip <zip>)
#               -Version <v> -Arch x64|arm64 -OutDir <dir>
#               [-Installer] [-Test] [-Symbols] [-NoPdbOk]
#               [-SignCommand '<cmd with {file}>'] [-AllowNoTic] [-NoConpty]
#
# Every failed check prints "package: FAIL <check>" and exits 1. Exit 2 is
# installer\build.ps1's "no ISCC", passed through.
[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName = 'Prefix')][string]$Prefix,
    [Parameter(Mandatory, ParameterSetName = 'Zip')][string]$FromZip,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Arch,
    [Parameter(Mandatory)][string]$OutDir,
    [switch]$Installer,
    [switch]$Test,
    [switch]$Symbols,
    [switch]$NoPdbOk,
    [string]$SignCommand = '',
    [switch]$AllowNoTic,
    [switch]$NoConpty,
    # Local runs only (release.ps1 never passes it): skip the VERSIONINFO and
    # imports checks, for an exe that does not meet them yet.
    [switch]$Local
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\Native.psm1') -Force -DisableNameChecking
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
[AppContext]::SetSwitch('Switch.System.IO.Compression.ZipFile.UseBackslash', $false)

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Fail([string]$check) {
    Write-Host "package: FAIL $check"
    exit 1
}

# Fixed entry time (1980-01-01, the zip epoch) so equal inputs give equal zips.
function Add-ZipFile($archive, [string]$path, [string]$name) {
    $e = $archive.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
    $e.LastWriteTime = [DateTimeOffset]'1980-01-01T00:00:00+00:00'
    $in = [IO.File]::OpenRead($path)
    try {
        $out = $e.Open()
        try { $in.CopyTo($out) } finally { $out.Dispose() }
    } finally { $in.Dispose() }
}

function Get-Rel([string]$root, [string]$path) {
    return $path.Substring($root.Length).TrimStart('\', '/')
}

try {
    # ---- parameters ------------------------------------------------------
    if ($Local) { Write-Host 'package: LOCAL BUILD (not for release): VERSIONINFO and imports checks skipped' }
    if ($Version -notmatch '^[^+\s\\/:]+-win\.(0|[1-9][0-9]*)$') {
        Fail "version '$Version' (must end in -win.<N>, N canonical, no +)"
    }
    $verN = [string]$Matches[1]
    if ($Symbols -and $PSCmdlet.ParameterSetName -eq 'Zip') { Fail '-Symbols needs -Prefix' }

    $null = New-Item -ItemType Directory -Force -Path $OutDir
    $OutDir = (Resolve-Path -LiteralPath $OutDir).Path
    $log = Join-Path $OutDir 'package.log'
    $top = "ghostty-$Version-windows-$Arch"
    $stageRoot = Join-Path $OutDir 'stage'
    $stage = Join-Path $stageRoot $top
    $zipPath = Join-Path $OutDir "$top.zip"
    $symPath = Join-Path $OutDir "$top-symbols.zip"
    $setupPath = Join-Path $OutDir ($top + '-setup' + $(if ($Test) { '-test' } else { '' }) + '.exe')
    $artifacts = New-Object System.Collections.Generic.List[string]

    # ---- 1. stage --------------------------------------------------------
    if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $stage

    if ($PSCmdlet.ParameterSetName -eq 'Prefix') {
        if (-not (Test-Path -LiteralPath $Prefix -PathType Container)) { Fail "-Prefix $Prefix (no such folder)" }
        $Prefix = (Resolve-Path -LiteralPath $Prefix).Path
        $bin = Join-Path $Prefix 'bin'
        $binFiles = @('ghostty.exe', 'tmux.exe')
        if (-not $NoConpty) { $binFiles += @('conpty.dll', 'OpenConsole.exe') }
        foreach ($f in $binFiles) {
            $src = Join-Path $bin $f
            if (Test-Path -LiteralPath $src -PathType Leaf) { Copy-Item -LiteralPath $src -Destination (Join-Path $stage $f) }
        }
        $shareSrc = Join-Path $Prefix 'share'
        $shareDst = Join-Path $stage 'share'
        $null = New-Item -ItemType Directory -Force -Path $shareDst
        foreach ($n in 'ghostty', 'terminfo', 'bash-completion', 'fish', 'zsh', 'vim', 'nvim', 'bat', 'man') {
            $src = Join-Path $shareSrc $n
            if (Test-Path -LiteralPath $src -PathType Container) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $shareDst $n) -Recurse
            }
        }
        foreach ($pair in @(@((Join-Path $repoRoot 'LICENSE'), 'LICENSE'),
                            @((Join-Path $PSScriptRoot 'README-windows.txt'), 'README-windows.txt'),
                            @((Join-Path $PSScriptRoot 'THIRD_PARTY_NOTICES.txt'), 'THIRD_PARTY_NOTICES.txt'))) {
            if (Test-Path -LiteralPath $pair[0] -PathType Leaf) {
                Copy-Item -LiteralPath $pair[0] -Destination (Join-Path $stage $pair[1])
            }
        }
    } else {
        if (-not (Test-Path -LiteralPath $FromZip -PathType Leaf)) { Fail "-FromZip $FromZip (no such file)" }
        $FromZip = (Resolve-Path -LiteralPath $FromZip).Path
        $tmpX = Join-Path $stageRoot '_x'
        $null = New-Item -ItemType Directory -Force -Path $tmpX
        $tmpXFull = [IO.Path]::GetFullPath($tmpX).TrimEnd('\') + '\'
        $zin = [IO.Compression.ZipFile]::OpenRead($FromZip)
        try {
            foreach ($e in $zin.Entries) {
                if ($e.FullName.EndsWith('/') -or $e.FullName.EndsWith('\')) { continue }
                $dest = [IO.Path]::GetFullPath((Join-Path $tmpX ($e.FullName.Replace('/', '\'))))
                if (-not $dest.StartsWith($tmpXFull, [StringComparison]::OrdinalIgnoreCase)) {
                    Fail "zip entry escapes the folder: $($e.FullName)"
                }
                $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest)
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
            }
        } finally { $zin.Dispose() }
        $kids = @(Get-ChildItem -LiteralPath $tmpX)
        if ($kids.Count -ne 1 -or -not $kids[0].PSIsContainer) { Fail 'zip layout (need exactly one top folder)' }
        if ($kids[0].Name -cne $top) { Fail "zip top folder '$($kids[0].Name)' <> '$top'" }
        Remove-Item -LiteralPath $stage -Recurse -Force
        Move-Item -LiteralPath $kids[0].FullName -Destination $stage
        Remove-Item -LiteralPath $tmpX -Recurse -Force
    }

    # ---- 2. verify -------------------------------------------------------
    function Require-File([string]$rel) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage $rel) -PathType Leaf)) {
            Write-Host "package: required file is missing: $rel"
            Fail $rel
        }
    }
    function Require-Dir([string]$rel, [switch]$NonEmpty) {
        $p = Join-Path $stage $rel
        if (-not (Test-Path -LiteralPath $p -PathType Container)) {
            Write-Host "package: required folder is missing: $rel"
            Fail $rel
        }
        if ($NonEmpty -and @(Get-ChildItem -LiteralPath $p -Force).Count -eq 0) {
            Write-Host "package: required folder is empty: $rel"
            Fail $rel
        }
    }

    Require-File 'ghostty.exe'
    Require-File 'tmux.exe'
    Require-File 'LICENSE'
    Require-File 'README-windows.txt'
    Require-File 'THIRD_PARTY_NOTICES.txt'
    if (-not $NoConpty) {
        Require-File 'conpty.dll'
        Require-File 'OpenConsole.exe'
    }
    Require-Dir 'share\ghostty\themes' -NonEmpty
    Require-Dir 'share\ghostty\shell-integration'
    Require-File 'share\terminfo\ghostty.terminfo'
    if (-not $AllowNoTic) { Require-File 'share\terminfo\78\xterm-ghostty' }

    $pdbs = @(Get-ChildItem -LiteralPath $stage -Recurse -File -Filter '*.pdb')
    if ($pdbs.Count -gt 0) { Fail ('pdb in the stage: ' + (Get-Rel $stage $pdbs[0].FullName)) }

    # VersionInfo of both exes (R-M6-2).
    if (-not $Local) {
        $wantName = 'Ghostty ' + [char]0x2014 + ' Unofficial Windows port'
        foreach ($exe in 'ghostty.exe', 'tmux.exe') {
            $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $stage $exe))
            if ($vi.ProductVersion -ne $Version) { Fail "$exe ProductVersion '$($vi.ProductVersion)' <> '$Version'" }
            if ([string]$vi.FilePrivatePart -ne $verN) { Fail "$exe FilePrivatePart $($vi.FilePrivatePart) <> $verN" }
            if ($vi.ProductName -ne $wantName) { Fail "$exe ProductName '$($vi.ProductName)'" }
        }
    } else {
        Write-Host 'package: SKIP versioninfo (-Local)'
    }

    # The bundled ConPTY: pinned hashes (vendor/conpty/README.md) and a
    # Microsoft Authenticode signature (R-M6-12).
    if (-not $NoConpty) {
        $readme = Join-Path $repoRoot 'vendor\conpty\README.md'
        if (-not (Test-Path -LiteralPath $readme)) { Fail 'vendor\conpty\README.md (pinned hashes)' }
        $pinned = @{}
        foreach ($m in [regex]::Matches((Get-Content -Raw -LiteralPath $readme),
                '\|\s*`(x64|arm64)/(conpty\.dll|OpenConsole\.exe)`\s*\|[^|]*\|\s*`([0-9a-f]{64})`\s*\|')) {
            $pinned[$m.Groups[1].Value + '/' + $m.Groups[2].Value] = $m.Groups[3].Value
        }
        foreach ($f in 'conpty.dll', 'OpenConsole.exe') {
            $key = "$Arch/$f"
            if (-not $pinned.ContainsKey($key)) { Fail "no pinned hash for $key in vendor\conpty\README.md" }
            $path = Join-Path $stage $f
            $h = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($h -ne $pinned[$key]) { Fail "$f sha256 $h <> pinned $($pinned[$key])" }
            $sig = Get-AuthenticodeSignature -LiteralPath $path
            if ($sig.Status -ne 'Valid') { Fail "$f signature is $($sig.Status)" }
            if ($sig.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') {
                Fail "$f signer is not Microsoft: $($sig.SignerCertificate.Subject)"
            }
            Write-Host "package: $f sha256 $h (Microsoft, Valid)"
        }
    }

    # Imports (M4, M5).
    $dumpbin = $null
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $inst = @(& $vswhere -latest -products '*' -property installationPath 2>$null)
        $ErrorActionPreference = $saved
        if ($inst.Count -gt 0 -and $inst[0] -and (Test-Path -LiteralPath (Join-Path $inst[0] 'VC\Tools\MSVC'))) {
            $cands = @(Get-ChildItem -LiteralPath (Join-Path $inst[0] 'VC\Tools\MSVC') -Recurse -Filter 'dumpbin.exe' -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending)
            $pick = $cands | Where-Object { $_.FullName -match '\\Hostx64\\x64\\' } | Select-Object -First 1
            if (-not $pick) { $pick = $cands | Select-Object -First 1 }
            if ($pick) { $dumpbin = $pick.FullName }
        }
    }
    if ($Local) {
        Write-Host 'package: SKIP imports (-Local)'
    } elseif (-not $dumpbin) {
        Write-Host 'package: SKIP imports (no dumpbin)'
    } else {
        function Get-Imports([string]$exePath) {
            $tmpLog = Join-Path $OutDir 'dumpbin.tmp.log'
            Remove-Item -LiteralPath $tmpLog -Force -ErrorAction SilentlyContinue
            $rc = Invoke-Native -Exe $dumpbin -Args @('/nologo', '/imports', $exePath) -Log $tmpLog -Quiet
            if ($rc -ne 0) { Fail "dumpbin /imports failed (exit $rc) for $exePath" }
            $names = @{}
            foreach ($l in (Get-Content -LiteralPath $tmpLog)) {
                if ($l -match '^\s{4}(\S+\.dll)\s*$') { $names[$Matches[1].ToLowerInvariant()] = $true }
            }
            Remove-Item -LiteralPath $tmpLog -Force -ErrorAction SilentlyContinue
            return @($names.Keys)
        }
        $gi = Get-Imports (Join-Path $stage 'ghostty.exe')
        foreach ($bad in 'winhttp.dll', 'dbghelp.dll') {
            if ($gi -contains $bad) { Fail "imports: ghostty.exe imports $bad" }
        }
        $ti = Get-Imports (Join-Path $stage 'tmux.exe')
        foreach ($d in $ti) {
            # advapi32 since M5 Task 17 (owner-SID check on the external pipe).
            if ($d -notin @('kernel32.dll', 'ntdll.dll', 'advapi32.dll')) { Fail "imports: tmux.exe imports $d" }
        }
    }

    # Installer constants must equal the app's.
    if ($Installer) {
        $iss = Join-Path $PSScriptRoot 'installer\ghostty.iss'
        if (-not (Test-Path -LiteralPath $iss)) { Fail 'installer\ghostty.iss' }
        $issText = Get-Content -Raw -LiteralPath $iss
        $zigAum = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'src\os\windows_explorer.zig')
        $m = [regex]::Match($zigAum, '(?s)pub const aumid = if \(builtin\.mode == \.debug\)\s*"[^"]+"\s*else\s*"([^"]+)";')
        if (-not $m.Success) { Fail 'aumid literal not found in src\os\windows_explorer.zig' }
        $aumid = $m.Groups[1].Value
        $m = [regex]::Match($issText, '#define\s+AppAumid\s+"([^"]+)"')
        if (-not $m.Success) { Fail 'AppAumid define not found in installer\ghostty.iss' }
        $uses = [regex]::Matches($issText, 'AppUserModelID:\s*"([^"]*)"')
        if ($uses.Count -eq 0) { Fail 'installer\ghostty.iss has no AppUserModelID in [Icons]' }
        foreach ($u in $uses) {
            if ($u.Groups[1].Value -ne '{#AppAumid}') { Fail "installer [Icons] AppUserModelID is not {#AppAumid}: '$($u.Groups[1].Value)'" }
        }
        if ($m.Groups[1].Value -ne $aumid) { Fail "installer AUMID '$($m.Groups[1].Value)' <> app '$aumid'" }
        $zigTray = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'src\apprt\win32\tray.zig')
        $m = [regex]::Match($zigTray, 'const class_name = std\.unicode\.utf8ToUtf16LeStringLiteral\("([^"]+)"\)')
        if (-not $m.Success) { Fail 'class_name literal not found in src\apprt\win32\tray.zig' }
        $trayClass = $m.Groups[1].Value
        $m = [regex]::Match($issText, '#define\s+TrayClass\s+"([^"]+)"')
        if (-not $m.Success) { Fail 'TrayClass not found in installer\ghostty.iss' }
        if ($m.Groups[1].Value -ne $trayClass) { Fail "installer TrayClass '$($m.Groups[1].Value)' <> app '$trayClass'" }
    }

    # Third-party notices cover every dependency and this arch's toolchain (R-M6-10).
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $tpc = @(& $ps51 -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'third-party-check.ps1') `
            -RepoRoot $repoRoot -Arch $Arch -Notices (Join-Path $stage 'THIRD_PARTY_NOTICES.txt') 2>&1)
    $tpcRc = $LASTEXITCODE
    $ErrorActionPreference = $saved
    foreach ($l in $tpc) { Write-Host ([string]$l) }
    if ($tpcRc -ne 0) { Fail "third-party-check (exit $tpcRc)" }

    # ---- 3. privacy ------------------------------------------------------
    function Assert-Private([string]$path, [string]$label) {
        $hit = Test-Privacy -Path $path
        if ($null -ne $hit) {
            $at = $hit -replace '^(\d+): ', '@$1: '
            Fail "privacy $label $at"
        }
    }
    $files = @(Get-ChildItem -LiteralPath $stage -Recurse -File)
    foreach ($f in $files) { Assert-Private $f.FullName (Get-Rel $stage $f.FullName) }
    Write-Host "package: privacy ok ($($files.Count) staged files)"

    # ---- 4. sign ---------------------------------------------------------
    if ($SignCommand) {
        $cmd = Get-Command cmd.exe
        foreach ($exe in 'ghostty.exe', 'tmux.exe') {
            $line = $SignCommand.Replace('{file}', '"' + (Join-Path $stage $exe) + '"')
            $rc = Invoke-Native -Exe $cmd.Source -CmdLine ('/d /s /c "' + $line + '"') -Log $log -HideCmdLine
            if ($rc -ne 0) { Fail "sign $exe (exit $rc)" }
        }
    }

    # ---- 5. zip ----------------------------------------------------------
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    $zout = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $items = @(Get-ChildItem -LiteralPath $stage -Recurse -File | ForEach-Object {
                @{ Name = ($top + '/' + (Get-Rel $stage $_.FullName).Replace('\', '/')); Path = $_.FullName } })
        $names = [string[]]@($items | ForEach-Object { $_.Name })
        $paths = [string[]]@($items | ForEach-Object { $_.Path })
        [Array]::Sort($names, $paths, [StringComparer]::Ordinal)
        for ($i = 0; $i -lt $names.Length; $i++) { Add-ZipFile $zout $paths[$i] $names[$i] }
    } finally { $zout.Dispose() }
    $zchk = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $n = 0
        foreach ($e in $zchk.Entries) {
            $n++
            if ($e.FullName.Contains('\')) { Fail "zip entry has a backslash: $($e.FullName)" }
            if (-not $e.FullName.StartsWith($top + '/')) { Fail "zip entry outside $top/: $($e.FullName)" }
        }
        if ($n -eq 0) { Fail 'zip is empty' }
    } finally { $zchk.Dispose() }
    $artifacts.Add($zipPath)

    # ---- 6. symbols ------------------------------------------------------
    if ($Symbols) {
        $have = New-Object System.Collections.Generic.List[string]
        foreach ($p in 'ghostty.pdb', 'tmux.pdb') {
            $src = Join-Path $Prefix "bin\$p"
            if (Test-Path -LiteralPath $src -PathType Leaf) { $have.Add($src) }
            elseif (-not $NoPdbOk) { Fail "symbols: bin\$p is missing" }
        }
        if ($have.Count -eq 0) {
            Write-Host 'package: SKIP symbols'
        } else {
            foreach ($src in $have) { Assert-Private $src ('symbols ' + (Split-Path -Leaf $src)) }
            if (Test-Path -LiteralPath $symPath) { Remove-Item -LiteralPath $symPath -Force }
            $sout = [IO.Compression.ZipFile]::Open($symPath, [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($src in $have) {
                    Add-ZipFile $sout $src (Split-Path -Leaf $src)
                }
            } finally { $sout.Dispose() }
            $artifacts.Add($symPath)
        }
    }

    # ---- 7. installer ----------------------------------------------------
    if ($Installer) {
        $build = Join-Path $PSScriptRoot 'installer\build.ps1'
        if (-not (Test-Path -LiteralPath $build)) { Fail 'installer\build.ps1' }
        $ia = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $build, '-Stage', $stage,
                '-Version', $Version, '-Arch', $Arch, '-OutDir', $OutDir)
        if ($Test) { $ia += '-Test' }
        if ($SignCommand) { $ia += @('-SignCommand', $SignCommand) }
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $rc = Invoke-Native -Exe $ps -Args $ia -Log $log -HideCmdLine:([bool]$SignCommand)
        if ($rc -eq 2) {
            foreach ($a in $artifacts) { Write-Host "artifact: $a" }
            Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host 'package: installer skipped (no ISCC, exit 2)'
            exit 2
        }
        if ($rc -ne 0) { Fail "installer build (exit $rc)" }
        if (-not (Test-Path -LiteralPath $setupPath)) { Fail "installer output missing: $setupPath" }
        Assert-Private $setupPath (Split-Path -Leaf $setupPath)
        $artifacts.Add($setupPath)
    }

    # ---- 8. done ---------------------------------------------------------
    foreach ($a in $artifacts) { Write-Host "artifact: $a" }
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
    Write-Host $(if ($Local) { 'package: OK (LOCAL, not for release)' } else { 'package: OK' })
    exit 0
} catch {
    Write-Host ('package: FAIL unexpected: ' + $_.Exception.Message)
    Write-Host $_.ScriptStackTrace
    exit 1
}
