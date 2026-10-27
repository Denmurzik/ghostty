# e2e: milestone=M3 timeout=120 order=545
# toggle-visibility: `global:ctrl+alt+shift+f10=toggle_visibility`. With a
# Ghostty window in the foreground the chord hides every window; the chord
# again shows them and the window that was in front is in the foreground.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms

Invoke-E2eScenario 'toggle-visibility' {
    $cfg = (Get-Content -LiteralPath (Get-ConfigPath 'gitbash-de') -Raw -Encoding UTF8) + "`nkeybind = global:ctrl+alt+shift+f10=toggle_visibility`n"
    $g = Start-E2eGhostty -ConfigText $cfg
    Wait-BashReady $g

    function Visible-Count { @(Get-GhosttyWindows $g).Count }
    function Chord { Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+alt+shift+f10' }

    if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
    if ((Visible-Count) -ne 1) { throw 'expected one visible window at the start' }

    Chord
    if (-not (Wait-Until -TimeoutSec 2 -PollMs 50 -Condition { (Visible-Count) -eq 0 })) { throw 'the chord did not hide the windows' }

    # Hidden: the foreground belongs to someone else, so the chord is sent to the desktop.
    Invoke-SendInput -Hwnd ([GhosttyHarness.Native]::GetForegroundWindow()) -Keys 'ctrl+alt+shift+f10'
    if (-not (Wait-Until -TimeoutSec 2 -PollMs 50 -Condition { (Visible-Count) -eq 1 })) { throw 'the second chord did not show the window' }
    $fg = [GhosttyHarness.Native]::GetForegroundWindow()
    if ($fg -ne $g.Hwnd) { throw "the window is not in the foreground: $(Get-WindowDescription $fg)" }
}
