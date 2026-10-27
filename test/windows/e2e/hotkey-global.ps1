# e2e: milestone=M3 timeout=120 order=540
# hotkey-global: `global:ctrl+alt+shift+f9=new_window` is a system-wide hotkey;
# with a window of another program in the foreground the chord opens a second
# Ghostty window.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms

Invoke-E2eScenario 'hotkey-global' {
    $cfg = (Get-Content -LiteralPath (Get-ConfigPath 'gitbash-de') -Raw -Encoding UTF8) + "`nkeybind = global:ctrl+alt+shift+f9=new_window`n"
    $g = Start-E2eGhostty -ConfigText $cfg
    Wait-BashReady $g

    $form = New-Object Windows.Forms.Form
    $form.Text = 'ghostty-e2e-foreign'
    try {
        $form.Show()
        [Windows.Forms.Application]::DoEvents()
        if (-not (Set-ForegroundSafe -Hwnd $form.Handle)) { throw 'E2E-SKIP: could not take the foreground' }

        if (@(Get-GhosttyWindows $g).Count -ne 1) { throw 'expected one Ghostty window before the chord' }
        Invoke-SendInput -Hwnd $form.Handle -Keys 'ctrl+alt+shift+f9'
        $ok = Wait-Until -TimeoutSec 1.5 -PollMs 50 -Condition { @(Get-GhosttyWindows $g).Count -ge 2 }
        if (-not $ok) { throw "the chord did not open a window; hotkeys: $((Get-GhosttyState -Class $g.Class).hotkeys | ConvertTo-Json -Compress)" }
    } finally {
        $form.Close()
        $form.Dispose()
    }
}
