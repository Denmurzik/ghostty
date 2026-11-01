# e2e: milestone=M8 timeout=240 order=1260
# selection-paste: the selection clipboard is Ghostty's own, in-process (the
# macOS model): with copy-on-select = primary a double-click on a word stores
# it there WITHOUT touching the system clipboard (its sequence number does not
# change), and the default middle-click-action (primary-paste) pastes it.
#  1. copy-on-select = primary: double-click the word SELWORD42 printed by
#     echo; the clipboard sequence number is unchanged; type `echo "<`,
#     middle-click, type `>" > file`, Enter -> the file holds <SELWORD42>.
#  2. copy-on-select = none (the Windows default): the double-click stores
#     nothing, the middle click pastes nothing -> the file holds <>.
# The clipboard is saved first and put back in `finally`.
# Keep this file ASCII only (Windows PowerShell 5.1 reads a BOM-less script as ANSI).
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force

Invoke-E2eScenario 'selection-paste' {
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
        # Prints the word on the first row of a cleared screen.
        function Show-Word($g) {
            Send-Line $g.Hwnd "clear; echo SELWORD42"
            Start-Sleep -Milliseconds 1200
        }
        function Get-Rect($g) {
            $win = @((Get-GhosttyState -Class $g.Class).windows)[0]
            @($win.tabs)[$win.active_tab].surfaces[0].rect
        }
        # Double-click inside the first characters of the first row.
        function Select-Word($g) {
            $rect = Get-Rect $g
            Send-MouseClick -Hwnd $g.Hwnd -X ([int]$rect[0] + 12) -Y ([int]$rect[1] + 10) -Double
            Start-Sleep -Milliseconds 500
        }
        # Middle click in the lower half of the surface (no mouse reporting).
        function Click-Middle($g) {
            $rect = Get-Rect $g
            $x = [int](([int]$rect[0] + [int]$rect[2]) / 2)
            $y = [int]([int]$rect[1] + ([int]$rect[3] - [int]$rect[1]) * 0.7)
            Send-MouseClick -Hwnd $g.Hwnd -X $x -Y $y -Button middle
            Start-Sleep -Milliseconds 500
        }
        # Types `echo "<`, middle-clicks, types `>" > file` and runs it.
        function Invoke-MiddlePaste($g, [string]$Name) {
            $marker = Join-Path $g.Sandbox.Tmp "gt-sp-$Name.txt"
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            Send-Typed $g.Hwnd 'echo "<'
            Start-Sleep -Milliseconds 300
            Click-Middle $g
            Send-Line $g.Hwnd ('>" > "$TEMP/gt-sp-{0}.txt"' -f $Name)
            if (-not (Wait-File $marker 15)) { Save-Evidence "no-file-$Name" $g -Window; throw "'$Name': the command did not run" }
            (Read-ShellFile $marker).Utf8.Trim()
        }

        # 1. copy-on-select = primary: the word reaches the middle click only.
        $g = Start-Case "copy-on-select = primary`n"
        Set-ClipboardText 'sentinel-before'
        Update-ClipboardMark
        $seq = [uint32](Get-ClipboardSequence)
        Show-Word $g
        Select-Word $g
        Save-Evidence 'primary-selected' $g -Window
        if ([uint32](Get-ClipboardSequence) -ne $seq) {
            Update-ClipboardMark
            throw 'primary: the system clipboard changed on select (the selection clipboard must stay in the process)'
        }
        $got = Invoke-MiddlePaste $g 'primary'
        if ($got -ne '<SELWORD42>') { Save-Evidence 'primary-fail' $g -Window; throw "primary: the middle click pasted '$got', expected '<SELWORD42>'" }
        if ([uint32](Get-ClipboardSequence) -ne $seq) {
            Update-ClipboardMark
            throw 'primary: the system clipboard changed after the middle click'
        }
        Write-E2eInfo 'copy-on-select = primary: double-click stored the word, middle click pasted it, clipboard untouched'
        Stop-Case $g

        # 2. copy-on-select = none (default): nothing stored, nothing pasted.
        $g = Start-Case "copy-on-select = none`n"
        Show-Word $g
        Select-Word $g
        $got = Invoke-MiddlePaste $g 'none'
        if ($got -ne '<>') { Save-Evidence 'none-fail' $g -Window; throw "none: the middle click pasted '$got', expected nothing" }
        Write-E2eInfo 'copy-on-select = none: the middle click pasted nothing'
        Stop-Case $g
    } finally {
        Restore-ClipboardText $saved
    }
}
