# Builds the unsigned sparse package ghostty-explorer.msix (Windows 11 top-level
# "Open Ghostty here") into a package.ps1 stage (Windows PowerShell 5.1,
# ASCII only). The package is never signed.
#
#   build-sparse.ps1 -Stage <stage dir> -Version <4-part> -Arch x64|arm64
#   build-sparse.ps1 -Probe       prints the makeappx path (exit 0) or the not-found text (exit 2)
#   build-sparse.ps1 -SelfTest    manifest template checks; needs no makeappx
#
# Exit 0 ok, 1 a check failed, 2 makeappx not found.
[CmdletBinding()]
param(
    [string]$Stage,
    [string]$Version,
    [ValidateSet('x64', 'arm64')][string]$Arch,
    [switch]$Probe,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\lib\Native.psm1') -Force -DisableNameChecking

$template = Join-Path $PSScriptRoot 'AppxManifest.xml'
$assets = Join-Path $PSScriptRoot 'Assets'
$assetNames = @('StoreLogo.png', 'Square44x44Logo.png', 'Square150x150Logo.png')
$oidPublisher = 'CN=Ghostty Windows port (unofficial), OID.2.25.311729368913984317654407730594956997722=1'

# $env:MAKEAPPX overrides: when it is set, only it is tried.
function Find-MakeAppx {
    if ($env:MAKEAPPX) {
        if (Test-Path -LiteralPath $env:MAKEAPPX -PathType Leaf) { return $env:MAKEAPPX }
        return $null
    }
    $kits = @()
    if (${env:ProgramFiles(x86)}) { $kits += (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin') }
    if ($env:ProgramFiles) { $kits += (Join-Path $env:ProgramFiles 'Windows Kits\10\bin') }
    $found = @()
    foreach ($k in $kits) {
        if (-not (Test-Path -LiteralPath $k -PathType Container)) { continue }
        foreach ($d in (Get-ChildItem -LiteralPath $k -Directory)) {
            $p = Join-Path $d.FullName 'x64\makeappx.exe'
            if (Test-Path -LiteralPath $p -PathType Leaf) { $found += [pscustomobject]@{ Dir = $d.Name; Path = $p } }
        }
    }
    if ($found.Count -gt 0) {
        # Highest SDK version first; a non-numeric folder name sorts last.
        $best = $found | Sort-Object { try { [version]$_.Dir } catch { [version]'0.0' } } -Descending | Select-Object -First 1
        return $best.Path
    }
    $cmd = Get-Command makeappx.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-MakeAppxNotFoundText {
    if ($env:MAKEAPPX) { return 'makeappx.exe not found (MAKEAPPX is set but names no file); install the Windows SDK or fix MAKEAPPX' }
    return 'makeappx.exe not found (looked in: Windows Kits\10\bin\*\x64 and PATH); install the Windows 10/11 SDK or set MAKEAPPX'
}

# Names of the failed checks of a manifest template text (empty = ok).
function Get-TemplateFailures([string]$text) {
    $f = New-Object System.Collections.Generic.List[string]
    if (-not $text.Contains('Publisher="' + $oidPublisher + '"')) { $f.Add('publisher OID') }
    if ($text -notmatch '<uap10:AllowExternalContent>\s*true\s*</uap10:AllowExternalContent>') { $f.Add('AllowExternalContent') }
    if ($text -notmatch 'TargetDeviceFamily\s+Name="Windows\.Desktop"\s+MinVersion="10\.0\.22000\.0"') { $f.Add('MinVersion 10.0.22000.0') }
    if ($text -notmatch 'AppListEntry="none"') { $f.Add('AppListEntry none') }
    foreach ($t in 'Directory', 'Directory\Background') {
        if ($text -notmatch ('<desktop5:ItemType\s+Type="' + [regex]::Escape($t) + '"')) { $f.Add("item type $t") }
    }
    if ($text -notmatch 'ThreadingModel="STA"') { $f.Add('ThreadingModel STA') }
    if ($text -notmatch 'Verb\s+Id="GhosttyOpenHere"\s+Clsid="\{\{CLSID\}\}"') { $f.Add('CLSID placeholder (verb)') }
    if ($text -notmatch '<com:Class\s+Id="\{\{CLSID\}\}"') { $f.Add('CLSID placeholder (class)') }
    if ($text -notmatch 'Version="\{\{VERSION\}\}"') { $f.Add('VERSION placeholder') }
    if ($text -notmatch 'ProcessorArchitecture="\{\{ARCH\}\}"') { $f.Add('ARCH placeholder') }
    if ($text -notmatch 'Name="Ghostty\.ExplorerMenu"') { $f.Add('package name') }
    return , $f.ToArray()
}

if ($SelfTest) {
    $fail = @()
    function Check([string]$name, $cond) { if (-not $cond) { $script:fail += $name } }
    if (-not (Test-Path -LiteralPath $template -PathType Leaf)) {
        Write-Host 'build-sparse: SELFTEST FAIL: manifest template missing'
        exit 1
    }
    $text = [IO.File]::ReadAllText($template)
    $base = Get-TemplateFailures $text
    if ($base.Count -gt 0) { Write-Host ('build-sparse: SELFTEST FAIL: ' + ($base -join ', ')); exit 1 }
    try { $null = [xml]$text } catch { $fail += 'template is not well-formed XML' }
    # Each rule must catch its own breakage.
    $mut = @(
        @('publisher OID', 'OID.2.25.311729368913984317654407730594956997722=1', 'OID.2.25.1=1'),
        @('AllowExternalContent', 'AllowExternalContent>true<', 'AllowExternalContent>false<'),
        @('MinVersion 10.0.22000.0', 'MinVersion="10.0.22000.0"', 'MinVersion="10.0.19041.0"'),
        @('AppListEntry none', 'AppListEntry="none"', 'AppListEntry="default"'),
        @('item type Directory\Background', 'Type="Directory\Background"', 'Type="Background"'),
        @('item type Directory', 'Type="Directory"', 'Type="Dir"'),
        @('CLSID placeholder (verb)', 'Verb Id="GhosttyOpenHere" Clsid="{{CLSID}}"', 'Verb Id="GhosttyOpenHere" Clsid="x"'),
        @('VERSION placeholder', 'Version="{{VERSION}}"', 'Version="1.0.0.0"'),
        @('ARCH placeholder', 'ProcessorArchitecture="{{ARCH}}"', 'ProcessorArchitecture="x64"'),
        @('package name', 'Name="Ghostty.ExplorerMenu"', 'Name="Other"'),
        @('ThreadingModel STA', 'ThreadingModel="STA"', 'ThreadingModel="MTA"'),
        @('CLSID placeholder (class)', '<com:Class Id="{{CLSID}}"', '<com:Class Id="{5DCE6858-478B-4439-9D93-6DAB0557A7BB}"')
    )
    foreach ($m in $mut) {
        $bad = $text.Replace($m[1], $m[2])
        Check ('mutation not applied: ' + $m[0]) ($bad -ne $text)
        $got = Get-TemplateFailures $bad
        Check ('rule "' + $m[0] + '" misses its breakage') ($got -contains $m[0])
    }
    # The PE reader (package.ps1's import check) against a built DLL, when there is one.
    $dll = Join-Path $PSScriptRoot '..\..\..\zig-out\bin\ghostty-explorer.dll'
    if (Test-Path -LiteralPath $dll -PathType Leaf) {
        $imp = @(Get-PeImports $dll)
        Check 'PE reader: imports include kernel32' ($imp -contains 'kernel32.dll')
        Check 'PE reader: machine is x64 or arm64' ((Get-PeMachine $dll) -in @(0x8664, 0xAA64))
        $threw = $false
        try { $null = Get-PeImports $template } catch { $threw = $true }
        Check 'PE reader: a non-PE file throws' $threw
    } else {
        Write-Host 'build-sparse: selftest: no built ghostty-explorer.dll, PE reader case skipped'
    }
    foreach ($n in $assetNames) {
        Check ('asset missing: ' + $n) (Test-Path -LiteralPath (Join-Path $assets $n) -PathType Leaf)
    }
    if ($fail.Count -gt 0) { Write-Host ('build-sparse: SELFTEST FAIL: ' + ($fail -join ', ')); exit 1 }
    Write-Host 'build-sparse: selftest ok'
    exit 0
}

try {
    $mk = Find-MakeAppx
    if ($Probe) {
        if ($mk) { Write-Host $mk; exit 0 }
        Write-Host (Get-MakeAppxNotFoundText); exit 2
    }
    if (-not $mk) { Write-Host (Get-MakeAppxNotFoundText); exit 2 }
    foreach ($n in 'Stage', 'Version', 'Arch') {
        if (-not (Get-Variable $n -ValueOnly)) { Write-Host "build-sparse: FAIL -$n is required"; exit 1 }
    }
    if ($Version -notmatch '^(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})$') {
        Write-Host "build-sparse: FAIL version '$Version' is not 4-part (X.Y.Z.N, each 0..65535)"; exit 1
    }
    foreach ($p in ($Version -split '\.')) {
        if ([int]$p -gt 65535) { Write-Host "build-sparse: FAIL version part $p > 65535"; exit 1 }
    }
    if (-not (Test-Path -LiteralPath $Stage -PathType Container)) { Write-Host "build-sparse: FAIL no such stage: $Stage"; exit 1 }
    $Stage = (Resolve-Path -LiteralPath $Stage).Path.TrimEnd('\')

    # The CLSID comes from the single source of truth, ids.zig.
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $ids = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'src\explorer_command\ids.zig')
    $m = [regex]::Match($ids, 'pub const clsid_text = "(\{[0-9A-Fa-f-]{36}\})";')
    if (-not $m.Success) { Write-Host 'build-sparse: FAIL clsid_text not found in src\explorer_command\ids.zig'; exit 1 }
    $clsid = $m.Groups[1].Value.Trim('{', '}')   # manifests take the GUID without braces

    $text = [IO.File]::ReadAllText($template)
    $bad = Get-TemplateFailures $text
    if ($bad.Count -gt 0) { Write-Host ('build-sparse: FAIL manifest template: ' + ($bad -join ', ')); exit 1 }
    $manifest = $text.Replace('{{VERSION}}', $Version).Replace('{{ARCH}}', $Arch).Replace('{{CLSID}}', $clsid)
    if ($manifest.Contains('{{')) { Write-Host 'build-sparse: FAIL unreplaced placeholder in the manifest'; exit 1 }

    $work = Join-Path ([IO.Path]::GetTempPath()) ('ghostty-sparse-' + [guid]::NewGuid().ToString('N'))
    $layout = Join-Path $work 'layout'
    try {
        # The layout holds only the manifest and Assets (the DLL and exe stay in the app folder).
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $layout 'Assets')
        foreach ($n in $assetNames) {
            $src = Join-Path $assets $n
            if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { Write-Host "build-sparse: FAIL missing asset $n"; exit 1 }
            Copy-Item -LiteralPath $src -Destination (Join-Path $layout "Assets\$n")
        }
        [IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'), $manifest, (New-Object System.Text.UTF8Encoding($false)))
        $out = Join-Path $Stage 'ghostty-explorer.msix'
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
        $log = Join-Path $work 'makeappx.log'
        $rc = Invoke-Native -Exe $mk -Args @('pack', '/o', '/nv', '/d', $layout, '/p', $out) -Log $log -Quiet
        if ($rc -ne 0 -or -not (Test-Path -LiteralPath $out -PathType Leaf)) {
            $tail = (Get-Content -LiteralPath $log -ErrorAction SilentlyContinue | Select-Object -Last 15) -join "`r`n"
            if ($env:USERPROFILE) { $tail = $tail.Replace($env:USERPROFILE, '%USERPROFILE%') }
            Write-Host $tail
            Write-Host "build-sparse: FAIL makeappx pack (exit $rc)"
            exit 1
        }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "build-sparse: wrote ghostty-explorer.msix ($Version, $Arch)"
    exit 0
} catch {
    Write-Host ('build-sparse: FAIL unexpected: ' + $_.Exception.Message)
    exit 1
}
