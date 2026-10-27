# e2e: milestone=M3 timeout=90 order=620
# config-errors: a config with an unknown key opens the "Configuration
# errors" task dialog (#32770 of the pid) that lists the line; "Ignore"
# closes it; after the file is fixed, "Reload configuration" shows no dialog.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

$script:TDM_CLICK_BUTTON = 0x466
$script:IdReload = 100
$script:IdIgnore = 2

Invoke-E2eScenario 'config-errors' {
    $g = Start-E2eGhostty -ConfigText ($script:BaseConfig + "`nfont-sise = 3`n")

    function Get-Errors {
        $d = Get-GhosttyState -Class $g.Class
        $d.m3.config_errors
    }
    function Get-Dialogs { @([GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, '#32770')) }
    function Send-DialogButton($Dlg, [int]$Id) {
        [void][GhosttyE2e.Win]::PostMessageW($Dlg, $script:TDM_CLICK_BUTTON, [IntPtr]$Id, [IntPtr]::Zero)
    }

    $dlg = Wait-Until -TimeoutSec 10 -PollMs 100 -Condition { Get-Dialogs | Select-Object -First 1 }
    if (-not $dlg) { throw 'no config errors dialog (#32770) within 10 s' }
    $title = [GhosttyE2e.Win]::TextOf($dlg)
    if ($title -ne 'Configuration errors') { throw "dialog title is '$title'" }
    $e = Get-Errors
    if ($e.open -ne $true) { throw "state.m3.config_errors.open is $($e.open)" }
    if ($e.text -notmatch 'font-sise') { throw "the dialog text does not list font-sise: '$($e.text)'" }
    Save-Evidence 'config-errors' $g -Window -Hwnd $dlg

    Send-DialogButton $dlg $script:IdIgnore
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { -not [GhosttyE2e.Win]::IsWindow($dlg) })) { throw 'Ignore did not close the dialog' }
    if ((Get-Errors).choice -ne 'ignore') { throw "choice is '$((Get-Errors).choice)', expected ignore" }
    $shown = (Get-Errors).shown

    # Fix the sandbox config only, then reload from a second dialog.
    $path = Join-Path $g.Sandbox.Home '.config\ghostty\config.ghostty'
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $bad = $text -replace '(?m)^font-sise = 3\r?\n?', ''
    if ($bad -eq $text) { throw "sandbox config has no font-sise line: $path" }

    # A reload with the error still there brings the dialog back ...
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'reload_config')
    $dlg = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { Get-Dialogs | Select-Object -First 1 }
    if (-not $dlg) { throw 'reload_config with the error still in the file showed no dialog' }

    # ... and fixing the file, then pressing "Reload configuration" leaves none.
    [IO.File]::WriteAllText($path, $bad, (New-Object Text.UTF8Encoding $false))
    Send-DialogButton $dlg $script:IdReload
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { -not [GhosttyE2e.Win]::IsWindow($dlg) })) { throw 'Reload did not close the dialog' }
    Start-Sleep -Milliseconds 1000
    if ((Get-Dialogs).Count -ne 0) { throw 'a dialog is up after the fixed config was reloaded' }
    $e = Get-Errors
    if ($e.choice -ne 'reload') { throw "choice is '$($e.choice)', expected reload" }
    if ($e.shown -ne $shown + 1) { throw "dialog shown $($e.shown) times, expected $($shown + 1)" }
}
