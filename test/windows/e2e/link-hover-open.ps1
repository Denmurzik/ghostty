# e2e: milestone=M3 timeout=120 order=550
# link-hover-open: an OSC 8 link printed by Git Bash shows its URL in a
# GhosttyOverlayLabel while the pointer is over it and hides it when the
# pointer leaves. Ctrl+click records the URL in `m3.opened` with verdict
# `open` (test mode records, nothing is launched). An OSC 8 `ms-settings:`
# link shows the confirmation dialog; cancelling it records
# {verdict: confirm, outcome: cancelled}. Interactive only.
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

    function Get-VisibleLabels {
        @([GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyOverlayLabel') | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) })
    }
    function Get-SurfaceHwnd {
        $s = (Get-GhosttyState -Class $g.Class).windows[0].tabs[0].surfaces[0]
        [IntPtr][Convert]::ToInt64($s.hwnd, 16)
    }

    # The links sit at the start of rows 0 and 1.
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+l'
    Start-Sleep -Milliseconds 300
    Send-Line $g.Hwnd ("printf '\033]8;;$url\033\\ghostty-link\033]8;;\033\\\n\033]8;;ms-settings:\033\\settings-link\033]8;;\033\\\n'")
    Start-Sleep -Milliseconds 800
    $surface = Get-SurfaceHwnd
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)

    # Row heights are unknown here: probe the first rows for the link.
    # OSC 8 links are only live while Ctrl (or Super) is held.
    $hovered = $false
    [GhosttyE2e.LinkKeys]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    try {
    foreach ($y in 20..300 | Where-Object { $_ % 10 -eq 0 }) {
        Send-MouseMove -Hwnd $surface -X 30 -Y $y
        if (Wait-Until -TimeoutSec 0.5 -PollMs 50 -Condition { @(Get-VisibleLabels).Count -ge 1 }) { $hovered = $true; $row = $y; break }
    }
    } finally { [GhosttyE2e.LinkKeys]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero) }
    if (-not $hovered) {
        # L1: if ConPTY drops OSC 8 the steps below are an owner-approved gap.
        Save-Evidence 'no-label' $g -Window
        throw 'no link label within 1 s of hovering the OSC 8 link'
    }
    Save-Evidence 'hover' $g -Window
    Write-E2eInfo "label shown at y=$row"

    # Moved away: hidden.
    Send-MouseMove -Hwnd $surface -X 400 -Y 300
    if (-not (Wait-Until -TimeoutSec 2 -PollMs 50 -Condition { @(Get-VisibleLabels).Count -eq 0 })) { throw 'the label stays after the pointer left the link' }

    # Ctrl+click on the https link: recorded as open.
    Send-MouseMove -Hwnd $surface -X 30 -Y $row
    Start-Sleep -Milliseconds 200
    [GhosttyE2e.LinkKeys]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    try { Send-MouseClick -Hwnd $surface -X 30 -Y $row } finally { [GhosttyE2e.LinkKeys]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero) }
    $rec = Wait-Until -TimeoutSec 5 -PollMs 100 -Condition {
        Get-Opened $g | Where-Object { $_.url -eq $url -and $_.verdict -eq 'open' } | Select-Object -First 1
    }
    if (-not $rec) { throw "the click did not record $url as open: $((Get-Opened $g) | ConvertTo-Json -Compress -Depth 4)" }
    Write-E2eInfo 'open recorded'

    # The ms-settings: link asks first; cancelling is recorded.
    $dlg = $null
    foreach ($dy in 0, 4, 8, 12, 16, 20) {
        Send-MouseMove -Hwnd $surface -X 30 -Y ($row + $dy + 10)
        Start-Sleep -Milliseconds 150
        [GhosttyE2e.LinkKeys]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
        try { Send-MouseClick -Hwnd $surface -X 30 -Y ($row + $dy + 10) } finally { [GhosttyE2e.LinkKeys]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero) }
        $dlg = Wait-Until -TimeoutSec 2 -PollMs 100 -Condition { [GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyDialog') | Select-Object -First 1 }
        if ($dlg) { break }
    }
    if (-not $dlg) { throw 'no confirmation dialog for the ms-settings: link' }
    Save-Evidence 'confirm' $g -Window -Hwnd $dlg
    # Cancel (IDCANCEL, what Esc does): the dialog is answered with window messages as in paste-confirm.
    [void][GhosttyE2e.Win]::PostMessageW($dlg, 0x466, [IntPtr]2, [IntPtr]::Zero)
    if (-not (Wait-Until -TimeoutSec 3 -PollMs 100 -Condition { -not [GhosttyE2e.Win]::IsWindow($dlg) })) { throw 'the confirmation dialog did not close' }
    $rec = Wait-Until -TimeoutSec 3 -PollMs 100 -Condition {
        Get-Opened $g | Where-Object { $_.url -eq 'ms-settings:' -and $_.verdict -eq 'confirm' -and $_.outcome -eq 'cancelled' } | Select-Object -First 1
    }
    if (-not $rec) { throw "cancel was not recorded: $((Get-Opened $g) | ConvertTo-Json -Compress -Depth 4)" }
    Write-E2eInfo 'confirm cancelled recorded'
}
