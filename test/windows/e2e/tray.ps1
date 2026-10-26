# e2e: milestone=M2 timeout=180 order=430
# tray: with the Windows default (quit-after-last-window-closed = false) the
# state reports tray.visible; closing the last window leaves the process
# running with no window; the tray callback (NIN_SELECT) and the New Window
# menu command open windows; Quit from the menu exits the process; a launch
# with other arguments is its own process without a tray icon.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

$script:WM_CLOSE = 0x10
$script:WM_COMMAND = 0x111
$script:WM_GHOSTTY_TRAY = 0x8000 + 9
$script:NIN_SELECT = 0x400
$script:MenuNewWindow = 1
$script:MenuQuit = 2

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

function Get-TrayWindow([int]$ProcessId) {
    @([GhosttyE2e.Win]::TopLevel([uint32]$ProcessId, 'GhosttyTray')) | Select-Object -First 1
}

Invoke-E2eScenario 'tray' {
    $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'gitbash-de') -KeepDefaultQuit
    Wait-BashReady $g
    $class = $g.Class

    function Get-State { Get-GhosttyState -Class $class }
    function Wait-WindowCount([int]$Count, [double]$TimeoutSec, [string]$What) {
        $ok = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition { @((Get-State).windows).Count -eq $Count }
        if (-not $ok) { throw "$What : expected $Count windows, state: $(Get-State | ConvertTo-Json -Depth 6 -Compress)" }
    }

    # 1. The icon is on.
    $s = Get-State
    if (-not $s.tray.visible) { throw "state.tray.visible is false: $($s | ConvertTo-Json -Depth 6 -Compress)" }
    if (-not $s.pipe_owner) { throw 'state.pipe_owner is false' }
    $tray = Get-TrayWindow $g.Pid
    if (-not $tray) { throw 'no GhosttyTray window in the process' }

    # 2. Closing the only window leaves the process running with no window.
    [void][GhosttyE2e.Win]::PostMessageW($g.Hwnd, $script:WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    Wait-WindowCount 0 5 'after closing the last window'
    Start-Sleep -Seconds 3
    $g.Process.Refresh()
    if ($g.Process.HasExited) { throw "ghostty exited with code $($g.Process.ExitCode) after its last window closed" }
    if (-not (Get-State).tray.visible) { throw 'the tray icon is gone with no window' }

    # 3. A click on the icon (NIN_SELECT) opens a window.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [void][GhosttyE2e.Win]::PostMessageW($tray, $script:WM_GHOSTTY_TRAY, [IntPtr]::Zero, [IntPtr]$script:NIN_SELECT)
    Wait-WindowCount 1 2 'NIN_SELECT with no window'
    Write-E2eInfo "window after the tray click in $($sw.ElapsedMilliseconds) ms"

    # 4. A click with a window present only presents it (still one window).
    [void][GhosttyE2e.Win]::PostMessageW($tray, $script:WM_GHOSTTY_TRAY, [IntPtr]::Zero, [IntPtr]$script:NIN_SELECT)
    Start-Sleep -Milliseconds 500
    Wait-WindowCount 1 2 'NIN_SELECT with a window'

    # 5. New Window from the menu, with a window present.
    [void][GhosttyE2e.Win]::PostMessageW($tray, $script:WM_COMMAND, [IntPtr]$script:MenuNewWindow, [IntPtr]::Zero)
    Wait-WindowCount 2 2 'menu New Window'

    # 6. A second launch of the same class forwards: a third window.
    $b = Start-Launch $class @()
    if (-not $b.WaitForExit(2000)) { throw 'the second launch was still running after 2 s' }
    Wait-WindowCount 3 5 'forwarded launch'

    # 7. A launch with other arguments is its own process, with no icon.
    $c = Start-Launch $class @('--font-size=20')
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Find-GhosttyWindows $c.Id) -and $deadline.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 50 }
    if (Get-TrayWindow $c.Id) { throw 'the standalone process has a GhosttyTray window' }
    $c.Refresh()
    if ($c.HasExited) { throw '--font-size launch exited instead of running on its own' }
    [void]$c.CloseMainWindow()
    if (-not $c.WaitForExit(3000)) { throw 'the standalone process did not end with its window' }

    # 8. Quit from the menu: idle shells need no confirmation.
    $sw.Restart()
    [void][GhosttyE2e.Win]::PostMessageW($tray, $script:WM_COMMAND, [IntPtr]$script:MenuQuit, [IntPtr]::Zero)
    $exit = Wait-ProcessExit $g 5
    if (-not $exit.Exited) { throw 'Quit from the tray menu did not end the process within 5 s' }
    if ($sw.ElapsedMilliseconds -gt 3000) { throw "Quit took $($sw.ElapsedMilliseconds) ms (limit 3000 ms)" }
}
