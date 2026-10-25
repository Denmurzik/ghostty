# typing-unicode-vim: characters sent as VK_PACKET (SendInput unicode, touch
# keyboard, remote desktop, automation tools) reach a full-screen program in
# the order they were typed and act as key presses (the `i` of `ivim-ok`
# starts insert mode). vim turns on bracketed paste, so text that Ghostty
# delivers as a paste (one per character) is inserted reversed instead.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'typing-unicode-vim' {
    $g = Start-BashE2e
    $out = Join-Path $g.Sandbox.Tmp 'gt-vim-packet.txt'
    $outVim = $out.Replace('\', '/').Replace(' ', '\ ')

    Send-Line $g.Hwnd 'vim'
    Start-Sleep -Milliseconds 3500
    # The `i` that starts insert mode and the text after it, all VK_PACKET;
    # then Esc and the ex command as real keys.
    Invoke-SendInput -Hwnd $g.Hwnd -Text 'ivim-ok'
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'esc'
    Start-Sleep -Milliseconds 600
    Save-Evidence 'vim' $g -Window
    Invoke-SendInput -Hwnd $g.Hwnd -Keys ((ConvertTo-KeyList ":wq! $outVim") + 'enter')
    if (-not (Wait-File $out 15)) { throw "vim did not write $out" }
    $text = (Get-Content -LiteralPath $out -Raw).Trim()
    if ($text -ne 'vim-ok') { throw "VK_PACKET text 'vim-ok' reached vim as '$text'" }
}
