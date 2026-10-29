# e2e: milestone=M7 timeout=120 order=1130
# link-windows-path: Windows paths in terminal output are links (R-M7-6). cmd
# types a file that holds `C:\Windows\win.ini:3`, `.\x\y.txt` and
# `\\server\share\z.txt`. With Ctrl held the pointer shows the link label over
# the first two and over nothing else (the UNC path is never a link, so a link
# can not contact an SMB share). Ctrl+click on each of the two records its
# exact text in `m3.opened` (test mode records, nothing is launched).
# Interactive desktop only. Keep this file ASCII only.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

if (-not ('GhosttyE2e.WinPathKeys' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name WinPathKeys -MemberDefinition @"
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
"@
}

function Get-Opened($G) { @((Get-GhosttyState -Class $G.Class).m3.opened) }

Invoke-E2eScenario 'link-windows-path' {
    $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'cmd')
    if (-not (Wait-ChildNamed $g @('cmd.exe') 20)) { throw 'cmd did not start' }
    Start-Sleep -Milliseconds 1500

    $file = Join-Path $g.Sandbox.Tmp 'gt-links.txt'
    $lines = @('C:\Windows\win.ini:3', '.\x\y.txt', '\\server\share\z.txt')
    [IO.File]::WriteAllText($file, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $false))

    function Get-VisibleLabels {
        @([GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyOverlayLabel') | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) })
    }
    function Get-SurfaceHwnd {
        $s = (Get-GhosttyState -Class $g.Class).windows[0].tabs[0].surfaces[0]
        [IntPtr][Convert]::ToInt64($s.hwnd, 16)
    }
    function Invoke-CtrlHold([scriptblock]$Body) {
        [GhosttyE2e.WinPathKeys]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
        try { & $Body } finally { [GhosttyE2e.WinPathKeys]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero) }
    }

    # The prompt is cut to `>` so that no directory is on the screen.
    Send-Line $g.Hwnd 'prompt $G'
    Send-Line $g.Hwnd 'cls'
    Start-Sleep -Milliseconds 400
    Send-Line $g.Hwnd ('type "' + $file + '"')
    Start-Sleep -Milliseconds 1000
    $surface = Get-SurfaceHwnd
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
    Save-Evidence 'text' $g -Window

    # Probe rows from the top for a label; keep the rows that show one.
    $hits = New-Object System.Collections.Generic.List[int]
    Invoke-CtrlHold {
        foreach ($y in 4..160 | Where-Object { $_ % 4 -eq 0 }) {
            Send-MouseMove -Hwnd $surface -X 20 -Y $y
            if (Wait-Until -TimeoutSec 0.3 -PollMs 30 -Condition { @(Get-VisibleLabels).Count -ge 1 }) { $hits.Add($y) }
        }
    }
    Send-MouseMove -Hwnd $surface -X 600 -Y 300

    # Group the hit rows into one entry per terminal row: a gap of more than
    # one probe step starts a new row.
    $rows = New-Object System.Collections.Generic.List[int]
    $prev = -100
    foreach ($y in $hits) {
        if ($y - $prev -gt 4) { $rows.Add($y) }
        $prev = $y
    }
    Write-E2eInfo "label rows (first probe y each): $($rows -join ', ')"
    if ($rows.Count -ne 2) {
        Save-Evidence 'rows' $g -Window
        throw "expected a link label on exactly 2 rows (win.ini and y.txt, never the UNC path), got $($rows.Count)"
    }

    # Ctrl+click each of the two: the exact text is recorded.
    $want = @('C:\Windows\win.ini:3', '.\x\y.txt')
    for ($i = 0; $i -lt 2; $i++) {
        $y = $rows[$i] + 2
        Send-MouseMove -Hwnd $surface -X 20 -Y $y
        Start-Sleep -Milliseconds 200
        Invoke-CtrlHold { Send-MouseClick -Hwnd $surface -X 20 -Y $y }
        $text = $want[$i]
        $rec = Wait-Until -TimeoutSec 5 -PollMs 100 -Condition {
            Get-Opened $g | Where-Object { $_.url -ceq $text } | Select-Object -First 1
        }
        if (-not $rec) { throw "the click did not record '$text': $((Get-Opened $g) | ConvertTo-Json -Compress -Depth 4)" }
        Write-E2eInfo "recorded '$text' verdict=$($rec.verdict)"
    }
}
