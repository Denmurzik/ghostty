# Stages, verifies, privacy-scans and zips one portable Ghostty for Windows
# build (Windows PowerShell 5.1). ASCII only.
#
#   package.ps1 (-Prefix <dir with bin\ and share\> | -FromZip <zip>)
#               -Version <v> -Arch x64|arm64 -OutDir <dir>
#               [-Installer] [-Test] [-Symbols] [-NoPdbOk]
#               [-SignCommand '<cmd with {file}>'] [-AllowNoTic] [-NoConpty]
#
# The stage also carries ghostty-explorer.dll and the unsigned sparse package
# ghostty-explorer.msix (sparse\build-sparse.ps1).
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
        $binFiles = @('ghostty.exe', 'tmux.exe', 'ghostty-explorer.dll')
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
    Require-File 'ghostty-explorer.dll'
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
        foreach ($exe in 'ghostty.exe', 'tmux.exe', 'ghostty-explorer.dll') {
            $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $stage $exe))
            if ($vi.ProductVersion -ne $Version) { Fail "$exe ProductVersion '$($vi.ProductVersion)' <> '$Version'" }
            if ([string]$vi.FilePrivatePart -ne $verN) { Fail "$exe FilePrivatePart $($vi.FilePrivatePart) <> $verN" }
            if ($vi.ProductName -ne $wantName) { Fail "$exe ProductName '$($vi.ProductName)'" }
        }
    } else {
        Write-Host 'package: SKIP versioninfo (-Local)'
    }

    # The sparse package for the Windows 11 Explorer menu (R-M7-13): built into
    # the stage from a prefix (a zip already carries the one that was built),
    # never signed. Either way it is verified: name, CLSIDs, version, arch and
    # publisher against ids.zig and the version, and every entry privacy-scanned.
    $vm = [regex]::Match($Version, '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[^+\s]+)?-win\.(0|[1-9][0-9]*)$')
    if (-not $vm.Success) { Fail "version '$Version' has no X.Y.Z base for the sparse package" }
    $ver4 = '{0}.{1}.{2}.{3}' -f $vm.Groups[1].Value, $vm.Groups[2].Value, $vm.Groups[3].Value, $vm.Groups[5].Value
    if ($PSCmdlet.ParameterSetName -eq 'Prefix') {
        $sparse = Join-Path $PSScriptRoot 'sparse\build-sparse.ps1'
        if (-not (Test-Path -LiteralPath $sparse)) { Fail 'sparse\build-sparse.ps1' }
        $psx = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $rc = Invoke-Native -Exe $psx -Log $log -Args @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $sparse,
            '-Stage', $stage, '-Version', $ver4, '-Arch', $Arch)
        if ($rc -eq 2) { Fail 'makeappx not found' }
        if ($rc -ne 0) { Fail "build-sparse (exit $rc)" }
    }
    Require-File 'ghostty-explorer.msix'
    $ids = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'src\explorer_command\ids.zig')
    $mc = [regex]::Match($ids, 'pub const clsid_text = "(\{[0-9A-Fa-f-]{36}\})";')
    $mn = [regex]::Match($ids, 'pub const package_name = "([^"]+)";')
    if (-not $mc.Success -or -not $mn.Success) { Fail 'clsid_text or package_name not found in src\explorer_command\ids.zig' }
    $oidPublisher = 'CN=Ghostty Windows port (unofficial), OID.2.25.311729368913984317654407730594956997722=1'
    $msixScan = Join-Path $stageRoot '_msix'
    $null = New-Item -ItemType Directory -Force -Path $msixScan
    $manifestText = $null
    $msixZip = [IO.Compression.ZipFile]::OpenRead((Join-Path $stage 'ghostty-explorer.msix'))
    try {
        $k = 0
        foreach ($ent in $msixZip.Entries) {
            if ($ent.FullName.EndsWith('/')) { continue }
            $en = [Uri]::UnescapeDataString($ent.FullName)
            if ($en -notin @('AppxManifest.xml', 'AppxBlockMap.xml', '[Content_Types].xml') -and $en -notmatch '^Assets/[A-Za-z0-9]+\.png$') {
                Fail "ghostty-explorer.msix has an unexpected entry: $en"
            }
            $k++
            $tmp = Join-Path $msixScan ("e$k.bin")
            [IO.Compression.ZipFileExtensions]::ExtractToFile($ent, $tmp, $true)
            $hit = Test-Privacy -Path $tmp
            if ($null -ne $hit) { Fail ("privacy ghostty-explorer.msix/$en " + ($hit -replace '^(\d+): ', '@$1: ')) }
            if ($en -eq 'AppxManifest.xml') { $manifestText = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8) }
        }
    } finally { $msixZip.Dispose() }
    Remove-Item -LiteralPath $msixScan -Recurse -Force
    if ($null -eq $manifestText) { Fail 'ghostty-explorer.msix has no AppxManifest.xml' }
    $mx = [xml]$manifestText
    $idn = $mx.Package.Identity
    if ($idn.Name -ne $mn.Groups[1].Value) { Fail "msix package name '$($idn.Name)' <> ids.zig '$($mn.Groups[1].Value)'" }
    if ($idn.Publisher -cne $oidPublisher) { Fail "msix publisher '$($idn.Publisher)'" }
    $clsids = @([regex]::Matches($manifestText, '(?:Clsid|Id)="([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"') | ForEach-Object { $_.Groups[1].Value })
    if ($clsids.Count -ne 3) { Fail "msix manifest names $($clsids.Count) CLSIDs (want 3: two verbs and the class)" }
    foreach ($c in $clsids) {
        if ("{$c}" -ne $mc.Groups[1].Value) { Fail "msix CLSID {$c} <> ids.zig $($mc.Groups[1].Value)" }
    }
    if ($manifestText -match '\{\{') { Fail 'msix manifest has an unreplaced placeholder' }
    if ($idn.Version -ne $ver4) { Fail "msix version '$($idn.Version)' <> '$ver4'" }
    if ($idn.ProcessorArchitecture -ne $Arch) { Fail "msix architecture '$($idn.ProcessorArchitecture)' <> '$Arch'" }

    # The staged DLL must be built for -Arch (an x64 DLL in an arm64 package
    # would register and never load).
    try { $machine = Get-PeMachine (Join-Path $stage 'ghostty-explorer.dll') } catch { Fail ('ghostty-explorer.dll: ' + $_.Exception.Message) }
    $wantMachine = if ($Arch -eq 'arm64') { 0xAA64 } else { 0x8664 }
    if ($machine -ne $wantMachine) { Fail ('ghostty-explorer.dll machine 0x{0:X4} <> {1}' -f $machine, $Arch) }

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

    # Imports (M4, M5, M7). Read from the PE tables (no dumpbin needed); a file
    # that cannot be parsed fails the package.
    if ($Local) {
        Write-Host 'package: SKIP imports (-Local)'
    } else {
        function Get-Imports([string]$exePath) {
            try { return @(Get-PeImports $exePath) } catch { Fail "imports: cannot read $exePath ($($_.Exception.Message))" }
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
        # The DLL loads into Explorer: no CRT, only kernel32, ole32, shell32 (R-M7-13).
        $ei = Get-Imports (Join-Path $stage 'ghostty-explorer.dll')
        if ($ei.Count -eq 0) { Fail 'imports: ghostty-explorer.dll has no imports (reader problem)' }
        foreach ($d in $ei) {
            if ($d -notin @('kernel32.dll', 'ole32.dll', 'shell32.dll')) { Fail "imports: ghostty-explorer.dll imports $d" }
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
        foreach ($exe in 'ghostty.exe', 'tmux.exe', 'ghostty-explorer.dll') {
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
