# Validates a release number N and prints the version and tag
# (Windows PowerShell 5.1, ASCII only). R-M6-7. No network: it reads
# build.zig.zon and local git refs only.
#
#   release-version.ps1 -N <string> [-Rehearsal] [-Zon <string>] [-RepoRoot <dir>]
#       prints zon=..., version-string=..., tag=..., sha=...  (exit 0)
#       or one "release-version: <rule>" line per broken rule (exit 1)
#   release-version.ps1 -SelfTest
#
# -N is a string on purpose: "07" and "+5" must reach the rules unchanged.
# -Zon is optional: the zon version the caller believes in; it must equal
# build.zig.zon's .version.
# -Rehearsal builds with N = 0 and skips the last three checks (N above the
# existing tags, clean tree, HEAD pushed).
[CmdletBinding()]
param(
    [string]$N = '',
    [switch]$Rehearsal,
    [string]$Zon = '',
    [string]$RepoRoot = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The pure rules. Returns the list of broken rules (empty = valid).
# $Tags: the local win-* tag names. $AncestorState: ok | no | unknown.
function Test-ReleaseRules {
    param(
        [string]$N,
        [bool]$Rehearsal,
        [string]$ClaimedZon,
        [string]$ActualZon,
        [string[]]$Tags,
        [bool]$Dirty,
        [string]$AncestorState
    )
    $errs = New-Object System.Collections.Generic.List[string]
    $canon = ($N -cmatch '^(0|[1-9][0-9]*)\z')
    $num = -1
    if (-not $canon) {
        $errs.Add("N '$N' is not canonical (digits only, no sign, no leading zero)")
    } elseif ($N.Length -gt 5 -or [int]$N -gt 65535) {
        $errs.Add("N '$N' is above 65535")
    } else {
        $num = [int]$N
    }
    if ($num -ge 0) {
        if ($num -eq 0 -and -not $Rehearsal) { $errs.Add('N = 0 is only for -Rehearsal; the first release is N = 1') }
        if ($num -ne 0 -and $Rehearsal) { $errs.Add("-Rehearsal builds with N = 0, not $N") }
    }
    if ($ClaimedZon -and $ClaimedZon -cne $ActualZon) {
        $errs.Add("zon version '$ClaimedZon' is not build.zig.zon's .version '$ActualZon'")
    }
    if (-not $Rehearsal) {
        if ($num -ge 1) {
            $max = 0
            $maxTag = ''
            $dup = ''
            foreach ($t in $Tags) {
                if ($t -cmatch '^win-.+-(0|[1-9][0-9]*)$') {
                    $tn = [int]$Matches[1]
                    if ($tn -eq $num) { $dup = $t }
                    if ($tn -gt $max) { $max = $tn; $maxTag = $t }
                }
            }
            if ($dup) {
                $errs.Add("N $num is already used by tag $dup (a tag's N is never reused)")
            } elseif ($num -le $max) {
                $errs.Add("N $num is not above the highest existing N $max ($maxTag); run: git fetch --tags origin")
            }
        }
        if ($Dirty) { $errs.Add('the working tree is dirty (commit or stash first)') }
        if ($AncestorState -eq 'no') {
            $errs.Add('HEAD is not contained in origin/windows; push first: git push origin windows')
        } elseif ($AncestorState -eq 'unknown') {
            $errs.Add('no local origin/windows ref; run: git fetch origin')
        }
    }
    return $errs.ToArray()
}

function Invoke-ReleaseVersionSelfTest {
    $base = @{ N = '3'; R = $false; Cz = ''; Az = '1.3.2-dev'; Tags = @('win-1.3.2-dev-1', 'win-1.3.2-dev-2'); D = $false; A = 'ok' }
    $cases = @(
        @{ n = 'valid';           o = @{};                                  want = '' },
        @{ n = 'valid-claimed';   o = @{ Cz = '1.3.2-dev' };                want = '' },
        @{ n = 'valid-no-tags';   o = @{ N = '1'; Tags = @() };             want = '' },
        @{ n = 'leading-zero';    o = @{ N = '07' };                        want = 'not canonical' },
        @{ n = 'plus';            o = @{ N = '+5' };                        want = 'not canonical' },
        @{ n = 'empty';           o = @{ N = '' };                          want = 'not canonical' },
        @{ n = 'minus';           o = @{ N = '-1' };                        want = 'not canonical' },
        @{ n = 'max';             o = @{ N = '65535'; Tags = @() };         want = '' },
        @{ n = 'over-max';        o = @{ N = '65536' };                     want = 'above 65535' },
        @{ n = 'huge';            o = @{ N = '99999999999999999999' };      want = 'above 65535' },
        @{ n = 'zero-release';    o = @{ N = '0' };                         want = 'only for -Rehearsal' },
        @{ n = 'rehearsal-zero';  o = @{ N = '0'; R = $true; D = $true; A = 'no'; Tags = @('win-1.3.2-dev-9') }; want = '' },
        @{ n = 'rehearsal-n';     o = @{ N = '3'; R = $true };              want = 'builds with N = 0' },
        @{ n = 'zon-mismatch';    o = @{ Cz = '1.3.1' };                    want = "is not build.zig.zon's" },
        @{ n = 'not-above';       o = @{ N = '2'; Tags = @('win-1.3.2-dev-5') }; want = 'not above the highest' },
        @{ n = 'duplicate';       o = @{ N = '2' };                         want = 'already used by tag win-1.3.2-dev-2' },
        @{ n = 'other-zon-tag';   o = @{ N = '4'; Tags = @('win-1.3.1-7') }; want = 'not above the highest' },
        @{ n = 'dirty';           o = @{ D = $true };                       want = 'dirty' },
        @{ n = 'not-pushed';      o = @{ A = 'no' };                        want = 'push first' },
        @{ n = 'no-origin';       o = @{ A = 'unknown' };                   want = 'git fetch origin' }
    )
    $fail = New-Object System.Collections.Generic.List[string]
    foreach ($c in $cases) {
        $p = @{} + $base
        foreach ($k in $c.o.Keys) { $p[$k] = $c.o[$k] }
        $r = @(Test-ReleaseRules -N $p.N -Rehearsal $p.R -ClaimedZon $p.Cz -ActualZon $p.Az -Tags $p.Tags -Dirty $p.D -AncestorState $p.A)
        if ($c.want -eq '') {
            if ($r.Count -ne 0) { $fail.Add("$($c.n): expected valid, got: $($r -join ' | ')") }
        } else {
            $hit = @($r | Where-Object { $_ -like ('*' + $c.want + '*') })
            if ($hit.Count -eq 0) { $fail.Add("$($c.n): expected '$($c.want)', got: $($r -join ' | ')") }
        }
    }
    if ($fail.Count -gt 0) {
        $fail | ForEach-Object { Write-Host "release-version self-test FAIL: $_" }
        return $false
    }
    Write-Host ("release-version self-test: {0} cases passed" -f $cases.Count)
    return $true
}

if ($SelfTest) {
    if (Invoke-ReleaseVersionSelfTest) { exit 0 } else { exit 1 }
}

if (-not $RepoRoot) { $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }

# Runs git in the repo; never aborts on stderr. Returns @{ Code; Lines }.
function Invoke-Git {
    param([string[]]$GitArgs)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $RepoRoot @GitArgs 2>&1
        $code = $LASTEXITCODE
        $lines = @($out | ForEach-Object { "$_" } | Where-Object { $_.Length -gt 0 })
        return @{ Code = $code; Lines = $lines }
    } finally { $ErrorActionPreference = $saved }
}

