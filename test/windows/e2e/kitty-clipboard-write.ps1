# e2e: milestone=M8 timeout=520 order=1250
# kitty-clipboard-write: a program writes the clipboard with the Kitty
# clipboard protocol (OSC 5522) and the system clipboard holds every
# representation. A native vtreader (bundled console under `auto`) sends the
# transaction and prints the reply.
#   1. clipboard-write = allow: text/plain "gh-5522", text/html "<b>gh</b>"
#      and a 2x2 image/png. Reply type=write:status=DONE. The clipboard has
#      CF_UNICODETEXT gh-5522, an "HTML Format" block whose fragment is
#      <b>gh</b>, "PNG" byte-identical, and a 2x2 CF_DIBV5 with the same pixels.
#   2. clipboard-write = ask: a GhosttyDialog appears; Enter (the default,
#      Deny) answers status=EPERM and the clipboard sequence number does not
#      change.
#   3a. limit 1 MiB, a 2 MiB write: status=EFBIG (the limit reaches the handler).
#   3. a 70 MiB write: status=EFBIG (core's limit) and no dialog.
# The clipboard is saved and restored.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_kitty5522.ps1')

Invoke-E2eScenario 'kitty-clipboard-write' {
    $saved = Save-ClipboardText
    try {
        $tmp = $script:Sbx.Tmp

        # The 2x2 image: red, green / blue, white (all opaque).
        $bmp = New-Object Drawing.Bitmap 2, 2, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $bmp.SetPixel(0, 0, [Drawing.Color]::FromArgb(255, 255, 0, 0))
        $bmp.SetPixel(1, 0, [Drawing.Color]::FromArgb(255, 0, 255, 0))
        $bmp.SetPixel(0, 1, [Drawing.Color]::FromArgb(255, 0, 0, 255))
        $bmp.SetPixel(1, 1, [Drawing.Color]::FromArgb(255, 255, 255, 255))
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $png = [byte[]]$ms.ToArray()
        $u8 = New-Object Text.UTF8Encoding $false

        function Start-WriteCase([string]$Name, [string]$Policy, [string]$QueryFile, [string]$Until, [int]$WaitMs) {
            $cfg = New-KittyConfig -Name $Name -QueryFile ($QueryFile -replace '\\', '/') -WaitMs $WaitMs -Until $Until -Extra "clipboard-write = $Policy"
            Start-E2eGhostty -ConfigText $cfg
        }
        function Finish-WriteCase($G, [string]$Name, [double]$TimeoutSec) {
            # Ghostty's write is this scenario's own doing: the restore mark
            # follows it before any check, so a failing check still puts the
            # owner's clipboard back.
            try {
                if (-not (Wait-File (Join-Path $script:Sbx.Tmp "$Name.done") $TimeoutSec)) { throw "$Name`: the reader never finished" }
            } finally { Update-ClipboardMark }
        }
        function Stop-Case($G) {
            [void](Invoke-GhosttyAction -Class $G.Class -Action 'close_all_windows')
            [void](Wait-ProcessExit $G 8)
        }

        # --- 1. allow ------------------------------------------------------------
        [GhosttyKitty.Tool]::WriteQuery((Join-Path $tmp 'w1.bin'), [string[]]@('text/plain', 'text/html', 'image/png'),
            [byte[][]]@($u8.GetBytes('gh-5522'), $u8.GetBytes('<b>gh</b>'), $png), 3072)
        Set-ClipboardText 'sentinel-before-write'
        $g = Start-WriteCase 'w1' 'allow' (Join-Path $tmp 'w1.bin') 'type=write:status=DONE\e\\' 25000
        Finish-WriteCase $g 'w1' 60
        if (Test-KittyDialogOpen $g) { throw 'allow: a dialog appeared' }

        # The clipboard first (reading the screen overwrites it).
        $snap = Get-ClipboardSnapshot
        $text = Get-ClipFormatBytes $snap 13
        if (-not $text) { throw 'allow: no CF_UNICODETEXT after the write' }
        $t = [Text.Encoding]::Unicode.GetString($text).TrimEnd([char]0)
        if ($t -ne 'gh-5522') { throw "allow: CF_UNICODETEXT is '$t', expected 'gh-5522'" }
        $html = Get-ClipFormatBytes $snap 'HTML Format'
        if (-not $html) { throw 'allow: no "HTML Format" after the write' }
        $frag = Get-CfHtmlFragment $html
        if ($frag -ne '<b>gh</b>') { throw "allow: the HTML fragment is '$frag', expected '<b>gh</b>'" }
        $gotPng = Get-ClipFormatBytes $snap 'PNG'
        if (-not $gotPng) { throw 'allow: no "PNG" after the write' }
        if ([Convert]::ToBase64String($gotPng) -ne [Convert]::ToBase64String($png)) { throw "allow: 'PNG' is not byte-identical ($($gotPng.Length) bytes, sent $($png.Length))" }
        $dib = Get-ClipFormatBytes $snap 17
        if (-not $dib) { throw 'allow: no CF_DIBV5 after the write' }
        $hdr = [BitConverter]::ToInt32($dib, 0); $w = [BitConverter]::ToInt32($dib, 4); $h = [BitConverter]::ToInt32($dib, 8)
        $bpp = [BitConverter]::ToInt16($dib, 14)
        if ($hdr -ne 124 -or $w -ne 2 -or [Math]::Abs($h) -ne 2 -or $bpp -ne 32) { throw "allow: CF_DIBV5 header size=$hdr ${w}x$h bpp=$bpp, expected 124, 2x2, 32" }
        # Bottom-up BGRA: the bottom row (blue, white) comes first.
        $px = [byte[]]$dib[124..($dib.Length - 1)]
        $want = @(@(255, 0, 0, 255), @(255, 255, 255, 255), @(0, 0, 255, 255), @(0, 255, 0, 255))
        for ($i = 0; $i -lt 4; $i++) {
            for ($c = 0; $c -lt 4; $c++) {
                if ([int]$px[4 * $i + $c] -ne $want[$i][$c]) { throw "allow: CF_DIBV5 pixel $i byte $c is $($px[4 * $i + $c]), expected $($want[$i][$c])" }
            }
        }
        Write-E2eInfo 'allow: text, HTML fragment, PNG and CF_DIBV5 are on the clipboard'

        $reply = Read-KittyScreen $g
        $st = Get-KittyStatuses (Read-KittyReply $reply.Raw)
        if ($st -notcontains 'DONE') { throw "allow: the reply has no status=DONE: $($reply.Raw)" }
        Save-Evidence 'allow' $g -Window
        Stop-Case $g

        # --- 2. ask, Deny by Enter ----------------------------------------------
        [GhosttyKitty.Tool]::WriteQuery((Join-Path $tmp 'w2.bin'), [string[]]@('text/plain'), [byte[][]]@($u8.GetBytes('should-not-land')), 3072)
        Set-ClipboardText 'sentinel-ask'
        $seq = [uint32](Get-ClipboardSequence)
        $g = Start-WriteCase 'w2' 'ask' (Join-Path $tmp 'w2.bin') 'status=EPERM\e\\' 25000
        $dlg = Find-KittyDialog $g 15
        if (-not $dlg) { throw 'ask: no dialog (GhosttyDialog) for the write' }
        Write-E2eInfo ("ask: dialog '" + [GhosttyE2e.Win]::TextOf($dlg) + "'")
        Save-Evidence 'ask-dialog' $g -Window -Hwnd $dlg
        Close-KittyDialog $dlg 'Deny'
        Finish-WriteCase $g 'w2' 40
        if ([uint32](Get-ClipboardSequence) -ne $seq) { throw 'ask: the clipboard sequence number changed after Deny' }
        $reply = Read-KittyScreen $g
        $st = Get-KittyStatuses (Read-KittyReply $reply.Raw)
        if ($st -notcontains 'EPERM') { throw "ask: Deny did not answer EPERM: $($reply.Raw)" }
        Write-E2eInfo 'ask: Deny answered EPERM and left the clipboard alone'
        Stop-Case $g

        # --- 3a. the limit wiring, fast: limit 1 MiB, a 2 MiB write --------------
        # The same EFBIG path as case 3 without a 90 s flood: if this passes and
        # case 3 fails, the config reaches the handler and the loss is in the
        # volume (the console or the read loop), not in the limit.
        $mid = [GhosttyKitty.Tool]::Fill(2 * 1024 * 1024, 65)
        [GhosttyKitty.Tool]::WriteQuery((Join-Path $tmp 'w3a.bin'), [string[]]@('text/plain'), [byte[][]]@($mid), 3072)
        $mid = $null
        $g = Start-WriteCase 'w3a' ("allow`nclipboard-write-limit-bytes = 1048576") (Join-Path $tmp 'w3a.bin') 'status=EFBIG\e\\' 60000
        Finish-WriteCase $g 'w3a' 90
        if (Test-KittyDialogOpen $g) { throw 'EFBIG (1 MiB limit): a dialog appeared' }
        $reply = Read-KittyScreen $g
        $st = Get-KittyStatuses (Read-KittyReply $reply.Raw)
        if ($st -notcontains 'EFBIG') { throw "EFBIG (1 MiB limit): the 2 MiB write was not refused with EFBIG: $($reply.Raw)" }
        Write-E2eInfo 'EFBIG: a 2 MiB write over a 1 MiB limit was refused'
        Stop-Case $g

        # --- 3. 70 MiB: over core's limit ---------------------------------------
        $big = [GhosttyKitty.Tool]::Fill(70 * 1024 * 1024, 65)
        [GhosttyKitty.Tool]::WriteQuery((Join-Path $tmp 'w3.bin'), [string[]]@('text/plain'), [byte[][]]@($big), 3072)
        $big = $null
        $g = Start-WriteCase 'w3' 'allow' (Join-Path $tmp 'w3.bin') 'status=EFBIG\e\\' 150000
        Finish-WriteCase $g 'w3' 200
        if (Test-KittyDialogOpen $g) { throw 'EFBIG: a dialog appeared' }
        $reply = Read-KittyScreen $g
        $st = Get-KittyStatuses (Read-KittyReply $reply.Raw)
        if ($st -notcontains 'EFBIG') { throw "EFBIG: the 70 MiB write was not refused with EFBIG: $($reply.Raw)" }
        Write-E2eInfo 'EFBIG: the 70 MiB write was refused, no dialog'
        Stop-Case $g
    } finally {
        Restore-ClipboardText $saved
    }
}
