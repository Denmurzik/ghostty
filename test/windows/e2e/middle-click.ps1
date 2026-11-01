# e2e: milestone=M8 timeout=300 order=1261
# middle-click: what a middle click does in Git Bash for each
# middle-click-action. The system clipboard holds `mc-paste`.
#  - clipboard-paste: the click pastes the system clipboard (`mc-paste`).
#  - primary-paste (the default) with the default copy-on-select: the
#    selection clipboard is empty, so nothing is pasted (as in win.2).
#  - ignore: nothing is pasted.
#  - mouse reporting (printf '\e[?1000h'): the app receives the middle button
#    (SGR press ESC [ < 1 ;) and nothing is pasted.
#  - a middle click on a tab chip still closes that tab.
# The clipboard is saved first and put back in `finally`.
# Keep this file ASCII only (Windows PowerShell 5.1 reads a BOM-less script as ANSI).
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force

Invoke-E2eScenario 'middle-click' {
    $saved = Save-ClipboardText
    try {
        function Start-Case([string]$Extra) {
            $g = Start-BashE2e -ExtraConfig $Extra
            $global:E2eLast = $g
            if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
            $g
        }
        function Stop-Case($g) {
            [void](Invoke-GhosttyAction -Class $g.Class -Action 'close_window')
            if (-not (Wait-ProcessExit $g 8).Exited) { throw 'ghostty did not exit after close_window' }
        }
        function Click-Middle($g) {
            $win = @((Get-GhosttyState -Class $g.Class).windows)[0]
            $rect = @($win.tabs)[$win.active_tab].surfaces[0].rect
            $x = [int](([int]$rect[0] + [int]$rect[2]) / 2)
            $y = [int]([int]$rect[1] + ([int]$rect[3] - [int]$rect[1]) * 0.7)
            Send-MouseClick -Hwnd $g.Hwnd -X $x -Y $y -Button middle
            Start-Sleep -Milliseconds 500
        }
        # Types `cat > file`, middle-clicks, types `end` + Enter and ends the
        # input with Ctrl+D (at an empty line): the file holds what the click
        # pasted in front of `end`, or just `end` when nothing was pasted.
        function Invoke-CatPaste($g, [string]$Name) {
            $marker = Join-Path $g.Sandbox.Tmp "gt-mc-$Name.txt"
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            Send-Line $g.Hwnd ('cat > "$TEMP/gt-mc-{0}.txt"' -f $Name)
            Start-Sleep -Milliseconds 700
            Click-Middle $g
            Send-Line $g.Hwnd 'end'
            Start-Sleep -Milliseconds 300
            Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+d'
            Start-Sleep -Milliseconds 300
            if (-not (Wait-File $marker 10)) { Save-Evidence "no-file-$Name" $g -Window; throw "'$Name': cat wrote nothing" }
            (Read-ShellFile $marker).Utf8
        }

        # 1. clipboard-paste pastes the system clipboard.
        $g = Start-Case "middle-click-action = clipboard-paste`n"
        Set-ClipboardText 'mc-paste'
        $got = Invoke-CatPaste $g 'cb'
        if ($got -notmatch 'mc-paste') { Save-Evidence 'cb-fail' $g -Window; throw "clipboard-paste: the file holds '$got', expected mc-paste" }
        Stop-Case $g

        # 2. primary-paste (default) with the default copy-on-select: nothing.
        $g = Start-Case ''
        Set-ClipboardText 'mc-paste'
        $got = Invoke-CatPaste $g 'primary'
        if ($got -match 'mc-paste') { Save-Evidence 'primary-fail' $g -Window; throw 'primary-paste pasted the system clipboard' }
        Stop-Case $g

        # 3. ignore: nothing.
        $g = Start-Case "middle-click-action = ignore`n"
        Set-ClipboardText 'mc-paste'
        $got = Invoke-CatPaste $g 'ignore'
        if ($got -match 'mc-paste') { Save-Evidence 'ignore-fail' $g -Window; throw 'ignore pasted the system clipboard' }
        Stop-Case $g

        # 4. Mouse reporting: the app gets the middle button, nothing is pasted.
        $g = Start-Case "middle-click-action = clipboard-paste`n"
        Set-ClipboardText 'mc-paste'
        $probe = Join-Path $g.Sandbox.Tmp 'gt-mc-mouse.txt'
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        Send-Line $g.Hwnd "printf '\033[?1000h\033[?1006h'; stty raw -echo; head -c 5 > `"`$TEMP/gt-mc-mouse.txt`"; stty sane; printf '\033[?1000l'"
        Start-Sleep -Milliseconds 1200
        Click-Middle $g
        if (-not (Wait-File $probe 10)) { Save-Evidence 'mouse' $g -Window; throw 'the mouse app received nothing' }
        $r = Read-ShellFile $probe
        if ($r.Utf8 -ne "$([char]27)[<1;") { throw "the app got '$($r.Hex)', expected the SGR middle press ESC [ < 1 ;" }
        Stop-Case $g

        # 5. A middle click on a tab chip still closes that tab.
        $g = Start-Case "confirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = always`n"
        function Get-Win { @((Get-GhosttyState -Class $g.Class).windows)[0] }
        $w = Get-Win
        $c = $w.strip.new_tab
        Send-MouseClick -Hwnd $g.Hwnd -X ([int](($c[0] + $c[2]) / 2)) -Y ([int](($c[1] + $c[3]) / 2))
        if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { @((Get-Win).tabs).Count -eq 2 })) { throw 'the new tab button did not add a tab' }
        $w = Get-Win
        $r = @($w.strip.tabs)[1]
        Send-MouseClick -Hwnd $g.Hwnd -X ([int](($r[0] + $r[2]) / 2)) -Y ([int](($r[1] + $r[3]) / 2)) -Button middle
        if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { @((Get-Win).tabs).Count -eq 1 })) {
            Save-Evidence 'tab-chip' $g -Window
            throw 'a middle click on a tab chip did not close the tab'
        }
        Stop-Case $g
    } finally {
        Restore-ClipboardText $saved
    }
}
