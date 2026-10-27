# input-latency: (a) key echo at an idle bash prompt, 200 keys 120 ms apart.
# Measures keypress -> present of the echo and the stage split; only records
# and gates it (Task 37): Ghostty-owned p95 <= 6 ms; the whole path p95 <= 16 ms
# when measured with cmd.exe (GHOSTTY_LAT_SHELL=cmd). With Git Bash the whole
# path is the bash stage plus the Ghostty stages and is recorded, not gated.
# e2e: milestone=M2 timeout=300 order=150
# Options (standalone: powershell -File input-latency.ps1 -ExtraConfig "font-size = 14" -Splits 2; under the
# runner: GHOSTTY_LAT_EXTRA_CONFIG / GHOSTTY_LAT_SPLITS): -ExtraConfig appends config lines (`;` separates
# lines), -Splits N types into the focused one of N panes. Rows measured with either are feature rows, not
# the baseline: name them with GHOSTTY_LAT_BUILD_VARIANT.
param(
    [string]$ExtraConfig = $env:GHOSTTY_LAT_EXTRA_CONFIG,
    [int]$Splits = $(if ($env:GHOSTTY_LAT_SPLITS) { [int]$env:GHOSTTY_LAT_SPLITS } else { 1 })
)
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_latency.ps1')

$global:LatExtra = (@($ExtraConfig -split ';' | Where-Object { $_ }) -join "`n")
$global:LatSplits = $Splits

Invoke-E2eScenario 'input-latency' {
    $g = Start-LatencyGhostty 'input-latency' -ExtraConfig $global:LatExtra -Splits $global:LatSplits
    $cursor = Enter-LatencyInput $g
    try {
        # Letters only: every key echoes one character.
        $keys = @(for ($i = 0; $i -lt 200; $i++) { [string][char](97 + ($i % 26)) })
        $since = Get-NowNs
        $stamps = Send-TimedKeys $g $keys 120
        $after = Get-AfterStamps
        Start-Sleep -Milliseconds 600
        $rows = @(Get-LatencyRows)
        $all = @($rows | Where-Object { $_.Kind -eq 'key' -and $_.T0 -ge $since })
        $samples = @(Get-Samples $rows 'key' $since $stamps $after)
        $incomplete = @($all | Where-Object { -not $_.Complete }).Count
        Write-E2eInfo "key samples: $($all.Count) rows, $($samples.Count) complete, $incomplete incomplete"
        # A build whose output does not wake the renderer closes few samples:
        # that is a measurement, recorded as it is.
        if ($samples.Count -eq 0) { throw 'no key echo was traced' }
        if ($samples.Count -lt 100) { Write-E2eInfo "WARN only $($samples.Count) of 200 key echoes closed a sample" }
        $stats = Publish-Latency 'key-echo' $samples
        Assert-LatencyGate $stats $samples 'key-echo owned' 'ghostty_owned' 6 20
        if ($env:GHOSTTY_LAT_SHELL -eq 'cmd') {
            Assert-LatencyGate $stats $samples 'key-echo total (cmd)' 'total' 16 50
        }
        $withRepaint = @($samples | Where-Object { $_.PresentsBetween -gt 0 }).Count
        Write-E2eInfo "samples with a keypress repaint before the echo: $withRepaint"
    } finally {
        Exit-LatencyInput $cursor
        try { Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+c' } catch { }
    }
}
