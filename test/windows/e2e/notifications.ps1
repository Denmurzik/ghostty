# e2e: milestone=M3 timeout=120 order=600
# notifications: in test mode the toast layer only records. OSC 9 and OSC 777
# notices and the notice for a finished command (OSC 133 C/D) reach the
# recorded list; `desktop-notifications = false` silences them. The real toast
# is the owner's manual check.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

function Get-Recorded($G) { @((Get-GhosttyState -Class $G.Class).m3.notify.recorded) }

function Wait-Recorded($G, [int]$Count, [string]$What) {
    $ok = Wait-Until -TimeoutSec 10 -PollMs 150 -Condition { @(Get-Recorded $G).Count -ge $Count }
    if (-not $ok) {
        throw "$What : expected $Count recorded notice(s), state: $((Get-GhosttyState -Class $G.Class).m3.notify | ConvertTo-Json -Compress -Depth 6)"
    }
}

Invoke-E2eScenario 'notifications' {
    $cfg = (Get-Content -LiteralPath (Get-ConfigPath 'gitbash-de') -Raw -Encoding UTF8) +
        "`nnotify-on-command-finish = always`nnotify-on-command-finish-after = 0s`nnotify-on-command-finish-action = no-bell,notify`n"
    $g = Start-E2eGhostty -ConfigText $cfg
    Wait-BashReady $g

    if (@(Get-Recorded $g).Count -ne 0) { throw 'notices recorded before anything was sent' }

    # OSC 9: the toast carries the app name as its title.
    Send-Line $g.Hwnd "printf '\e]9;hello & <you>\e\'"
    Wait-Recorded $g 1 'OSC 9'
    $n = (Get-Recorded $g)[0]
    if ($n.title -ne 'Ghostty') { throw "OSC 9 title is '$($n.title)', expected 'Ghostty'" }
    if ($n.body -ne 'hello & <you>') { throw "OSC 9 body is '$($n.body)', expected 'hello & <you>'" }

    # OSC 777;notify: title and body as given (core limits one notice a second).
    Start-Sleep -Seconds 2
    Send-Line $g.Hwnd "printf '\e]777;notify;Build;done\e\'"
    Wait-Recorded $g 2 'OSC 777'
    $n = (Get-Recorded $g)[1]
    if ($n.title -ne 'Build' -or $n.body -ne 'done') { throw "OSC 777 notice is '$($n.title)' / '$($n.body)', expected 'Build' / 'done'" }

    # A command that finished: OSC 133 C, a second, OSC 133 D;0 sent by the case itself.
    Start-Sleep -Seconds 2
    Send-Line $g.Hwnd "printf '\e]133;C\a'; sleep 1; printf '\e]133;D;0\a'"
    Wait-Recorded $g 3 'command_finished'
    $n = (Get-Recorded $g)[2]
    if ($n.title -ne 'Command Succeeded') { throw "command_finished title is '$($n.title)', expected 'Command Succeeded'" }
    if ($n.body -notlike 'Command took *and exited with code 0.') { throw "command_finished body is '$($n.body)'" }

    # desktop-notifications = false: nothing more is recorded.
    $path = Join-Path $script:Sbx.Home '.config\ghostty\config.ghostty'
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    [IO.File]::WriteAllText($path, $text + "`ndesktop-notifications = false`n", (New-Object Text.UTF8Encoding $false))
    Invoke-GhosttyAction -Class $g.Class -Action 'reload_config' | Out-Null
    Start-Sleep -Seconds 2
    Send-Line $g.Hwnd "printf '\e]9;silenced\e\'"
    Start-Sleep -Seconds 2
    $after = Get-Recorded $g
    if (@($after).Count -ne 3) { throw "a notice was recorded with desktop-notifications = false: $($after | ConvertTo-Json -Compress)" }
}
