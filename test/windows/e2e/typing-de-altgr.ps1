# typing-de-altgr: on the German layout AltGr+Q is @ (and AltGr gives the
# other third-level characters); the fake Ctrl that Windows sends with AltGr
# must not turn them into control characters.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'typing-de-altgr' {
    $g = Start-BashE2e
    # @ (AltGr+Q), [ ] { } \ ~ | and the euro sign (AltGr+E), which is
    # outside the ANSI code page and needs the Unicode VkKeyScanExW lookup.
    $payload = '@[]{}\~|' + (ConvertFrom-CodePoints 0x20AC)
    $path = Invoke-PayloadCase $g 'gt-altgr.txt' {
        Set-WindowLayout $g.Hwnd '00000407'
        Invoke-SendInput -Hwnd $g.Hwnd -Keys ($payload.ToCharArray() | ForEach-Object { [string]$_ })
    }
    Assert-ShellText $path $payload 'DE AltGr'
}
