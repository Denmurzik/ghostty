# e2e: milestone=M5 timeout=150 order=980
# crash-dump: a deliberate access violation and a stack overflow (the test op
# `crash`) each end the process within 15 s with exactly one new .dmp in
# <LOCALAPPDATA>\ghostty\crash (0 < size < 64 MB), no WerFault for the pid,
# the log line `crash dump written to`, and `+crash-report` listing the dump.
# A marker echoed into the pty before the crash is not in the dump bytes
# (MiniDumpFilterMemory). The dumps are deleted at the end.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

$script:Marker = 'M5SECRETMARK'

function Test-HasBytes([byte[]]$Haystack, [byte[]]$Needle) {
    if ($Needle.Length -eq 0 -or $Haystack.Length -lt $Needle.Length) { return $false }
    $first = $Needle[0]
    $i = [Array]::IndexOf($Haystack, $first, 0)
    while ($i -ge 0 -and $i -le $Haystack.Length - $Needle.Length) {
        $match = $true
        for ($j = 1; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) { $match = $false; break }
        }
        if ($match) { return $true }
        if ($i + 1 -ge $Haystack.Length) { break }
        $i = [Array]::IndexOf($Haystack, $first, $i + 1)
    }
    $false
}

function Invoke-CrashCase([string]$Kind) {
    $g = Start-E2eGhostty -Env @{ XDG_STATE_HOME = $null }
    Wait-BashReady $g
    $crashDir = Join-Path $g.Sandbox.Local 'ghostty\crash'
    $before = @(Get-ChildItem -LiteralPath $crashDir -Filter *.dmp -ErrorAction SilentlyContinue)

    [void](Invoke-GhosttyAction -Class $g.Class -Action "text:echo $script:Marker\r")
    Start-Sleep -Milliseconds 1200

    $pidText = " $($g.Pid) "
    $wer = $null
    try {
        [void](Invoke-GhosttyIpc -Class $g.Class -Request @{ op = 'crash'; text = $Kind } -TimeoutMs 3000)
    } catch {
        # The pipe dies with the process: expected.
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $g.Process.HasExited -and $sw.Elapsed.TotalSeconds -lt 15) {
        $w = Get-CimInstance Win32_Process -Filter "Name='WerFault.exe'" -ErrorAction SilentlyContinue |
            Where-Object { (" " + $_.CommandLine + " ") -match "\s-p\s+$($g.Pid)\s" }
        if ($w) { $wer = $w }
        Start-Sleep -Milliseconds 100
    }
    if (-not $g.Process.HasExited) { throw "$Kind : still running 15 s after the crash" }
    Write-E2eInfo ("$Kind : exited in {0} ms, code 0x{1:x}" -f $sw.ElapsedMilliseconds, $g.Process.ExitCode)
    # WER may start a moment after the exit.
    Start-Sleep -Milliseconds 1500
    $w = Get-CimInstance Win32_Process -Filter "Name='WerFault.exe'" -ErrorAction SilentlyContinue |
        Where-Object { (" " + $_.CommandLine + " ") -match "\s-p\s+$($g.Pid)\s" }
    if ($w -or $wer) { throw "$Kind : WerFault.exe was started for pid $($g.Pid)" }

    $after = @(Get-ChildItem -LiteralPath $crashDir -Filter *.dmp -ErrorAction SilentlyContinue)
    $new = @($after | Where-Object { @($before | ForEach-Object Name) -notcontains $_.Name })
    if ($new.Count -ne 1) { throw "$Kind : expected exactly one new .dmp in $crashDir, found $($new.Count)" }
    $dmp = $new[0]
    if ($dmp.Length -le 0 -or $dmp.Length -ge 64MB) { throw "$Kind : dump size $($dmp.Length) is out of range" }
    if ($dmp.Name -notmatch "^ghostty-$($g.Pid)-\d+\.dmp$") { throw "$Kind : unexpected dump name $($dmp.Name)" }
    Write-E2eInfo ("$Kind : dump {0} bytes" -f $dmp.Length)

    if (-not (Test-Path -LiteralPath $g.Log)) { throw "$Kind : no log file" }
    $logText = Get-Content -LiteralPath $g.Log -Raw -Encoding UTF8
    if ($logText -notmatch [regex]::Escape('crash dump written to')) { throw "$Kind : the log has no 'crash dump written to' line" }

    # +crash-report with the sandbox env lists the dump.
    $psi = [Diagnostics.ProcessStartInfo]::new($script:Exe)
    $psi.Arguments = '+crash-report'
    $psi.WorkingDirectory = $script:Root
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $g.Sandbox.Local
    $psi.EnvironmentVariables['APPDATA'] = $g.Sandbox.Roaming
    $psi.EnvironmentVariables['USERPROFILE'] = $g.Sandbox.Home
    [void]$psi.EnvironmentVariables.Remove('GHOSTTY_WIN32_TEST_IPC')
    [void]$psi.EnvironmentVariables.Remove('XDG_STATE_HOME')
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    [void]$p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(20000)) { try { $p.Kill() } catch {}; throw "$Kind : +crash-report did not exit" }
    if ($out.Result -notmatch [regex]::Escape($dmp.Name)) { throw "$Kind : +crash-report does not list $($dmp.Name):`n$($out.Result)" }

    # The pty marker must not be in the dump (ASCII or UTF-16LE).
    $bytes = [IO.File]::ReadAllBytes($dmp.FullName)
    if (Test-HasBytes $bytes ([Text.Encoding]::ASCII.GetBytes($script:Marker))) { throw "$Kind : the marker is in the dump (ASCII)" }
    if (Test-HasBytes $bytes ([Text.Encoding]::Unicode.GetBytes($script:Marker))) { throw "$Kind : the marker is in the dump (UTF-16)" }

    Remove-Item -LiteralPath $dmp.FullName -Force
}

Invoke-E2eScenario 'crash-dump' {
    try {
        Invoke-CrashCase 'av'
        Invoke-CrashCase 'stack'
    } finally {
        Get-ChildItem -LiteralPath (Join-Path $script:Sbx.Local 'ghostty\crash') -Filter *.dmp -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}
