# typing-ru: real key presses on the Russian layout produce Cyrillic text.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'typing-ru' {
    $g = Start-BashE2e
    $payload = ConvertFrom-CodePoints 0x43F, 0x440, 0x438, 0x432, 0x435, 0x442
    $path = Invoke-PayloadCase $g 'gt-ru.txt' {
        Set-WindowLayout $g.Hwnd '00000419'
        # Hardware scancodes of G H B D T N: the layout turns them into
        # the letters. (send-input -Keys cannot resolve Cyrillic characters,
        # see typing-de-altgr.)
        Invoke-SendInput -Hwnd $g.Hwnd -Scancodes '0x22', '0x23', '0x30', '0x20', '0x14', '0x31'
    }
    Assert-ShellText $path $payload 'RU layout'
}
