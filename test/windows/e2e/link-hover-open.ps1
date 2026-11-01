# e2e: milestone=M3 timeout=120 order=550
# link-hover-open: an OSC 8 link printed by Git Bash shows its URL in a
# GhosttyOverlayLabel while the pointer is over it and hides it when the
# pointer leaves. Ctrl+click records the URL in `m3.opened` with verdict
# `open` (test mode records, nothing is launched). An OSC 8 `ms-settings:`
# link shows the confirmation dialog; cancelling it records
# {verdict: confirm, outcome: cancelled}. An OSC 8 link with U+202E in its URI
# is refused on Ctrl+click and its label shows <U+202E> (evidence shot).
# The command that prints the links is followed by `clear` in the same line,
# so its echo (which holds the plain URL, a link of its own) is gone and the
# links are the first rows. Ctrl is held for the whole hover and click of a
# link, as a user does. Interactive only.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

if (-not ('GhosttyE2e.LinkKeys' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name LinkKeys -MemberDefinition @"
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
"@
}

function Get-Opened($G) { @((Get-GhosttyState -Class $G.Class).m3.opened) }

Invoke-E2eScenario 'link-hover-open' {
    $g = Start-BashE2e
    $url = 'https://example.com/ghostty-e2e'

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
    function Hold-Ctrl { [GhosttyE2e.LinkKeys]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero) }
    function Release-Ctrl { [GhosttyE2e.LinkKeys]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero) }
    function Move-Away {
        Send-MouseMove -Hwnd $surface -X 400 -Y 300 | Out-Null
        [void](Wait-Until -TimeoutSec 2 -PollMs 50 -Condition { @(Get-LinkLabels).Count -eq 0 })
    }
    # The first of $Rows rows from row 0 whose pointer shows the link label (Ctrl held), else -1.
    function Find-LinkRow([int]$Rows) {
        for ($r = 0; $r -lt $Rows; $r++) {
            Send-MouseMove -Hwnd $surface -X 30 -Y (Get-RowY $r) | Out-Null
            if (Wait-Until -TimeoutSec 0.5 -PollMs 50 -Condition { @(Get-LinkLabels).Count -ge 1 }) { return $r }
        }
        -1
    }
    # Ctrl down, pointer onto the link (the label must show), click, Ctrl up.
    function Invoke-LinkClick([int]$Row) {
        Move-Away
        $y = Get-RowY $Row
        Hold-Ctrl
        try {
            Send-MouseMove -Hwnd $surface -X 30 -Y $y | Out-Null
            if (-not (Wait-Until -TimeoutSec 1.5 -PollMs 50 -Condition { @(Get-LinkLabels).Count -ge 1 })) {
                throw "no link label at row $Row before the click ($(Get-LabelRects))"
            }
            Send-MouseClick -Hwnd $surface -X 30 -Y $y
        } finally { Release-Ctrl }
    }

    # The links are the first two rows once `clear` ran.
    Send-Line $g.Hwnd ("clear; printf '\033]8;;$url\033\\ghostty-link\033]8;;\033\\\n\033]8;;ms-settings:\033\\settings-link\033]8;;\033\\\n'")
    Start-Sleep -Milliseconds 1000
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)

    # OSC 8 links are only live while Ctrl (or Super) is held.
    $row = -1
    Hold-Ctrl
    try {
        $row = Find-LinkRow 6
        if ($row -ge 0) { Save-Evidence 'hover' $g -Window }
    } finally { Release-Ctrl }
    if ($row -lt 0) {
        # L1: if ConPTY drops OSC 8 the steps below are an owner-approved gap.
        Save-Evidence 'no-label' $g -Window
        throw "no link label within 0.5 s of hovering any of the first 6 rows ($(Get-LabelRects))"
    }
    Write-E2eInfo "label shown at row $row"

    # Moved away: hidden.
    Hold-Ctrl
    try { Send-MouseMove -Hwnd $surface -X 400 -Y 300 | Out-Null } finally { Release-Ctrl }
    if (-not (Wait-Until -TimeoutSec 2 -PollMs 50 -Condition { @(Get-LinkLabels).Count -eq 0 })) { throw 'the label stays after the pointer left the link' }

    # Ctrl+click on the https link: recorded as open.
    Invoke-LinkClick $row
    $rec = Wait-Until -TimeoutSec 5 -PollMs 100 -Condition {
        Get-Opened $g | Where-Object { $_.url -eq $url -and $_.verdict -eq 'open' } | Select-Object -First 1
    }
    if (-not $rec) { throw "the click did not record $url as open: $((Get-Opened $g) | ConvertTo-Json -Compress -Depth 4)" }
    Write-E2eInfo 'open recorded'

    # The ms-settings: link (the next row) asks first; cancelling is recorded.
    Invoke-LinkClick ($row + 1)
    $dlg = Wait-Until -TimeoutSec 3 -PollMs 100 -Condition { [GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyDialog') | Select-Object -First 1 }
    if (-not $dlg) {
        Save-Evidence 'no-confirm' $g -Window
        throw "no confirmation dialog for the ms-settings: link: $((Get-Opened $g) | ConvertTo-Json -Compress -Depth 4)"
    }
    Save-Evidence 'confirm' $g -Window -Hwnd $dlg
    # Cancel (IDCANCEL, what Esc does): the dialog is answered with window messages as in paste-confirm.
    [void][GhosttyE2e.Win]::PostMessageW($dlg, 0x466, [IntPtr]2, [IntPtr]::Zero)
    if (-not (Wait-Until -TimeoutSec 3 -PollMs 100 -Condition { -not [GhosttyE2e.Win]::IsWindow($dlg) })) { throw 'the confirmation dialog did not close' }
    $rec = Wait-Until -TimeoutSec 3 -PollMs 100 -Condition {
        Get-Opened $g | Where-Object { $_.url -eq 'ms-settings:' -and $_.verdict -eq 'confirm' -and $_.outcome -eq 'cancelled' } | Select-Object -First 1
    }
    if (-not $rec) { throw "cancel was not recorded: $((Get-Opened $g) | ConvertTo-Json -Compress -Depth 4)" }
    Write-E2eInfo 'confirm cancelled recorded'

    # --- an OSC 8 link whose URI holds U+202E (right-to-left override) -----------------
    # The label must show it as <U+202E> (checked on the evidence shot: the
    # test-ops state has no label text), and Ctrl+click is refused, never opened.
    # The override as UTF-8 bytes (E2 80 AE) in a printf escape: the script stays ASCII.
    Send-Line $g.Hwnd ("clear; printf '\033]8;;https://example.com/\xe2\x80\xaegpj.exe\033\\bidi-link\033]8;;\033\\\n'")
    Start-Sleep -Milliseconds 1000
    $row = -1
    Hold-Ctrl
    try {
        $row = Find-LinkRow 6
        if ($row -ge 0) { Save-Evidence 'hover-bidi' $g -Window }
    } finally { Release-Ctrl }
    if ($row -lt 0) {
        Save-Evidence 'no-label-bidi' $g -Window
        throw "no link label within 0.5 s of hovering any of the first 6 rows with the U+202E link ($(Get-LabelRects))"
    }
    Invoke-LinkClick $row
    $rec = Wait-Until -TimeoutSec 5 -PollMs 100 -Condition {
        Get-Opened $g | Where-Object { $_.url -like 'https://example.com/*gpj.exe' -and $_.verdict -eq 'refuse' } | Select-Object -First 1
    }
    if (-not $rec) { throw "the U+202E link was not recorded as refused: $((Get-Opened $g) | ConvertTo-Json -Compress -Depth 4)" }
    if (@(Get-Opened $g | Where-Object { $_.url -like 'https://example.com/*gpj.exe' -and $_.verdict -ne 'refuse' }).Count -ne 0) { throw 'the U+202E link was opened or confirmed' }
    Write-E2eInfo 'U+202E link refused'
}
