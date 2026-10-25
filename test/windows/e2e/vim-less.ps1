# vim-less: full-screen programs work: `less` pages a file and `q` returns
# to the prompt; vim takes typed text (i, text, Esc) and writes it out.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'vim-less' {
    $g = Start-BashE2e
    $tmp = $g.Sandbox.Tmp

    # less: the line after it only runs once less has quit. (The process
    # tree of an MSYS shell does not reliably show less.exe/vim.exe, so the
    # scenario goes by the screen and by the files the commands leave.)
    $lessDone = Join-Path $tmp 'gt-less.txt'
    Send-Line $g.Hwnd 'less /etc/profile; echo less-done > "$TEMP/gt-less.txt"'
    Start-Sleep -Milliseconds 2500
    if (Test-Path $lessDone) { throw 'less returned to the prompt on its own' }
    $d = Wait-Dump $g {
        param($d) [GhosttyE2e.Win]::CountNotNear($d.Bytes, 54, $d.Width, $d.Height, 0x10, 0x20, 0x30, 2) -gt 3000
    } 10
    if (-not $d) { throw 'the dump shows no pager text while less runs' }
    Save-Evidence 'less' $g -Window
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'q'
    if (-not (Wait-File $lessDone 10)) { throw 'q did not quit less (the command after it never ran)' }

    # vim
    $out = Join-Path $tmp 'gt-vim.txt'
    $outVim = $out.Replace('\', '/').Replace(' ', '\ ')
    Send-Line $g.Hwnd 'vim'
    Start-Sleep -Milliseconds 3500
    # Real key presses: in a full-screen program the layout-independent
    # text path (typing-unicode-vim) is not what is under test here.
    Invoke-SendInput -Hwnd $g.Hwnd -Keys (@('i') + (ConvertTo-KeyList 'vim-ok') + @('esc'))
    Start-Sleep -Milliseconds 600
    Save-Evidence 'vim' $g -Window
    Invoke-SendInput -Hwnd $g.Hwnd -Keys ((ConvertTo-KeyList ":wq! $outVim") + 'enter')
    if (-not (Wait-File $out 15)) { throw "vim did not write $out" }
    $text = (Get-Content -LiteralPath $out -Raw).Trim()
    if ($text -ne 'vim-ok') { throw "vim wrote '$text', expected 'vim-ok'" }
    # vim is gone and the shell is back.
    Send-Line $g.Hwnd 'echo vim-done > "$TEMP/gt-vim-done.txt"'
    if (-not (Wait-File (Join-Path $tmp 'gt-vim-done.txt') 10)) { throw 'the shell did not come back after :wq!' }
}
