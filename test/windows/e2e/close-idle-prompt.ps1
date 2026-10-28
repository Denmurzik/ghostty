# e2e: milestone=M5 timeout=120 order=425
# close-idle-prompt: with `confirm-close-surface = true`, closing a window
# whose shell sits at an idle prompt (OSC 133 marks from the shell
# integration) asks nothing: no GhosttyDialog, Ghostty exits. Cases: Git Bash,
# cmd (idle closes unasked, a running `ping -t` asks), and Git Bash whose rc
# file runs `exec zsh` (zsh gets the zsh integration).
# The headless counterpart is test/windows/shell-marks/run.ps1.
# PENDING: written without a GUI run (task #53); first run in the M5 Task 19
# e2e pass.
# Keep this file ASCII only.
. (Join-Path $PSScriptRoot '_common.ps1')

$script:WM_CLOSE = 0x10

function Get-ConfirmText {
    (Get-Content -LiteralPath (Get-ConfigPath 'gitbash-de') -Raw -Encoding UTF8) -replace 'confirm-close-surface = false', 'confirm-close-surface = true'
}

# WM_CLOSE at the prompt: Ghostty exits and no confirmation dialog shows up.
function Assert-ClosesUnasked($G, [string]$What) {
    Start-Sleep -Milliseconds 1500
    [void][GhosttyE2e.Win]::PostMessageW($G.Hwnd, $script:WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    $exit = Wait-ProcessExit $G 5
    if (-not $exit.Exited) {
        $dlg = @([GhosttyE2e.Win]::TopLevel([uint32]$G.Pid, 'GhosttyDialog')).Count
        throw "$What : ghostty still running 5 s after WM_CLOSE at an idle prompt ($dlg confirmation dialog(s))"
    }
    Write-E2eInfo "$What closed unasked in $($exit.Ms) ms"
}

Invoke-E2eScenario 'close-idle-prompt' {
    # 1. Git Bash at its prompt.
    $g = Start-E2eGhostty -ConfigText (Get-ConfirmText)
    Wait-BashReady $g
    Assert-ClosesUnasked $g 'git bash'

    # 2. cmd: its idle prompt closes unasked; with `ping -t` running (cmd marks
    # no command start, Ghostty looks at the shell's children) it asks, and
    # "Close" (id 100) closes.
    $cmdCfg = (Get-ConfirmText).TrimEnd() + "`ncommand = direct:$env:SystemRoot\System32\cmd.exe`n"
    $g = Start-E2eGhostty -ConfigText $cmdCfg
    Start-Sleep -Seconds 2
    Assert-ClosesUnasked $g 'cmd'

    $g = Start-E2eGhostty -ConfigText $cmdCfg
    Start-Sleep -Seconds 2
    Set-WindowLayout $g.Hwnd '00000409'
    Send-Line $g.Hwnd 'ping -t 127.0.0.1'
    if (-not (Wait-ChildNamed $g @('ping.exe') 15)) { throw 'cmd: ping.exe never started' }
    Start-Sleep -Milliseconds 500
    [void][GhosttyE2e.Win]::PostMessageW($g.Hwnd, $script:WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    $dlg = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition {
        @([GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyDialog')) | Select-Object -First 1
    }
    if (-not $dlg) { throw 'cmd: no confirmation dialog within 8 s while ping -t runs' }
    [void][GhosttyE2e.Win]::PostMessageW($dlg, 0x466, [IntPtr]100, [IntPtr]::Zero)   # TDM_CLICK_BUTTON, Close
    $exit = Wait-ProcessExit $g 5
    if (-not $exit.Exited) { throw 'cmd: ghostty still running 5 s after Close' }

    # 3. A bash rc file that ends in `exec zsh`.
    $bash = Find-GitBash
    $zsh = if ($bash) { Join-Path (Split-Path (Split-Path $bash)) 'usr\bin\zsh.exe' }
    if (-not $zsh -or -not (Test-Path -LiteralPath $zsh)) { throw 'E2E-SKIP: no zsh next to Git Bash' }
    $rc = Join-Path ([IO.Path]::GetTempPath()) "ghostty-e2e-exec-zsh-$PID.bashrc"
    # The sandbox HOME has no .zshrc: zsh would show its new-user menu instead
    # of a prompt.
    [IO.File]::WriteAllText($rc, "[ -f ~/.zshrc ] || echo `"PROMPT='zsh%% '`" > ~/.zshrc`nif [ -t 1 ]; then exec zsh; fi`n")
    try {
        $cfg = (Get-ConfirmText).TrimEnd() + "`ncommand = direct:`"$bash`" --rcfile $($rc -replace '\\', '/')`n"
        $g = Start-E2eGhostty -ConfigText $cfg
        if (-not (Wait-ChildNamed $g @('zsh.exe') 20)) { throw 'zsh.exe never started from the bash rc file' }
        Start-Sleep -Seconds 2
        Assert-ClosesUnasked $g 'bash exec zsh'
    } finally {
        Remove-Item -LiteralPath $rc -ErrorAction SilentlyContinue
    }
}
