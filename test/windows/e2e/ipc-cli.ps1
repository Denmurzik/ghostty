# e2e: milestone=M2 timeout=90 order=340
# ipc-cli: `ghostty.exe +new-window --class=<class>` opens a window in the
# running instance and exits 0; an unknown class fails and names the class.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

function Invoke-Cli([string[]]$CliArgs) {
    $so = Join-Path $script:Sbx.Tmp ('cli-out-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    $se = $so + '.err'
    $p = Start-Process -FilePath $script:Exe -ArgumentList $CliArgs -WorkingDirectory $script:Root `
        -PassThru -NoNewWindow -RedirectStandardOutput $so -RedirectStandardError $se
    if (-not $p.WaitForExit(15000)) { try { $p.Kill() } catch {}; throw "ghostty $($CliArgs -join ' ') did not exit within 15 s" }
    [pscustomobject]@{
        Code   = $p.ExitCode
        Stdout = (Get-Content -LiteralPath $so -Raw -ErrorAction SilentlyContinue)
        Stderr = (Get-Content -LiteralPath $se -Raw -ErrorAction SilentlyContinue)
    }
}

Invoke-E2eScenario 'ipc-cli' {
    $a = Start-E2eGhostty
    $class = $a.Class
    [void](Wait-GhosttyState -Class $class -TimeoutSec 15 -Predicate { @($_.windows).Count -eq 1 })

    $r = Invoke-Cli @('+new-window', "--class=$class")
    if ($r.Code -ne 0) { throw "+new-window exited with $($r.Code): $($r.Stderr)" }
    [void](Wait-GhosttyState -Class $class -TimeoutSec 10 -Predicate { @($_.windows).Count -eq 2 })

    $missing = 'ghostty-e2e-none' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $r = Invoke-Cli @('+new-window', "--class=$missing")
    if ($r.Code -eq 0) { throw '+new-window to an unknown class exited 0' }
    if ("$($r.Stderr)" -notlike "*$missing*") { throw "stderr does not name the class '$missing': $($r.Stderr)" }
    $s = Get-GhosttyState -Class $class
    if (@($s.windows).Count -ne 2) { throw 'the running instance changed on a request for another class' }
}
