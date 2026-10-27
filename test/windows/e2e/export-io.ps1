# e2e: milestone=M3 timeout=60 order=625
# export-io: the test op `export-io` (the inspector's export button cannot be
# clicked by a script) writes the text to a sandbox path without a dialog; the
# file holds exactly the bytes and state.m3.export_io records {path, bytes}.
# Unsafe paths are refused. The real save dialog is in the manual checklist.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'export-io' {
    $g = Start-E2eGhostty
    $out = Join-Path $g.Sandbox.Tmp 'export.txt'

    $r = Invoke-GhosttyIpc -Class $g.Class -Request @{ op = 'export-io'; surface = 0; text = 'hello-export'; path = $out }
    if ($r.code -ne 0) { throw "export-io: code $($r.code): $($r.stderr)" }

    $bytes = [IO.File]::ReadAllBytes($out)
    if ([Text.Encoding]::ASCII.GetString($bytes) -ne 'hello-export' -or $bytes.Length -ne 12) {
        throw "export file holds $($bytes.Length) bytes: $([BitConverter]::ToString($bytes))"
    }
    $x = (Get-GhosttyState -Class $g.Class).m3.export_io
    if ($x.bytes -ne 12 -or $x.path -ne $out -or $x.count -ne 1) { throw "state.m3.export_io is $($x | ConvertTo-Json -Compress)" }
    if (@([GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyDialog')).Count -ne 0) { throw 'a dialog appeared in test mode' }

    foreach ($bad in "$($g.Sandbox.Tmp)\..\escape.txt", "$out`:stream") {
        $r = Invoke-GhosttyIpc -Class $g.Class -Request @{ op = 'export-io'; surface = 0; text = 'x'; path = $bad }
        if ($r.code -eq 0) { throw "export-io accepted the unsafe path $bad" }
    }
    if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $g.Sandbox.Tmp) 'escape.txt')) { throw 'the .. path wrote a file' }
}
