# e2e: milestone=M8 timeout=120 order=1240
# copy-html: a copy puts the selection on the clipboard as text AND as rich
# text ("HTML Format", copy_to_clipboard = mixed, the default). Git Bash prints
# red text; a drag-select and Ctrl+Shift+C must give CF_UNICODETEXT
# "red plain" and an "HTML Format" fragment with "red" inside a
# `color: #rrggbb` style. With keybind = ctrl+shift+c=copy_to_clipboard:plain
# (config reload) the same copy has no "HTML Format". The clipboard is saved
# and restored.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force

function Get-ClipText {
    $t = $null
    Invoke-ClipboardRetry { $script:__t = [System.Windows.Forms.Clipboard]::GetText() }
    $t = $script:__t
    if ($null -eq $t) { '' } else { $t.TrimEnd("`r", "`n") }
}

function Get-ClipHtml {
    $script:__h = $null
    Invoke-ClipboardRetry {
        if ([System.Windows.Forms.Clipboard]::ContainsData('HTML Format')) {
            $script:__h = [string][System.Windows.Forms.Clipboard]::GetData('HTML Format')
        }
    }
    $script:__h
}

Invoke-E2eScenario 'copy-html' {
    $saved = Save-ClipboardText
    try {
        $g = Start-BashE2e
        $hwnd = $g.Hwnd

        # Red "red", then plain text, on the first row of a cleared screen.
        Send-Line $hwnd "clear; printf '\e[31mred\e[0m plain\n'"
        Start-Sleep -Milliseconds 1200

        function Copy-FirstRow {
            # A sentinel that is neither of the expected texts, plain text only.
            Set-ClipboardText 'sentinel-not-copied'
            # Press near the top-left cell, release far right on the same row:
            # the row is selected up to its last character.
            Send-MouseDrag -Hwnd $hwnd -X 3 -Y 6 -ToX 360 -ToY 6 -Steps 10 -HoldMs 80
            Start-Sleep -Milliseconds 300
            Invoke-SendInput -Hwnd $hwnd -Keys 'ctrl+shift+c'
            $copied = Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { (Get-ClipText) -ne 'sentinel-not-copied' }
            if (-not $copied) { Save-Evidence 'no-copy' $g -Window; throw 'Ctrl+Shift+C did not change the clipboard within 5 s' }
            Update-ClipboardMark
        }

        # 1. Mixed (default): text and HTML.
        Copy-FirstRow
        $text = Get-ClipText
        if ($text -ne 'red plain') { Save-Evidence 'text-fail' $g -Window; throw "CF_UNICODETEXT is '$text', expected 'red plain'" }
        $block = Get-ClipHtml
        if (-not $block) { throw 'no "HTML Format" on the clipboard after a default copy' }
        $m = [regex]::Match($block, '(?s)<!--StartFragment-->(.*)<!--EndFragment-->')
        $frag = if ($m.Success) { $m.Groups[1].Value } else { $block }
        if ($frag -notmatch '(?is)color:\s*#[0-9a-f]{6}[^>]*>\s*red') {
            throw "the HTML fragment has no 'red' inside a color: #rrggbb style: $frag"
        }
        Write-E2eInfo 'default copy: text "red plain" and an HTML fragment with a colored "red"'
        Save-Evidence 'mixed' $g -Window

        # 2. copy_to_clipboard:plain: no HTML.
        $path = Join-Path $script:Sbx.Home '.config\ghostty\config.ghostty'
        $cfg = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $cfg = $cfg.TrimEnd() + "`nkeybind = ctrl+shift+c=copy_to_clipboard:plain`n"
        [IO.File]::WriteAllText($path, $cfg, (New-Object Text.UTF8Encoding $false))
        Invoke-GhosttyAction -Class $g.Class -Action 'reload_config' | Out-Null
        Start-Sleep -Milliseconds 1000

        Copy-FirstRow
        $text = Get-ClipText
        if ($text -ne 'red plain') { throw "after the plain keybind CF_UNICODETEXT is '$text', expected 'red plain'" }
        if (Get-ClipHtml) { throw 'copy_to_clipboard:plain still put an "HTML Format" on the clipboard' }
        Write-E2eInfo 'copy_to_clipboard:plain: text only'
    } finally {
        Restore-ClipboardText $saved
    }
}
