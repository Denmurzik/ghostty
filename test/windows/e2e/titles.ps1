# e2e: milestone=M2 timeout=180 order=330
# titles: window and tab titles behave like Ghostty for macOS. Git Bash
# (shell integration injected) shows the working directory while idle and the
# command while it runs; the window caption follows the active tab; cmd shows
# its working directory and never the ConPTY image path; PowerShell shows the
# working directory and the command. Needs the shell integration scripts in
# zig-out\share\ghostty (zig build installs them).
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

$script:WM_CLOSE = 0x10
function Close-Window($G) {
    [void][GhosttyE2e.Win]::PostMessageW($G.Hwnd, $script:WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Get-TitleWin($G) {
    $r = Get-GhosttyState -Class $G.Class
    $d = if ($r.PSObject.Properties['data']) { $r.data } else { $r }
    @($d.windows)[0]
}
function Wait-TabTitle($G, [int]$Index, [scriptblock]$Predicate, [string]$What, [double]$TimeoutSec = 15) {
    $t = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
        $w = Get-TitleWin $G
        if ($w -and @($w.tabs).Count -gt $Index) {
            $title = [string]@($w.tabs)[$Index].title
            if (& $Predicate $title) { $title }
        }
    }
    if (-not $t) {
        $now = Get-TitleWin $G | ConvertTo-Json -Depth 8 -Compress
        throw "timeout waiting for: $What; state: $now"
    }
    $t
}
function Wait-Caption($G, [scriptblock]$Predicate, [string]$What) {
    $t = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition {
        $c = [GhosttyE2e.Win]::TextOf($G.Hwnd)
        if (& $Predicate $c) { $c }
    }
    if (-not $t) { throw "caption '$([GhosttyE2e.Win]::TextOf($G.Hwnd))', want: $What" }
    $t
}

Invoke-E2eScenario 'titles' {
    # 1. Git Bash: the working directory while idle, the command while it runs.
    $g = Start-BashE2e
    [void](Wait-TabTitle $g 0 { param($t) $t -eq '~' } 'idle title ~')
    [void](Wait-Caption $g { param($c) $c -eq '~' } '~')
    Send-Line $g.Hwnd 'sleep 4'
    [void](Wait-TabTitle $g 0 { param($t) $t -eq 'sleep 4' } 'title of the running command')
    [void](Wait-Caption $g { param($c) $c -eq 'sleep 4' } 'sleep 4')
    [void](Wait-TabTitle $g 0 { param($t) $t -eq '~' } 'idle title again' 10)

    # 2. The caption follows the active tab.
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
    [void](Wait-TabTitle $g 1 { param($t) $t -eq '~' } 'second tab idle title')
    Send-Line $g.Hwnd 'cd /tmp'
    [void](Wait-TabTitle $g 1 { param($t) $t -eq '/tmp' } 'second tab cd /tmp')
    [void](Wait-Caption $g { param($c) $c -eq '/tmp' } '/tmp')
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'goto_tab:1')
    [void](Wait-Caption $g { param($c) $c -eq '~' } '~ after goto_tab:1')
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'goto_tab:2')
    [void](Wait-Caption $g { param($c) $c -eq '/tmp' } '/tmp after goto_tab:2')
    Save-Evidence -Tag 'titles-bash' -G $g -Window
    Close-Window $g
    [void](Wait-ProcessExit $g 8)

    # 3. cmd: the working directory, never the image path.
    $g = Start-E2eGhostty -ConfigText "command = direct:cmd.exe`nconfirm-close-surface = false`n"
    $t = Wait-TabTitle $g 0 { param($t) $t -like '*\*' -or $t -like '?:*' } 'cmd shows its working directory'
    if ($t -match '(?i)cmd\.exe') { throw "cmd title is the image path: '$t'" }
    # cmd's running-command title: its own "<image> - <command>" title must
    # arrive as the bare command, never "<cwd> - <command>" or the image path.
    Send-Line $g.Hwnd 'ping -n 6 127.0.0.1 > nul'
    $seen = New-Object System.Collections.Generic.List[string]
    $running = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition {
        $w = Get-TitleWin $g
        $title = [string]@($w.tabs)[0].title
        if ($seen.Count -eq 0 -or $seen[$seen.Count - 1] -ne $title) { $seen.Add($title) }
        if ($title -match 'ping') { $title }
    }
    Write-E2eInfo "cmd titles seen: $($seen -join ' | ')"
    if (-not $running) { throw "cmd never showed the running command; titles: $($seen -join ' | ')" }
    if ($running -match '(?i)cmd\.exe| - ') { throw "cmd running title is not the bare command: '$running'" }
    Save-Evidence -Tag 'titles-cmd' -G $g -Window
    Close-Window $g
    [void](Wait-ProcessExit $g 8)

    # 4. PowerShell 7: the working directory and the command.
    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $pwsh) {
        $g = Start-E2eGhostty -ConfigText "command = direct:`"$pwsh`" -NoLogo -NoProfile`nconfirm-close-surface = false`n"
        [void](Wait-TabTitle $g 0 { param($t) $t -eq '~' } 'pwsh idle title ~' 20)
        Send-Line $g.Hwnd 'Start-Sleep 4'
        [void](Wait-TabTitle $g 0 { param($t) $t -eq 'Start-Sleep 4' } 'pwsh command title')
        [void](Wait-TabTitle $g 0 { param($t) $t -eq '~' } 'pwsh idle title again' 10)
        Save-Evidence -Tag 'titles-pwsh' -G $g -Window
        Close-Window $g
        [void](Wait-ProcessExit $g 8)
    }
}
