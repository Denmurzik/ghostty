# e2e: milestone=M2 timeout=180 order=330
# single-instance: a launch with no arguments, or with only --working-directory,
# opens a window in the running instance and exits 0 within 2 s; two launches
# 50 ms apart leave one process with two windows; a launch with other
# arguments, or with windows-single-instance = false, is a separate process.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

# Starts the exe like Start-E2eGhostty does (same sandbox environment, the
# given class) but returns at once, without waiting for a window.
function Start-Launch([string]$Class, [string[]]$LaunchArgs) {
    $sbx = $script:Sbx
    $vars = [ordered]@{
        USERPROFILE            = $sbx.Home
        HOME                   = $sbx.Home
        LOCALAPPDATA           = $sbx.Local
        APPDATA                = $sbx.Roaming
        TEMP                   = $sbx.Tmp
        TMP                    = $sbx.Tmp
        XDG_CONFIG_HOME        = (Join-Path $sbx.Home '.config')
        GHOSTTY_WIN32_TEST_IPC = '1'
    }
    $saved = @{}
    foreach ($n in $vars.Keys) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
    try {
        foreach ($n in $vars.Keys) { [Environment]::SetEnvironmentVariable($n, $vars[$n], 'Process') }
        $proc = Start-Process -FilePath $script:Exe -WorkingDirectory $script:Root -PassThru `
            -ArgumentList (@("--class=$Class") + @($LaunchArgs | Where-Object { $_ }))
    } finally {
        foreach ($n in $vars.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
    }
    $null = $proc.Handle
    Register-OwnGhostty -ProcessId $proc.Id
    $proc
}

function Wait-OwnWindow($Proc, [double]$TimeoutSec = 15) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $Proc.Refresh()
        if ($Proc.HasExited) { throw "process $($Proc.Id) exited early with code $($Proc.ExitCode)" }
        $w = Find-GhosttyWindows $Proc.Id | Select-Object -First 1
        if ($w) { return $w }
        Start-Sleep -Milliseconds 20
    }
    throw "process $($Proc.Id) showed no window within $TimeoutSec s"
}

Invoke-E2eScenario 'single-instance' {
    # 1. A launch with --working-directory forwards.
    $a = Start-BashE2e
    $class = $a.Class
    $dirName = ConvertFrom-CodePoints @(0x420, 0x430, 0x431, 0x43E, 0x447, 0x430, 0x44F, 0x20, 0x43F, 0x430, 0x43F, 0x43A, 0x430)
    $dir = Join-Path $a.Sandbox.Root $dirName
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $b = Start-Launch $class @('"--working-directory=' + $dir + '"')
    if (-not $b.WaitForExit(2000)) { throw 'the second launch was still running after 2 s' }
    $ms = $sw.ElapsedMilliseconds
    if ($b.ExitCode -ne 0) { throw "the second launch exited with code $($b.ExitCode)" }
    Write-E2eInfo "second launch forwarded and exited in $ms ms"

    [void](Wait-GhosttyState -Class $class -TimeoutSec 10 -Predicate { @($_.windows).Count -eq 2 })
    $out = Join-Path $a.Sandbox.Tmp 'gt-si.txt'
    $got = $false
    for ($i = 0; $i -lt 6 -and -not $got; $i++) {
        [void](Invoke-GhosttyAction -Class $class -Action 'text:pwd -W > "$TEMP/gt-si.txt"\r')
        $got = Wait-File $out 4
    }
    if (-not $got) { throw 'gt-si.txt never appeared' }
    Start-Sleep -Milliseconds 300
    $cwd = (Get-Content -LiteralPath $out -Raw -Encoding UTF8).Trim() -replace '/', '\'
    if ($cwd -ne $dir) { throw "the new shell started in '$cwd', expected '$dir'" }

    # 2. Other arguments: a separate process, its window closes it.
    $c = Start-Launch $class @('--font-size=20')
    [void](Wait-OwnWindow $c)
    Start-Sleep -Milliseconds 500
    $c.Refresh()
    if ($c.HasExited) { throw '--font-size launch exited instead of running on its own' }
    $s = Get-GhosttyState -Class $class
    if (@($s.windows).Count -ne 2) { throw "the running instance has $(@($s.windows).Count) windows, expected 2 (the --font-size launch must not have joined it)" }
    $sw.Restart()
    [void]$c.CloseMainWindow()
    if (-not $c.WaitForExit(3000)) { throw 'the --font-size launch did not exit within 3 s of closing its window' }
    Write-E2eInfo "standalone launch ended $($sw.ElapsedMilliseconds) ms after its window closed"

    # 3. Two launches 50 ms apart while nothing runs: one process, two windows.
    $class2 = 'ghostty-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $d1 = Start-Launch $class2 @()
    Start-Sleep -Milliseconds 50
    $d2 = Start-Launch $class2 @()
    Start-Sleep -Seconds 3
    $alive = @($d1, $d2 | Where-Object { $_.Refresh(); -not $_.HasExited })
    if ($alive.Count -ne 1) { throw "expected one surviving process after 3 s, got $($alive.Count)" }
    $gone = @($d1, $d2 | Where-Object { $_.HasExited })[0]
    if ($gone.ExitCode -ne 0) { throw "the forwarding launch exited with code $($gone.ExitCode)" }
    [void](Wait-GhosttyState -Class $class2 -TimeoutSec 10 -Predicate { @($_.windows).Count -eq 2 })

    # 4. windows-single-instance = false: every launch is its own process.
    $f = Start-E2eGhostty -ConfigText 'windows-single-instance = false'
    $g = Start-Launch $f.Class @()
    [void](Wait-OwnWindow $g)
    Start-Sleep -Seconds 1
    $g.Refresh()
    if ($g.HasExited) { throw 'windows-single-instance = false: the second launch exited' }
    $s = Get-GhosttyState -Class $f.Class
    if (@($s.windows).Count -ne 1) { throw "windows-single-instance = false: the first instance has $(@($s.windows).Count) windows, expected 1" }
}
