# e2e: milestone=M3 timeout=240 order=650
# pwd-osc7: the working directory a shell reports with OSC 7 reaches the
# surface (IPC state `pwd`, a Windows path) in Git Bash, pwsh and cmd, and a
# new tab / split starts in it (Git Bash).
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'pwd-osc7' {
    $dir = Join-Path $script:Sbx.Tmp 'pwd dir #1 Проект'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    function Get-FocusedPwd($G) {
        $d = Get-GhosttyState -Class $G.Class
        $w = @($d.windows)[0]
        foreach ($t in @($w.tabs)) {
            foreach ($s in @($t.surfaces)) { if ($s.focused) { return [string]$s.pwd } }
        }
        ''
    }
    function Wait-Pwd($G, [string]$Want, [string]$What, [double]$TimeoutSec = 12) {
        $ok = Wait-Until -TimeoutSec $TimeoutSec -PollMs 150 -Condition { (Get-FocusedPwd $G) -ieq $Want }
        if (-not $ok) { throw "$What : pwd is '$(Get-FocusedPwd $G)', expected '$Want'" }
    }

    # --- Git Bash: cd, then a new tab and a split start there ---
    $g = Start-BashE2e
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
    Send-Line $g.Hwnd 'cd "$TEMP/pwd dir #1 Проект"'
    Wait-Pwd $g $dir 'git bash cd'
    Save-Evidence -Tag 'pwd-osc7-bash' -G $g -Window

    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
    Wait-Pwd $g $dir 'new tab inherits the directory'
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_split:right')
    Wait-Pwd $g $dir 'split inherits the directory'
    Stop-OwnGhostty

    # --- pwsh ---
    if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
        $g = Start-E2eGhostty -ConfigText "command = direct:pwsh.exe -NoLogo`nconfirm-close-surface = false`n"
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        if (-not (Wait-ChildNamed $g @('pwsh.exe') 20)) { throw 'pwsh did not start' }
        Start-Sleep -Seconds 2
        Send-Line $g.Hwnd "Set-Location -LiteralPath '$dir'"
        Wait-Pwd $g $dir 'pwsh Set-Location'
        Stop-OwnGhostty
    } else {
        Write-E2eInfo 'pwsh not found; pwsh case skipped'
    }

    # --- cmd ---
    $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'cmd')
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
    if (-not (Wait-ChildNamed $g @('cmd.exe') 20)) { throw 'cmd did not start' }
    Start-Sleep -Seconds 1
    Send-Line $g.Hwnd "cd /d `"$dir`""
    Wait-Pwd $g $dir 'cmd cd'
    Save-Evidence -Tag 'pwd-osc7-cmd' -G $g -Window
}
