# e2e: milestone=M7 timeout=120 order=1130
# link-windows-path: Windows paths in terminal output are links (R-M7-6). cmd
# types a file that holds `C:\Windows\win.ini:3`, `.\x\y.txt` and
# `\\server\share\z.txt`. With Ctrl held the pointer shows the link label over
# the first two and over nothing else (the UNC path is never a link, so a link
# can not contact an SMB share). Ctrl+click on each of the two records its
# exact text in `m3.opened` (test mode records, nothing is launched).
# The file sits in the shell's working directory and is typed by its bare
# name, so the echoed command line holds no path (the long sandbox path would
# be a link of its own); the screen is cleared before the type. Every row is
# probed on its own, from a pointer parked away from the text.
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

    $home_dir = $g.Sandbox.Home
    $file = Join-Path $home_dir 'gt-links.txt'
    $lines = @('C:\Windows\win.ini:3', '.\x\y.txt', '\\server\share\z.txt')
    [IO.File]::WriteAllText($file, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $false))

    $s0 = (Get-GhosttyState -Class $g.Class).windows[0]
    $surface = [IntPtr][Convert]::ToInt64($s0.tabs[0].surfaces[0].hwnd, 16)
    $cell = [int]$s0.cell[1]

    # Only the link label counts: the resize overlay, the scroller, badges and
    # the key state label share its window class. The link label sits at the
    # bottom-left corner of its surface (overlay.zig, surface_bottom_left,
    # margin 0); the others are at the top or the right.
    function Get-LinkLabels {
        $s = New-Object GhosttyE2e.Win+RECT
        [void][GhosttyE2e.Win]::GetWindowRect($surface, [ref]$s)
        $found = New-Object System.Collections.Generic.List[IntPtr]
        foreach ($h in [GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyOverlayLabel')) {
            if (-not [GhosttyE2e.Win]::IsWindowVisible($h)) { continue }
            $l = New-Object GhosttyE2e.Win+RECT
            [void][GhosttyE2e.Win]::GetWindowRect($h, [ref]$l)
            if (([math]::Abs($l.Left - $s.Left) -le 3) -and ([math]::Abs($l.Bottom - $s.Bottom) -le 3)) { $found.Add($h) }
        }
        $found.ToArray()
    }
    function Get-LabelRects {
        $parts = foreach ($h in [GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyOverlayLabel')) {
            if (-not [GhosttyE2e.Win]::IsWindowVisible($h)) { continue }
            $l = New-Object GhosttyE2e.Win+RECT
            [void][GhosttyE2e.Win]::GetWindowRect($h, [ref]$l)
            "[$($l.Left),$($l.Top),$($l.Right),$($l.Bottom)]"
        }
        $s = New-Object GhosttyE2e.Win+RECT
        [void][GhosttyE2e.Win]::GetWindowRect($surface, [ref]$s)
        "visible labels: $(@($parts) -join ' ') surface: [$($s.Left),$($s.Top),$($s.Right),$($s.Bottom)]"
    }
    function Get-RowY([int]$Row) { [int]($Row * $cell + [math]::Floor($cell / 2)) }
    function Invoke-CtrlHold([scriptblock]$Body) {
        [GhosttyE2e.WinPathKeys]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
        try { & $Body } finally { [GhosttyE2e.WinPathKeys]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero) }
    }
    function Move-Away {
        Send-MouseMove -Hwnd $surface -X 600 -Y 300 | Out-Null
        [void](Wait-Until -TimeoutSec 2 -PollMs 50 -Condition { @(Get-LinkLabels).Count -eq 0 })
    }
    function Test-RowLabel([int]$Row) {
        Move-Away
        Send-MouseMove -Hwnd $surface -X 20 -Y (Get-RowY $Row) | Out-Null
        [bool](Wait-Until -TimeoutSec 0.5 -PollMs 30 -Condition { @(Get-LinkLabels).Count -ge 1 })
    }

    # The prompt is cut to `>`, the file is typed by name from its directory
    # and the screen is cleared first: no directory is on the screen.
    Send-Line $g.Hwnd 'prompt $G'
    Send-Line $g.Hwnd ('cd /d "' + $home_dir + '"')
    Send-Line $g.Hwnd 'cls'
    Start-Sleep -Milliseconds 400
    Send-Line $g.Hwnd 'type gt-links.txt'
    Start-Sleep -Milliseconds 1000
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
    Save-Evidence 'text' $g -Window

    # Probe the first rows one by one for a label.
    $rows = New-Object System.Collections.Generic.List[int]
    Invoke-CtrlHold {
        for ($r = 0; $r -lt 8; $r++) {
            if (Test-RowLabel $r) { $rows.Add($r) }
        }
    }
    Move-Away
    Write-E2eInfo "label rows: $($rows -join ', ') (cell height $cell)"
    if ($rows.Count -ne 2) {
        Save-Evidence 'rows' $g -Window
        throw "expected a link label on exactly 2 rows (win.ini and y.txt, never the UNC path), got $($rows.Count): $($rows -join ', ') ($(Get-LabelRects))"
    }

    # Ctrl+click each of the two: the exact text is recorded.
    $want = @('C:\Windows\win.ini:3', '.\x\y.txt')
    for ($i = 0; $i -lt 2; $i++) {
        $y = Get-RowY $rows[$i]
        Move-Away
        Invoke-CtrlHold {
            Send-MouseMove -Hwnd $surface -X 20 -Y $y | Out-Null
            if (-not (Wait-Until -TimeoutSec 1.5 -PollMs 50 -Condition { @(Get-LinkLabels).Count -ge 1 })) {
                throw "no link label at row $($rows[$i]) before the click"
            }
            Send-MouseClick -Hwnd $surface -X 20 -Y $y
        }
        $text = $want[$i]
        $rec = Wait-Until -TimeoutSec 5 -PollMs 100 -Condition {
            Get-Opened $g | Where-Object { $_.url -ceq $text } | Select-Object -First 1
        }
        if (-not $rec) { throw "the click did not record '$text': $((Get-Opened $g) | ConvertTo-Json -Compress -Depth 4)" }
        Write-E2eInfo "recorded '$text' verdict=$($rec.verdict)"
    }
}
