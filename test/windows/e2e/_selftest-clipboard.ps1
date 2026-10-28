# Self-test of the clipboard save/restore (lib\Clipboard.psm1): HTML + text
# on the clipboard, save, overwrite, restore, compare byte for byte. The
# owner's clipboard is saved first and put back at the end; if it cannot be
# copied the test SKIPs. Run: powershell -NoProfile -STA -File _selftest-clipboard.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $PSScriptRoot '_common.ps1')

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'run with powershell -STA' }
try { $owner = Get-ClipboardSnapshot } catch { Write-Output "SKIP clipboard selftest: $($_.Exception.Message)"; exit 2 }
try {
    # HTML Format needs its header; the payload only has to round-trip.
    $html = "Version:0.9`r`nStartHTML:0000000000`r`n<html><body><b>caf" + [char]0xE9 + " test</b></body></html>"
    $do = New-Object System.Windows.Forms.DataObject
    $do.SetText('selftest text ' + [char]0x0416)
    $do.SetData('HTML Format', (New-Object IO.MemoryStream (, [Text.Encoding]::UTF8.GetBytes($html + "`0"))))
    $do.SetData('Rich Text Format', '{\rtf1 selftest}')
    [System.Windows.Forms.Clipboard]::SetDataObject($do, $true)

    $a = Get-ClipboardSnapshot
    $ids = @($a.Items | ForEach-Object { [uint32]$_[0] })
    if ($ids -notcontains 13) { throw 'no CF_UNICODETEXT in the snapshot' }
    if (@($a.Items).Count -lt 3) { throw "expected at least text + HTML + RTF, got $(@($a.Items).Count) formats" }

    [System.Windows.Forms.Clipboard]::SetText('overwritten')
    $mid = Get-ClipboardSnapshot
    if (Test-ClipboardSnapshotEqual $a $mid) { throw 'the overwrite changed nothing' }

    # Through the DPAPI file too.
    $file = Join-Path $env:TEMP ('gt-clip-selftest-' + [guid]::NewGuid().ToString('N') + '.bin')
    try {
        Export-ClipboardSnapshot $a $file
        $raw = [IO.File]::ReadAllBytes($file); $text = [Text.Encoding]::GetEncoding(28591).GetString($raw) + [Text.Encoding]::Unicode.GetString($raw)
        if ($text.Contains('selftest')) { throw 'the backup file holds clear text' }
        $b2 = Import-ClipboardSnapshot $file
    } finally { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
    if (-not (Test-ClipboardSnapshotEqual $a $b2)) { throw 'the DPAPI round trip changed the data' }

    Set-ClipboardSnapshot $b2
    $b = Get-ClipboardSnapshot
    if (-not (Test-ClipboardSnapshotEqual $a $b)) { throw 'restored clipboard differs from the saved one' }
    # The harness flow: Save, own writes, and the owner copying mid-test.
    function Get-Text { [System.Windows.Forms.Clipboard]::GetText() }
    $before = Get-ClipboardSnapshot
    # (a) nothing else wrote: Restore puts the original back.
    $s = Save-ClipboardText
    Set-ClipboardText 'own write 1'
    [System.Windows.Forms.Clipboard]::SetText('app copy'); Update-ClipboardMark
    Restore-ClipboardText $s
    if (-not (Test-ClipboardSnapshotEqual $before (Get-ClipboardSnapshot))) { throw 'flow (a): the clipboard was not restored' }
    if (Test-Path (Get-ClipboardBackupPath)) { throw 'flow (a): the backup file is still there' }
    # (b) the owner copies in the middle: their text stays, backup dropped.
    $s = Save-ClipboardText
    Set-ClipboardText 'own write 2'
    [System.Windows.Forms.Clipboard]::SetText('OWNER COPIED THIS')
    Set-ClipboardText 'own write 3'
    [System.Windows.Forms.Clipboard]::SetText('OWNER COPIED THIS')
    Restore-ClipboardText $s
    if ((Get-Text) -ne 'OWNER COPIED THIS') { throw "flow (b): the owner's copy was overwritten: '$(Get-Text)'" }
    if (Test-Path (Get-ClipboardBackupPath)) { throw 'flow (b): the backup file is still there' }
    # (c) a left-over backup is never overwritten by a new Save.
    $s = Save-ClipboardText
    Set-ClipboardText 'killed scenario text'
    $keep = Get-ClipboardSnapshot
    $s2 = Save-ClipboardText   # restores the first backup (mark still matches), then saves again
    if (-not (Test-ClipboardSnapshotEqual $s (Get-ClipboardSnapshot))) { throw 'flow (c): the earlier backup was not restored first' }
    Restore-ClipboardText $s2
    Write-Output "PASS clipboard selftest ($(@($a.Items).Count) formats, $(($a.Items | ForEach-Object { $_[1].Length } | Measure-Object -Sum).Sum) bytes)"
} finally {
    Set-ClipboardSnapshot $owner
}
