# e2e: milestone=M8 timeout=90 order=1270
# title-inject: Git for Windows' default prompt titles the window with a raw
# $PWD. A directory whose name holds BEL and ESC (MSYS allows that) would end
# that title early and run an OSC 52 clipboard write. With the bash
# integration stripping the control bytes, cd into such a directory leaves the
# clipboard alone (GetClipboardSequenceNumber is unchanged, the clipboard text
# is still ours) and the window title shows no control pictures. Interactive
# desktop only; the clipboard is saved first and restored after.
# Keep this file ASCII only (Windows PowerShell 5.1 reads a BOM-less script as ANSI).
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'title-inject' {
    $saved = Save-ClipboardText
    try {
        $g = Start-BashE2e
        if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
        $done = Join-Path $g.Sandbox.Tmp 'gt-ti.txt'
        Remove-Item -LiteralPath $done -Force -ErrorAction SilentlyContinue

        # A marker on the clipboard: an injected OSC 52 ('Hello') would replace it.
        $marker = 'ghostty-e2e-title-inject-marker'
        Set-ClipboardText $marker
        $seq = [uint32](Get-ClipboardSequence)

        # The crafted directory is made by the scenario, under the sandbox TEMP.
        Send-Line $g.Hwnd 'mkdir -p "$TEMP/ti" && cd "$TEMP/ti"'
        Start-Sleep -Milliseconds 400
        Send-Line $g.Hwnd "mkdir `$'inj\a\e]52;c;SGVsbG8=\a' && cd `$'inj\a\e]52;c;SGVsbG8=\a' && echo ok > `"`$TEMP/gt-ti.txt`""
        if (-not (Wait-File $done 20)) { Save-Evidence 'fail' $g -Window; throw 'the shell did not get into the crafted directory' }
        # Let the next prompt (and its title) arrive.
        Start-Sleep -Milliseconds 1500
        Save-Evidence 'crafted-dir' $g -Window

        if ([uint32](Get-ClipboardSequence) -ne $seq) {
            throw 'the clipboard changed after cd into the crafted directory (an OSC 52 got through)'
        }
        $now = [System.Windows.Forms.Clipboard]::GetText()
        if ($now -ne $marker) { throw "the clipboard text is '$now', expected the marker" }

        $title = [GhosttyE2e.Win]::TextOf($g.Hwnd)
        Write-E2eInfo "window title: $title"
        foreach ($c in $title.ToCharArray()) {
            if ([int]$c -ge 0x2400 -and [int]$c -le 0x243F) { throw 'the window title holds a control picture' }
            if ([int]$c -lt 0x20 -or [int]$c -eq 0x7F) { throw 'the window title holds a control character' }
        }
    } finally {
        Restore-ClipboardText $saved
    }
}
