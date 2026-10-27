<#
.SYNOPSIS
Screenshot checks of the terminal emulation: each case prints its escape
sequences in a fresh ghostty.exe and the frame dump is compared with a
reference PNG.

.DESCRIPTION
test/windows/vt-smoke/cases/<case>.sh are bash scripts that print their
sequences with printf, touch $VTS_DONE and `exec sleep 600`. Their second
line is the header

    # vts: requires=<task|none> extra-config=<k=v;k=v>

`requires` names the task or decision that makes the case meaningful (T5, T7,
T15, L1 ...). A case with a requirement SKIPs until its reference PNG exists
(the lead generates it after the prerequisite landed: -Only <case> -Update).
`@FIXTURES@` in a case is replaced by the cases directory.

Per case: a sandbox with its own config (class ghostty-vts-<hex>, font-size
12, window 100x30 cells, no cursor blink, the embedded font, command =
Git Bash running the case), wait until the shell touched $VTS_DONE and the
frame dump is stable (two equal dumps 300 ms apart), convert the dump to a PNG
and compare it with vt-smoke/ref/<case>@<dpi>.png (<dpi> is the DPI of the window: 96 at 100 %,
168 at 175 %; a case without a reference for the current DPI SKIPs; Compare-Image, tolerance 24,
99.5 % of the pixels). The references depend on the display scale and the
driver: generate and compare with the same -Driver (warp by default, it is
deterministic across machines at the same scale).

Exit code: 0 all compared cases PASS (SKIPs allowed), 1 any FAIL, 2 nothing ran
(desktop locked or busy).

.PARAMETER Only
Case names to run (comma separated).

.PARAMETER Update
Writes the reference PNGs instead of comparing. Without -Only only cases with
requires=none are written. The lead inspects every changed PNG before commit.

.PARAMETER Driver
warp (default, GHOSTTY_D3D11_DRIVER=warp) or hardware.

.PARAMETER EvidenceDir
Where actual PNGs (failures: actual and diff) are copied.

.EXAMPLE
powershell -NoProfile -File test/windows/vt-smoke.ps1 -Only sgr-16 -Update
#>
param(
    [string[]]$Only,
    [switch]$Update,
    [ValidateSet('warp', 'hardware')][string]$Driver = 'warp',
    [string]$EvidenceDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'e2e\_common.ps1')
Import-Module (Join-Path $PSScriptRoot 'lib\ImageCompare.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\GhosttyIpc.psm1') -Force

$vtsDir = Join-Path $PSScriptRoot 'vt-smoke'
$casesDir = Join-Path $vtsDir 'cases'
$refDir = Join-Path $vtsDir 'ref'
$fixtures = ((Resolve-Path -LiteralPath $casesDir).Path -replace '\\', '/')

# `powershell -File` hands over `a,b` as one string.
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if (-not $EvidenceDir) { $EvidenceDir = $env:GHOSTTY_E2E_EVIDENCE }
if ($EvidenceDir) {
    New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
    $env:GHOSTTY_E2E_EVIDENCE = (Resolve-Path -LiteralPath $EvidenceDir).Path
}

$cases = @(Get-ChildItem -LiteralPath $casesDir -Filter '*.sh' | Sort-Object Name | ForEach-Object { $_.BaseName })
$unknown = @($Only | Where-Object { $cases -notcontains $_ })
if ($unknown.Count) { throw "unknown case(s): $($unknown -join ', ')" }
if ($Only.Count) { $cases = @($cases | Where-Object { $Only -contains $_ }) }

# The header of a case: requires and the extra config lines.
function Read-VtsCase([string]$Name) {
    $text = [IO.File]::ReadAllText((Join-Path $casesDir "$Name.sh"), (New-Object Text.UTF8Encoding $false))
    $text = ($text -replace "`r`n", "`n").Replace('@FIXTURES@', $fixtures)
    $requires = $null
    $extra = ''
    foreach ($l in ($text -split "`n" | Select-Object -First 10)) {
        if ($l -match '^#\s*vts:\s*requires=(\S+)\s*(?:extra-config=(.*))?$') {
            $requires = $Matches[1]
            if ($Matches.Count -gt 2 -and $Matches[2]) { $extra = $Matches[2].Trim() }
            break
        }
    }
    if (-not $requires) { throw "case $Name has no '# vts: requires=.. extra-config=..' header" }
    [pscustomobject]@{
        Name     = $Name
        Requires = $requires
        Extra    = @($extra -split ';' | Where-Object { $_ })
        Text     = $text
    }
}

# Two equal dumps 300 ms apart (the frame is at rest), or $null.
function Wait-StableDump($G, [double]$TimeoutSec = 20) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $prev = $null
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (Test-Path -LiteralPath $G.Dump) {
            $d = Read-Dump $G.Dump
            if ($d -and $d.Width -gt 100 -and $d.Height -gt 100) {
                if ($prev -and $prev.Bytes.Length -eq $d.Bytes.Length) {
                    $same = $true
                    $a = $prev.Bytes; $b = $d.Bytes
                    for ($i = 54; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { $same = $false; break } }
                    if ($same) { return $d }
                }
                $prev = $d
            }
        }
        Start-Sleep -Milliseconds 300
    }
    $null
}