$zonPath = Join-Path $RepoRoot 'build.zig.zon'
if (-not (Test-Path -LiteralPath $zonPath)) {
    Write-Host "release-version: build.zig.zon not found in $RepoRoot"
    exit 1
}
$zonText = [IO.File]::ReadAllText($zonPath)
if ($zonText -notmatch '\.version\s*=\s*"([^"]+)"') {
    Write-Host 'release-version: no .version in build.zig.zon'
    exit 1
}
$actualZon = $Matches[1]

$tags = @()
$dirty = $false
$ancestor = 'ok'
$sha = ''
$g = Invoke-Git @('rev-parse', 'HEAD')
if ($g.Code -ne 0 -or $g.Lines.Count -eq 0) {
    Write-Host 'release-version: git rev-parse HEAD failed'
    exit 1
}
$sha = $g.Lines[0].Trim()
if (-not $Rehearsal) {
    $g = Invoke-Git @('tag', '-l', 'win-*')
    if ($g.Code -ne 0) { Write-Host 'release-version: git tag -l failed'; exit 1 }
    $tags = @($g.Lines)
    $g = Invoke-Git @('status', '--porcelain')
    if ($g.Code -ne 0) { Write-Host 'release-version: git status failed'; exit 1 }
    $dirty = ($g.Lines.Count -gt 0)
    $g = Invoke-Git @('rev-parse', '--verify', '--quiet', 'refs/remotes/origin/windows')
    if ($g.Code -ne 0) {
        $ancestor = 'unknown'
    } else {
        $g = Invoke-Git @('merge-base', '--is-ancestor', 'HEAD', 'origin/windows')
        $ancestor = if ($g.Code -eq 0) { 'ok' } else { 'no' }
    }
}

$errs = @(Test-ReleaseRules -N $N -Rehearsal ([bool]$Rehearsal) -ClaimedZon $Zon -ActualZon $actualZon -Tags $tags -Dirty $dirty -AncestorState $ancestor)
if ($errs.Count -gt 0) {
    foreach ($e in $errs) { Write-Host "release-version: $e" }
    exit 1
}

$nn = [string][int]$N
Write-Host "zon=$actualZon"
Write-Host "version-string=$actualZon-win.$nn"
Write-Host "tag=win-$actualZon-$nn"
Write-Host "sha=$sha"
exit 0
