# Builds the per-user Inno Setup installer from a package.ps1 stage
# (Windows PowerShell 5.1, ASCII only).
#
#   build.ps1 -Stage <dir> -Version <v> -Arch x64|arm64 -OutDir <dir>
#             [-Test] [-SignCommand '<cmd with {file}>']
#   build.ps1 -Probe       prints the ISCC path (exit 0) or the not-found text (exit 2)
#   build.ps1 -SelfTest    checks the ISCC argument lists; needs no ISCC
#
# Exit 0 ok, 1 failure, 2 no ISCC (R-M6-6).
[CmdletBinding()]
param(
    [string]$Stage,
    [string]$Version,
    [ValidateSet('x64', 'arm64')][string]$Arch,
    [string]$OutDir,
    [switch]$Test,
    [string]$SignCommand = '',
    [switch]$Probe,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\lib\Native.psm1') -Force -DisableNameChecking

function Get-IsccCandidates {
    $c = New-Object System.Collections.Generic.List[string]
    if ($env:ISCC) { $c.Add($env:ISCC) }
    if ($env:LOCALAPPDATA) { $c.Add((Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')) }
    if (${env:ProgramFiles(x86)}) { $c.Add((Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')) }
    if ($env:ProgramFiles) { $c.Add((Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')) }
    return , $c.ToArray()
}

# $env:ISCC overrides: when it is set, only it is tried.
function Find-Iscc {
    $cands = Get-IsccCandidates
    $try = if ($env:ISCC) { @($cands[0]) } else { $cands }
    foreach ($p in $try) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

function Get-IsccNotFoundText {
    return ('ISCC.exe not found (looked in: ' + ((Get-IsccCandidates) -join '; ') + '); install Inno Setup 6 or set ISCC')
}

# X.Y.Z[-pre]-win.N  ->  X.Y.Z.N (the 4-part FILEVERSION of the exes).
function Get-VerInfo([string]$v) {
    $m = [regex]::Match($v, '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[^+\s]+)?-win\.(0|[1-9][0-9]*)$')
    if (-not $m.Success) { return $null }
    return ('{0}.{1}.{2}.{3}' -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value, $m.Groups[5].Value)
}

function Get-IsccArgs([string]$stage, [string]$version, [string]$arch, [string]$outDir, [bool]$test, [string]$sign, [string]$iss) {
    $vi = Get-VerInfo $version
    if (-not $vi) { throw "version '$version' does not end in -win.<N>" }
    $a = @('/Q', "/DAppVersion=$version", "/DVerInfo=$vi", "/DArch=$arch", "/DStage=$stage", "/DOutDir=$outDir")
    if ($test) { $a += '/DGhosttyTest' }
    if ($sign) { $a += @('/DSign', ('/Ssigntool=' + $sign.Replace('{file}', '$f'))) }
    $a += $iss
    return , $a
}

if ($SelfTest) {
    $fail = @()
    function Check([string]$name, $cond) { if (-not $cond) { $script:fail += $name } }
    $iss = 'ghostty.iss'
    $x = Get-IsccArgs 'S' '1.4.0-win.0' 'x64' 'O' $false '' $iss
    Check 'x64 defines' (($x -contains '/DAppVersion=1.4.0-win.0') -and ($x -contains '/DVerInfo=1.4.0.0') -and ($x -contains '/DArch=x64') -and ($x -contains '/DStage=S') -and ($x -contains '/DOutDir=O'))
    Check 'x64 no test/sign' (($x -notcontains '/DGhosttyTest') -and ($x -notcontains '/DSign'))
    Check 'x64 script last' ($x[$x.Count - 1] -eq $iss)
    $r = Get-IsccArgs 'S' '1.4.0-dev.5-win.12' 'arm64' 'O' $false '' $iss
    Check 'arm64' (($r -contains '/DArch=arm64') -and ($r -contains '/DVerInfo=1.4.0.12'))
    $t = Get-IsccArgs 'S' '1.4.0-win.0' 'x64' 'O' $true '' $iss
    Check 'test' (($t -contains '/DGhosttyTest') -and ($t -notcontains '/DSign'))
    $s = Get-IsccArgs 'S' '1.4.0-win.0' 'x64' 'O' $false 'signtool sign /f x.pfx {file}' $iss
    Check 'sign' (($s -contains '/DSign') -and ($s -contains '/Ssigntool=signtool sign /f x.pfx $f'))
    $bad = $false
    try { $null = Get-IsccArgs 'S' '1.4.0' 'x64' 'O' $false '' $iss } catch { $bad = $true }
    Check 'bad version throws' $bad
    $saved = $env:ISCC
    try {
        $env:ISCC = Join-Path ([IO.Path]::GetTempPath()) 'no-such-dir\ISCC.exe'
        Check 'missing ISCC env -> null' ($null -eq (Find-Iscc))
        Check 'not-found text' ((Get-IsccNotFoundText) -match '^ISCC\.exe not found \(looked in: .*\); install Inno Setup 6 or set ISCC$')
    } finally { $env:ISCC = $saved }
    if ($fail.Count -gt 0) { Write-Host ('build: SELFTEST FAIL: ' + ($fail -join ', ')); exit 1 }
    Write-Host 'build: selftest ok'
    exit 0
}

try {
    $iscc = Find-Iscc
    if ($Probe) {
        if ($iscc) { Write-Host $iscc; exit 0 }
        Write-Host (Get-IsccNotFoundText); exit 2
    }
    if (-not $iscc) { Write-Host (Get-IsccNotFoundText); exit 2 }
    foreach ($n in 'Stage', 'Version', 'Arch', 'OutDir') {
        if (-not (Get-Variable $n -ValueOnly)) { Write-Host "build: FAIL -$n is required"; exit 1 }
    }
    if (-not (Test-Path -LiteralPath $Stage -PathType Container)) { Write-Host "build: FAIL no such stage: $Stage"; exit 1 }
    $null = New-Item -ItemType Directory -Force -Path $OutDir
    $Stage = (Resolve-Path -LiteralPath $Stage).Path.TrimEnd('\')
    $OutDir = (Resolve-Path -LiteralPath $OutDir).Path.TrimEnd('\')
    $iss = Join-Path $PSScriptRoot 'ghostty.iss'
    $isccArgs = Get-IsccArgs $Stage $Version $Arch $OutDir ([bool]$Test) $SignCommand $iss
    $log = Join-Path $OutDir 'installer.log'
    $rc = Invoke-Native -Exe $iscc -Args $isccArgs -Log $log -HideCmdLine:([bool]$SignCommand)
    if ($rc -ne 0) { Write-Host "build: FAIL ISCC exit $rc (see $log)"; exit 1 }
    $setup = Join-Path $OutDir ("ghostty-$Version-windows-$Arch-setup" + $(if ($Test) { '-test' } else { '' }) + '.exe')
    if (-not (Test-Path -LiteralPath $setup)) { Write-Host "build: FAIL ISCC did not write $setup"; exit 1 }
    Write-Host "artifact: $setup"
    exit 0
} catch {
    Write-Host ('build: FAIL unexpected: ' + $_.Exception.Message)
    exit 1
}
