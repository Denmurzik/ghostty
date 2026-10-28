# Coverage check for THIRD_PARTY_NOTICES.txt (Windows PowerShell 5.1). ASCII only.
#
#   third-party-check.ps1 -RepoRoot <dir> -Arch x64|arm64 [-Notices <file>] [-PkgDir <zig-pkg>]
#   third-party-check.ps1 -SelfTest
#
# Reads the dependency names of build.zig.zon and, recursively, of every
# build.zig.zon reachable from it (path dependencies, and fetched packages under
# zig-pkg), plus every pkg/* folder. Adds the toolchain table for the arch and
# microsoft/terminal. Each name needs a "== <name> ==" section in the notices
# file, or an entry in the exclusion table below with a one-line reason.
# Names compare case-insensitively with '-' equal to '_'.
#
# Exit 0 = covered, 1 = something is missing (each line "third-party-check: FAIL ...").

[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
    [string]$Notices = '',
    [string]$PkgDir = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- tables (R-M6-10) ------------------------------------------------------

# Shipped in every Windows build, whatever the dependency graph says.
$script:FixedAll = @(
    'zig',                  # Zig std + compiler_rt, compiled into every exe
    'microsoft/terminal',   # bundled ConPTY: conpty.dll, OpenConsole.exe
    'noto_emoji'            # src/font/res/NotoColorEmoji.ttf, NotoEmoji-Regular.ttf, embedded
)
# Linked on top of that for aarch64-windows-gnu (libc++ for the C++ deps, the
# unwinder, and Zig's MinGW-w64 C runtime with its winpthreads files).
$script:FixedArm64 = @('libc++', 'libc++abi', 'libunwind', 'mingw-w64', 'winpthreads')

# Not in the Windows exes, or not third-party code. Name -> one-line reason.
$script:Exclusions = [ordered]@{
    'afl++'                     = 'fuzzing harness, not built into any exe'
    'android_ndk'               = 'Android only'
    'apple_sdk'                 = 'macOS and iOS only'
    'aro'                       = 'build time only (translate_c); nothing is linked'
    'breakpad'                  = 'only with -Dsentry, which is off on Windows'
    'fontconfig'                = 'Linux only; the Windows font backend is freetype'
    'gettext'                   = 'Linux only (libintl dependency)'
    'gobject'                   = 'GTK, Linux only'
    'gtk4_layer_shell'          = 'Linux only'
    'libintl'                   = 'Linux only (gettext)'
    'libxml2'                   = 'Linux only (fontconfig dependency)'
    'macos'                     = 'macOS only'
    'opengl'                    = 'OpenGL renderer bindings; Windows renders with D3D11'
    'pixels'                    = 'wuffs test images, not compiled'
    'plasma_wayland_protocols'  = 'Wayland, Linux only'
    'sentry'                    = 'crash reporting is off on Windows (own minidump writer)'
    'translate_c'               = 'build time only; nothing is linked'
    'wayland'                   = 'Linux only'
    'wayland_protocols'         = 'Linux only'
    'win32'                     = 'first-party hand-written bindings (Ghostty LICENSE)'
    'zig_js'                    = 'WebAssembly only'
    'zig_objc'                  = 'macOS only'
    'zig_wayland'               = 'Linux only'
}

function Norm([string]$n) { return $n.Trim().ToLowerInvariant().Replace('-', '_') }

# ---- zon reading ------------------------------------------------------------

# Removes // comments outside strings.
function Remove-ZonComments([string]$t) {
    $sb = New-Object System.Text.StringBuilder
    $inStr = $false
    $i = 0
    while ($i -lt $t.Length) {
        $c = $t[$i]
        if ($inStr) {
            [void]$sb.Append($c)
            if ($c -eq '\' -and ($i + 1) -lt $t.Length) { $i++; [void]$sb.Append($t[$i]) }
            elseif ($c -eq '"') { $inStr = $false }
        } elseif ($c -eq '"') {
            $inStr = $true; [void]$sb.Append($c)
        } elseif ($c -eq '/' -and ($i + 1) -lt $t.Length -and $t[$i + 1] -eq '/') {
            while ($i -lt $t.Length -and $t[$i] -ne "`n") { $i++ }
            continue
        } else {
            [void]$sb.Append($c)
        }
        $i++
    }
    return $sb.ToString()
}

# Returns @{ Name; Path; Hash } for each entry of `.dependencies = .{ ... }`.
function Get-ZonDeps([string]$text) {
    $t = Remove-ZonComments $text
    $m = [regex]::Match($t, '\.dependencies\s*=\s*\.\{')
    if (-not $m.Success) { return @() }
    $i = $m.Index + $m.Length
    $depth = 1
    $inStr = $false
    $start = $i
    $entries = New-Object System.Collections.Generic.List[string]
    while ($i -lt $t.Length -and $depth -gt 0) {
        $c = $t[$i]
        if ($inStr) {
            if ($c -eq '\') { $i++ } elseif ($c -eq '"') { $inStr = $false }
        } elseif ($c -eq '"') { $inStr = $true }
        elseif ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') {
            $depth--
            if ($depth -eq 1) { $entries.Add($t.Substring($start, $i - $start + 1)); $start = $i + 1 }
        }
        $i++
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($e in $entries) {
        $k = [regex]::Match($e, '^[\s,]*\.(?:@"([^"]+)"|([A-Za-z_][A-Za-z0-9_]*))\s*=')
        if (-not $k.Success) { continue }
        $name = if ($k.Groups[1].Success) { $k.Groups[1].Value } else { $k.Groups[2].Value }
        $p = [regex]::Match($e, '\.path\s*=\s*"([^"]*)"')
        $h = [regex]::Match($e, '\.hash\s*=\s*"([^"]*)"')
        $out.Add(@{
                Name = $name
                Path = $(if ($p.Success) { $p.Groups[1].Value } else { '' })
                Hash = $(if ($h.Success) { $h.Groups[1].Value } else { '' })
            })
    }
    return $out.ToArray()
}

# Every dependency name reachable from the root zon, plus pkg/*.
function Get-AllNames([string]$repoRoot, [string]$pkgDir) {
    $names = @{}
    $seen = @{}
    $queue = New-Object System.Collections.Generic.Queue[string]
    $queue.Enqueue($repoRoot)
    $pkgRoot = Join-Path $repoRoot 'pkg'
    if (Test-Path -LiteralPath $pkgRoot -PathType Container) {
        foreach ($d in Get-ChildItem -LiteralPath $pkgRoot -Directory) {
            $names[(Norm $d.Name)] = $true
            $queue.Enqueue($d.FullName)
        }
    }
    while ($queue.Count -gt 0) {
        $dir = $queue.Dequeue()
        $full = [IO.Path]::GetFullPath($dir).TrimEnd('\').ToLowerInvariant()
        if ($seen.ContainsKey($full)) { continue }
        $seen[$full] = $true
        $zon = Join-Path $dir 'build.zig.zon'
        if (-not (Test-Path -LiteralPath $zon -PathType Leaf)) { continue }
        foreach ($d in (Get-ZonDeps ([IO.File]::ReadAllText($zon)))) {
            $names[(Norm $d.Name)] = $true
            if ($d.Path) {
                $queue.Enqueue((Join-Path $dir ($d.Path.Replace('/', '\'))))
            } elseif ($d.Hash -and $pkgDir) {
                $queue.Enqueue((Join-Path $pkgDir $d.Hash))
            }
        }
    }
    return @($names.Keys | Sort-Object)
}

# ---- the check --------------------------------------------------------------

# Returns the list of failure strings (empty = covered).
function Get-CoverageFailures([string[]]$names, [string]$noticesText, [string]$arch,
                              $exclusions, [string[]]$fixedAll, [string[]]$fixedArm64) {
    $fails = New-Object System.Collections.Generic.List[string]
    $sections = @{}
    foreach ($m in [regex]::Matches($noticesText, '(?m)^== (.+?) ==[ \t]*\r?$')) {
        $sections[(Norm $m.Groups[1].Value)] = $true
    }
    $excl = @{}
    foreach ($k in $exclusions.Keys) {
        $reason = [string]$exclusions[$k]
        if ([string]::IsNullOrWhiteSpace($reason) -or $reason.Contains("`n")) {
            $fails.Add("exclusion '$k' needs a one-line reason")
        }
        $excl[(Norm $k)] = $true
    }
    $need = New-Object System.Collections.Generic.List[string]
    foreach ($n in $names) { $need.Add($n) }
    foreach ($n in $fixedAll) { $need.Add($n) }
    if ($arch -eq 'arm64') { foreach ($n in $fixedArm64) { $need.Add($n) } }
    foreach ($n in ($need | Sort-Object -Unique)) {
        $key = Norm $n
        if ($sections.ContainsKey($key)) { continue }
        # Toolchain and microsoft/terminal entries are never excludable.
        if ($excl.ContainsKey($key) -and ($fixedAll -notcontains $n) -and ($fixedArm64 -notcontains $n)) { continue }
        $fails.Add("no '== $n ==' section and no exclusion")
    }
    return $fails.ToArray()
}

# ---- self test ----------------------------------------------------------------

function Invoke-SelfTest {
    function Expect([string]$what, [bool]$ok) {
        if ($ok) { Write-Host "  ok   $what" } else { Write-Host "  FAIL $what"; $script:bad++ }
    }
    $script:bad = 0
    $fa = @('zig', 'microsoft/terminal')
    $f64 = @('libc++', 'winpthreads')
    $full = "== zig ==`n== microsoft/terminal ==`n== libc++ ==`n== winpthreads ==`n== harfbuzz ==`n== some-pkg ==`n"
    $ex = @{ 'gtk4_layer_shell' = 'Linux only' }

    $r = @(Get-CoverageFailures @('harfbuzz', 'some_pkg') $full 'arm64' $ex $fa $f64)
    Expect 'sections present (arm64): no failures' ($r.Count -eq 0)

    $r = @(Get-CoverageFailures @('harfbuzz', 'gtk4_layer_shell') $full 'x64' $ex $fa $f64)
    Expect 'exclusion with a reason: no failures' ($r.Count -eq 0)

    $r = @(Get-CoverageFailures @('harfbuzz', 'freetype') $full 'x64' $ex $fa $f64)
    Expect 'missing name: fails and names it' ($r.Count -eq 1 -and $r[0] -match 'freetype')

    $noLibcxx = $full.Replace("== libc++ ==`n", '')
    $r = @(Get-CoverageFailures @('harfbuzz') $noLibcxx 'arm64' $ex $fa $f64)
    Expect 'missing arm64 toolchain entry: fails for arm64' ($r.Count -eq 1 -and $r[0] -match 'libc\+\+')
    $r = @(Get-CoverageFailures @('harfbuzz') $noLibcxx 'x64' $ex $fa $f64)
    Expect 'missing arm64 toolchain entry: passes for x64' ($r.Count -eq 0)

    $noMs = $full.Replace("== microsoft/terminal ==`n", '')
    $r = @(Get-CoverageFailures @('harfbuzz') $noMs 'x64' $ex $fa $f64)
    Expect 'missing microsoft/terminal: fails' ($r.Count -eq 1 -and $r[0] -match 'microsoft/terminal')

    $r = @(Get-CoverageFailures @('harfbuzz') $full 'x64' @{ 'gtk4_layer_shell' = '' } $fa $f64)
    Expect 'exclusion without a reason: fails' ($r.Count -eq 1 -and $r[0] -match 'reason')

    $noZig = $full.Replace("== zig ==`n", '')
    $r = @(Get-CoverageFailures @('harfbuzz') $noZig 'x64' @{ 'zig' = 'excluded?' } $fa $f64)
    Expect 'toolchain entry cannot be excluded' ($r.Count -eq 1 -and $r[0] -match "'== zig =='")

    $zon = @'
.{
    .name = .x,
    // a comment with .fake = .{ .path = "no" }
    .dependencies = .{
        .a = .{ .url = "https://example.org/a.tar.gz", .hash = "a-0.1-XYZ", .lazy = true },
        // .b = .{ .path = "./b" },
        .@"c-d" = .{
            .path = "./pkg/c-d", // trailing
            .lazy = true,
        },
        .e = .{ .path = "../e" },
    },
    .paths = .{ "" },
}
'@
    $d = @(Get-ZonDeps $zon)
    Expect 'zon: three entries, comments skipped' ($d.Count -eq 3 -and $d[0].Name -eq 'a' -and $d[1].Name -eq 'c-d' -and $d[2].Name -eq 'e')
    Expect 'zon: hash, path' ($d[0].Hash -eq 'a-0.1-XYZ' -and $d[1].Path -eq './pkg/c-d' -and $d[2].Path -eq '../e')

    if ($script:bad -ne 0) { Write-Host "third-party-check: self-test FAIL ($($script:bad))"; exit 1 }
    Write-Host 'third-party-check: self-test OK'
    exit 0
}

if ($SelfTest) { Invoke-SelfTest }

# ---- main -----------------------------------------------------------------------

if (-not $RepoRoot) { Write-Host 'third-party-check: FAIL -RepoRoot is required'; exit 1 }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not $Notices) { $Notices = Join-Path $RepoRoot 'dist\windows\THIRD_PARTY_NOTICES.txt' }
if (-not (Test-Path -LiteralPath $Notices -PathType Leaf)) {
    Write-Host 'third-party-check: FAIL THIRD_PARTY_NOTICES.txt is missing'
    exit 1
}

# zig-pkg is next to the root zon; a git worktree has none of its own, so fall
# back to the main checkout's.
if (-not $PkgDir) {
    $PkgDir = Join-Path $RepoRoot 'zig-pkg'
    if (-not (Test-Path -LiteralPath $PkgDir -PathType Container)) {
        $common = ''
        try {
            $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $common = [string](& git -C $RepoRoot rev-parse --git-common-dir 2>$null)
            $ErrorActionPreference = $saved
        } catch { $ErrorActionPreference = 'Stop' }
        if ($common) {
            $cp = if ([IO.Path]::IsPathRooted($common)) { $common } else { Join-Path $RepoRoot $common }
            $main = Split-Path -Parent ([IO.Path]::GetFullPath($cp.Trim()))
            $alt = Join-Path $main 'zig-pkg'
            if (Test-Path -LiteralPath $alt -PathType Container) { $PkgDir = $alt }
        }
    }
}
if (-not (Test-Path -LiteralPath $PkgDir -PathType Container)) {
    Write-Host "third-party-check: FAIL no zig-pkg folder (build once so the packages are fetched)"
    exit 1
}

$names = Get-AllNames $RepoRoot $PkgDir
$text = [IO.File]::ReadAllText($Notices, (New-Object System.Text.UTF8Encoding($false)))
$fails = @(Get-CoverageFailures $names $text $Arch $script:Exclusions $script:FixedAll $script:FixedArm64)
if ($fails.Count -gt 0) {
    foreach ($f in $fails) { Write-Host "third-party-check: FAIL $f" }
    exit 1
}
Write-Host "third-party-check: OK ($Arch, $($names.Count) dependency names)"
exit 0
