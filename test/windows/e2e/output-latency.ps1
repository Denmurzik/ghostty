# output-latency: (c) pty read -> present for output that nobody typed:
# `while :; do date +%s%N; sleep 0.1; done`, 200 lines.
# e2e: milestone=M2 timeout=300 order=152
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_latency.ps1')

Invoke-E2eScenario 'output-latency' {
    $g = Start-LatencyGhostty 'output-latency'
    $cursor = Enter-LatencyInput $g
    try {
        $since = Get-NowNs
        Send-Line $g.Hwnd 'while :; do date +%s%N; sleep 0.1; done'
        $deadline = (Get-Date).AddSeconds(60)
        $samples = @()
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 1000
            $rows = @(Get-LatencyRows)
            $samples = @(Get-Samples $rows 'output' $since $null | Where-Object { $_.OutputBytes -ge 10 })
            if ($samples.Count -ge 200) { break }
        }
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+c'
        if ($samples.Count -eq 0) { throw 'no output line was traced' }
        if ($samples.Count -lt 100) { Write-E2eInfo "WARN only $($samples.Count) of 200 output lines closed a sample" }
        $samples = @($samples | Select-Object -First 200)
        $null = Publish-Latency 'output-idle' $samples
    } finally {
        Exit-LatencyInput $cursor
    }
}