# The DPI the window runs at (state document of the test IPC), read once per run.
function Get-VtsDpi($G) {
    if ($script:VtsDpi) { return $script:VtsDpi }
    $w = Wait-Until -TimeoutSec 10 -PollMs 200 -Condition {
        $d = Get-GhosttyState -Class $G.Class
        $x = @($d.windows)[0]
        if ($x -and $x.dpi) { $x }
    }
    if (-not $w) { throw 'cannot read the window dpi from the state document' }
    $script:VtsDpi = [int]$w.dpi
    $script:VtsDpi
}

function Invoke-VtsCase($Case, [string]$Bash) {
    $name = $Case.Name
    if ($Update -and $Case.Requires -ne 'none' -and $Only.Count -eq 0) { return "SKIP $name`: requires $($Case.Requires), not written without -Only" }

    $sbx = $script:Sbx
    $script = Join-Path $sbx.Tmp "$name.sh"
    [IO.File]::WriteAllText($script, $Case.Text, (New-Object Text.UTF8Encoding $false))
    $done = Join-Path $sbx.Tmp "$name.done"
    Remove-Item -LiteralPath $done -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sbx.Dump -Recurse -Force -ErrorAction SilentlyContinue

    $lines = @(
        'font-size = 12'
        'window-width = 100'
        'window-height = 30'
        'cursor-style-blink = false'
        'confirm-close-surface = false'
        'env = LC_ALL=en_US.UTF-8'
        'env = LANG=en_US.UTF-8'
        ('env = VTS_DONE={0}' -f ($done -replace '\\', '/'))
        ('command = direct:"{0}" --noprofile --norc "{1}"' -f $Bash, ($script -replace '\\', '/'))
    ) + $Case.Extra
    $envVars = @{}
    if ($Driver -eq 'warp') { $envVars['GHOSTTY_D3D11_DRIVER'] = 'warp' }

    $g = Start-E2eGhostty -ConfigText (($lines -join "`n") + "`n") -ClassPrefix 'ghostty-vts' -Env $envVars
    try {
        # The references are keyed by the DPI of the window: ref/<case>@<dpi>.png.
        $dpi = Get-VtsDpi $g
        $ref = Join-Path $refDir "$name@$dpi.png"
        if (-not $Update -and -not (Test-Path -LiteralPath $ref)) { return "SKIP $name`: no reference for $dpi dpi" }
        $ok = Wait-File $done 25
        if (-not $ok) { Save-Evidence "$name-stuck" $g -Window; Save-Log; return "FAIL $name`: the case script did not finish within 25 s" }
        # ConPTY and the renderer lag behind the script.
        Start-Sleep -Milliseconds 700
        $d = Wait-StableDump $g 20
        if (-not $d) { return "FAIL $name`: no stable frame dump within 20 s" }

        $actual = Join-Path $sbx.Tmp "$name.png"
        Save-DumpPng $d $actual
        if ($EvidenceDir) { Copy-Item -LiteralPath $actual -Destination (Join-Path $EvidenceDir "vts-$name.png") -Force }
        if ($Update) {
            New-Item -ItemType Directory -Force -Path $refDir | Out-Null
            Copy-Item -LiteralPath $actual -Destination $ref -Force
            return "PASS $name`: reference written ($($d.Width)x$($d.Height))"
        }
        try {
            $r = Compare-Image -Actual $actual -Reference $ref -DiffPng (Join-Path $sbx.Tmp "$name.diff.png")
        } catch {
            return "FAIL $name`: $($_.Exception.Message)"
        }
        $stats = 'match {0:P2}, max diff {1}, mean diff {2:N3}' -f $r.Match, $r.MaxDiff, $r.MeanDiff
        if ($r.DiffPng) {
            if ($EvidenceDir) { Copy-Item -LiteralPath $r.DiffPng -Destination (Join-Path $EvidenceDir "vts-$name.diff.png") -Force }
            return "FAIL $name`: $stats"
        }
        "PASS $name`: $stats"
    } finally {
        # One window at a time: the next case must not see this one's dump.
        $p = $g.Process
        Stop-OwnGhostty
        try { [void]$p.WaitForExit(5000) } catch { }
    }
}

$bash = Find-GitBash
if (-not $bash) { Write-Output 'SKIP vt-smoke: Git Bash is not installed'; exit 2 }

$script:VtsDpi = $null
$global:VtsFailed = @()
$global:VtsCases = $cases
$global:VtsRun = ${function:Invoke-VtsCase}
$global:VtsBash = $bash
$global:VtsReader = ${function:Read-VtsCase}
$result = @(Invoke-E2eScenario 'vt-smoke' {
    foreach ($name in $global:VtsCases) {
        $case = & $global:VtsReader $name
        $line = [string](@(& $global:VtsRun $case $global:VtsBash) | Select-Object -Last 1)
        Write-E2eInfo $line
        if ($line -like 'FAIL*') { $global:VtsFailed += $name }
    }
    if ($global:VtsFailed.Count) { throw "failed: $($global:VtsFailed -join ', ')" }
})
$last = [string]($result | Select-Object -Last 1)
Write-Output $last
if ($last -like 'FAIL*') { exit 1 }
if ($last -like 'SKIP*') { exit 2 }
exit 0
