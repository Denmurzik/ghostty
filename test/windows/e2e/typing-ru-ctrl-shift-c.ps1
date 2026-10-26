# e2e: milestone=M1 timeout=150 order=70
# typing-ru-ctrl-shift-c: on the Russian layout the keys of the Latin
# shortcuts type Cyrillic letters, and Ctrl+Shift+A / Ctrl+Shift+C must
# still match (core falls back to the physical key). Select all, copy, and
# the clipboard holds the screen text. The clipboard text is saved and put
# back; a clipboard with non-text formats SKIPs the scenario.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'typing-ru-ctrl-shift-c' {
    $saved = Save-ClipboardText
    try {
        $g = Start-BashE2e
        $marker = 'gt-copy-marker-7421'
        Send-Line $g.Hwnd "echo $marker"
        Start-Sleep -Milliseconds 1500
        Set-ClipboardText 'gt-clipboard-before'

        # Cyrillic letters on the A and C keys of the Russian layout,
        # resolved by send-input through the Unicode VkKeyScanExW.
        $a = ConvertFrom-CodePoints 0x444
        $c = ConvertFrom-CodePoints 0x441
        Set-WindowLayout $g.Hwnd '00000419'
        Invoke-SendInput -Hwnd $g.Hwnd -Keys "ctrl+shift+$a"
        Invoke-SendInput -Hwnd $g.Hwnd -Keys "ctrl+shift+$c"

        $last = @{ Text = $null }
        $got = Wait-Until -TimeoutSec 8 -PollMs 200 -Condition {
            $t = Invoke-ClipboardRetry { if ([System.Windows.Forms.Clipboard]::ContainsText()) { [System.Windows.Forms.Clipboard]::GetText() } }
            $last.Text = $t
            if ($t -and $t.Contains($marker)) { $t }
        }
        Save-Evidence 'copied' $g -Window
        if (-not $got) { throw "Ctrl+Shift+C on the Russian layout did not copy the selection; clipboard holds '$($last.Text)'" }
        Write-E2eInfo "RU layout Ctrl+Shift+A, Ctrl+Shift+C copied the screen text ($($got.Length) chars)"
    } finally {
        Restore-ClipboardText $saved
    }
}
