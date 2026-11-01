# e2e: milestone=M8 timeout=180 order=1252
# kitty-paste-event: with DECSET ?5522 on, Ctrl+Shift+V does not paste text:
# the terminal sends the program one paste event, a read response that lists
# the clipboard's MIME types and carries a one-time password. A native
# vtreader (bundled console under `auto`) sends ESC [ ? 5522 h and waits; the
# clipboard holds text and a 16x16 DIB. The reply is
# type=read:status=OK:pw=..., the listing (text/plain, image/png), DONE; no
# bracketed-paste bytes, no dialog. The clipboard is saved and restored.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_kitty5522.ps1')

Invoke-E2eScenario 'kitty-paste-event' {
    $saved = Save-ClipboardText
    try {
        $tmp = $script:Sbx.Tmp
        $u8 = New-Object Text.UTF8Encoding $false

        # The program only turns the mode on (a file query: ESC [ ? 5522 h).
        $q = Join-Path $tmp 'pe.bin'
        [IO.File]::WriteAllBytes($q, $u8.GetBytes($script:Esc + '[?5522h'))
        $cfg = New-KittyConfig -Name 'pe' -QueryFile ($q -replace '\\', '/') -WaitMs 25000 -Extra 'clipboard-read = ask'
        $g = Start-E2eGhostty -ConfigText $cfg
        Start-Sleep -Milliseconds 1500

        Set-ClipSnapshot (New-ClipSnapshot @(
                @{ Format = 13; Bytes = (ConvertTo-UnicodeTextBytes 'pasted text') }
                @{ Format = 8; Bytes = ([GhosttyKitty.Tool]::Dib24(16, 16, 255, 0, 0, $false)) }
            ))

        Set-WindowLayout $g.Hwnd '00000409'
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+shift+v'
        Start-Sleep -Milliseconds 1500
        if (Test-KittyDialogOpen $g) { Save-Evidence 'dialog' $g -Window; throw 'a paste event opened a dialog' }

        # The vtreader waits out its time, then prints what it received.
        if (-not (Wait-File (Join-Path $tmp 'pe.done') 45)) { throw 'the reader never finished' }
        $reply = Read-KittyScreen $g
        $packets = Read-KittyReply $reply.Raw
        Save-Evidence 'event' $g -Window

        $st = Get-KittyStatuses $packets
        if (@($st).Count -ne 3 -or $st[0] -ne 'OK' -or $st[1] -ne 'DATA' -or $st[2] -ne 'DONE') {
            throw "expected one event OK, DATA (listing), DONE; got '$($st -join ',')': $($reply.Raw)"
        }
        $pw = [string]$packets[0].Meta['pw']
        if (-not $pw) { throw "the OK packet has no pw: $($reply.Raw)" }
        foreach ($p in $packets) { if ([string]$p.Meta['pw'] -ne $pw) { throw 'the packets do not all carry the same pw' } }
        $list = Get-KittyData $packets '.'
        if ($null -eq $list) { throw 'no listing in the event' }
        $mimes = ($u8.GetString($list)).Trim() -split ' '
        if ($mimes -notcontains 'text/plain' -or $mimes -notcontains 'image/png') { throw "the listing is '$($mimes -join ' ')', expected text/plain and image/png" }
        if ($reply.Raw.Contains($script:Esc + '[200~') -or $reply.Raw.Contains('pasted text')) { throw 'bracketed paste bytes or the text reached the program' }
        Write-E2eInfo "paste event: OK, listing '$($mimes -join ' ')', DONE, pw present, no bracketed paste"
    } finally {
        Restore-ClipboardText $saved
    }
}
