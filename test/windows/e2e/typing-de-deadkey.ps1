# e2e: milestone=M1 timeout=150 order=50
# typing-de-deadkey: on the German layout the ^ key (scancode 0x29) followed
# by e gives e-circumflex, the acute key (0x0D) followed by e gives
# e-acute, and the dead key followed by space is the bare accent.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'typing-de-deadkey' {
    $g = Start-BashE2e
    $payload = (ConvertFrom-CodePoints 0xEA, 0xE9) + '^'
    $path = Invoke-PayloadCase $g 'gt-dead.txt' {
        Set-WindowLayout $g.Hwnd '00000407'
        # One call: the dead key state must survive between the key presses.
        # 0x12 = E, 0x39 = Space.
        Invoke-SendInput -Hwnd $g.Hwnd -Scancodes '0x29', '0x12', '0x0D', '0x12', '0x29', '0x39'
    }
    Assert-ShellText $path $payload 'DE dead keys'
}
