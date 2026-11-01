# e2e: milestone=M8 timeout=420 order=1251
# kitty-clipboard-read: a program reads the clipboard with the Kitty clipboard
# protocol (OSC 5522) behind the confirmation prompt. A native vtreader (bundled
# console under `auto`) sends the request and prints the reply. The clipboard
# holds CF_UNICODETEXT "hello", "HTML Format" "<i>hi</i>" and a 16x16 red CF_DIB
# (no "PNG").
#   1. clipboard-read = ask, read ". image/png text/html text/plain": a
#      GhosttyDialog appears, its picture box shows the red image; Allow
#      answers OK, the listing "text/plain text/html image/png", DATA text/html
#      "<i>hi</i>", DATA image/png (a 16x16 red PNG) and DONE.
#   2. the same, Deny (Enter): status=EPERM.
#   3. clipboard-read = deny: status=EPERM and no dialog.
#   4. ask, a read of "." only: the listing, no dialog.
#   5. allow, a 3840x2160 DIB read as image/png: the log line
#      "kitty read gathered ... in N ms" and the time against the 300 ms budget
#      (ReleaseFast; reported only for a debug build).
# The clipboard is saved and restored.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_kitty5522.ps1')

Invoke-E2eScenario 'kitty-clipboard-read' {
    $saved = Save-ClipboardText
    try {
        $tmp = $script:Sbx.Tmp
        $u8 = New-Object Text.UTF8Encoding $false

        function Set-SourceClipboard([byte[]]$Dib) {
            Set-ClipSnapshot (New-ClipSnapshot @(
                    @{ Format = 13; Bytes = (ConvertTo-UnicodeTextBytes 'hello') }
                    @{ Format = 'HTML Format'; Bytes = (New-CfHtml '<i>hi</i>') }
                    @{ Format = 8; Bytes = $Dib }
                ))
        }
        function Start-ReadCase([string]$Name, [string]$Policy, [string]$Mimes, [string]$Until, [int]$WaitMs, [int]$GotMax = -1) {
            $q = Join-Path $script:Sbx.Tmp "$Name.bin"
            [GhosttyKitty.Tool]::ReadQuery($q, $Mimes)
            $cfg = New-KittyConfig -Name $Name -QueryFile ($q -replace '\\', '/') -WaitMs $WaitMs -Until $Until -GotMax $GotMax -Extra "clipboard-read = $Policy"
            Start-E2eGhostty -ConfigText $cfg
        }
        function Wait-Reader($Name, [double]$TimeoutSec) {
            if (-not (Wait-File (Join-Path $script:Sbx.Tmp "$Name.done") $TimeoutSec)) { throw "$Name`: the reader never finished" }
        }
        function Stop-Case($G) {
            [void](Invoke-GhosttyAction -Class $G.Class -Action 'close_all_windows')
            [void](Wait-ProcessExit $G 8)
        }

        $dib16 = [GhosttyKitty.Tool]::Dib24(16, 16, 255, 0, 0, $false)
        $request = '. image/png text/html text/plain'

        # --- 1. ask, Allow ---------------------------------------------------------
        Set-SourceClipboard $dib16
        $g = Start-ReadCase 'r1' 'ask' $request 'status=DONE\e\\' 25000
        $dlg = Find-KittyDialog $g 15
        if (-not $dlg) { throw 'ask: no dialog (GhosttyDialog) for the read' }
        Write-E2eInfo ("ask: dialog '" + [GhosttyE2e.Win]::TextOf($dlg) + "'")
        Save-Evidence 'dialog' $g -Window -Hwnd $dlg
        $evd = Get-EvidenceDir; if (-not $evd) { $evd = $tmp }
        $shot = Join-Path $evd 'kitty-clipboard-read-dialog-shot.png'
        $red = Measure-ShotColor $dlg $shot @(255, 0, 0) 40
        if ($red -lt 160) { throw "ask: the dialog shows $red red pixels, the 16x16 (256 pixel) red picture is missing" }
        Write-E2eInfo "ask: the dialog shows the red picture ($red of 256 pixels)"
        Close-KittyDialog $dlg 'Allow'
        Wait-Reader 'r1' 40
        $reply = Read-KittyScreen $g
        $packets = Read-KittyReply $reply.Raw
        Save-Evidence 'allow' $g -Window
        $st = Get-KittyStatuses $packets
        if ($st[0] -ne 'OK' -or $st -notcontains 'DONE') { throw "ask/Allow: statuses are '$($st -join ',')', expected OK ... DONE: $($reply.Raw)" }
        $list = Get-KittyData $packets '.'
        if ($null -eq $list) { throw 'ask/Allow: no listing' }
        $listText = ($u8.GetString($list)).Trim()
        if ($listText -ne 'text/plain text/html image/png') { throw "ask/Allow: the listing is '$listText'" }
        $html = Get-KittyData $packets 'text/html'
        if ($null -eq $html -or $u8.GetString($html) -ne '<i>hi</i>') { throw 'ask/Allow: DATA text/html is not <i>hi</i>' }
        $plain = Get-KittyData $packets 'text/plain'
        if ($null -eq $plain -or $u8.GetString($plain) -ne 'hello') { throw 'ask/Allow: DATA text/plain is not hello' }
        $pngData = Get-KittyData $packets 'image/png'
        if ($null -eq $pngData) { throw 'ask/Allow: no DATA image/png' }
        $img = New-Object Drawing.Bitmap (New-Object IO.MemoryStream (, [byte[]]$pngData))
        try {
            if ($img.Width -ne 16 -or $img.Height -ne 16) { throw "ask/Allow: the PNG is $($img.Width)x$($img.Height), expected 16x16" }
            $p = $img.GetPixel(8, 8)
            if ($p.R -lt 250 -or $p.G -gt 5 -or $p.B -gt 5) { throw "ask/Allow: the PNG centre pixel is $p, expected red" }
        } finally { $img.Dispose() }
        Write-E2eInfo 'ask/Allow: OK, listing, text/html, text/plain, a 16x16 red PNG, DONE'
        Stop-Case $g

        # --- 2. ask, Deny --------------------------------------------------------------
        Set-SourceClipboard $dib16
        $g = Start-ReadCase 'r2' 'ask' $request 'status=EPERM\e\\' 25000
        $dlg = Find-KittyDialog $g 15
        if (-not $dlg) { throw 'deny: no dialog (GhosttyDialog) for the read' }
        Close-KittyDialog $dlg 'Deny'
        Wait-Reader 'r2' 40
        $reply = Read-KittyScreen $g
        $st = Get-KittyStatuses (Read-KittyReply $reply.Raw)
        if ($st -notcontains 'EPERM' -or $st -contains 'DATA') { throw "deny: statuses are '$($st -join ',')', expected EPERM only: $($reply.Raw)" }
        Write-E2eInfo 'ask/Deny: EPERM'
        Stop-Case $g

        # --- 3. clipboard-read = deny --------------------------------------------------
        Set-SourceClipboard $dib16
        $g = Start-ReadCase 'r3' 'deny' $request 'status=EPERM\e\\' 25000
        Wait-Reader 'r3' 40
        if (Test-KittyDialogOpen $g) { throw 'deny policy: a dialog appeared' }
        $reply = Read-KittyScreen $g
        $st = Get-KittyStatuses (Read-KittyReply $reply.Raw)
        if ($st -notcontains 'EPERM') { throw "deny policy: no EPERM: $($reply.Raw)" }
        Write-E2eInfo 'clipboard-read = deny: EPERM, no dialog'
        Stop-Case $g

        # --- 4. a "." read only: the listing, no prompt --------------------------------------
        Set-SourceClipboard $dib16
        $g = Start-ReadCase 'r4' 'ask' '.' 'status=DONE\e\\' 25000
        Wait-Reader 'r4' 40
        if (Test-KittyDialogOpen $g) { throw 'listing: a dialog appeared' }
        $reply = Read-KittyScreen $g
        $packets = Read-KittyReply $reply.Raw
        $list = Get-KittyData $packets '.'
        if ($null -eq $list -or ($u8.GetString($list)).Trim() -ne 'text/plain text/html image/png') { throw "listing: wrong or missing listing: $($reply.Raw)" }
        Write-E2eInfo 'ask, "." only: the listing without a dialog'
        Stop-Case $g

        # --- 5. a 4K screenshot as image/png: time ---------------------------------------------
        Set-SourceClipboard ([GhosttyKitty.Tool]::Dib24(3840, 2160, 40, 90, 200, $true))
        $g = Start-ReadCase 'r5' 'allow' 'image/png' 'status=DONE\e\\' 60000 64
        Wait-Reader 'r5' 90
        $log = Get-Content -LiteralPath $g.Log -Raw -ErrorAction SilentlyContinue
        $m = [regex]::Match([string]$log, 'kitty read gathered (\d+) representations, (\d+) bytes in (\d+) ms')
        if (-not $m.Success) { throw "the log has no 'kitty read gathered' line ($($g.Log))" }
        $ms = [int]$m.Groups[3].Value
        Write-E2eInfo "4K DIB served as PNG: $($m.Groups[2].Value) bytes in $ms ms (budget 300 ms on ReleaseFast)"
        if ($ms -gt 300) { Write-E2eInfo "NOTE $ms ms is over the 300 ms ReleaseFast budget (expected on a debug build)" }
        Stop-Case $g
    } finally {
        Restore-ClipboardText $saved
    }
}
