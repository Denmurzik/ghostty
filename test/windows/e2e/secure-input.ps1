# e2e: milestone=M5 timeout=240 order=870
# secure-input: `toggle_secure_input` excludes every top-level window of the UI
# thread from capture (WDA_EXCLUDEFROMCAPTURE, 0x11): the window, the palette
# popup, a window opened afterwards, the explainer dialog, and the badge
# popups. One lock badge per surface. A copy while it is on carries the
# clipboard exclusion formats (read as a format list, never the content).
# Turning it off clears every affinity and hides the badges. There is no
# pixel oracle for the badge while it is on (it is excluded from capture), so
# the one guarded screenshot is taken after turning it off. Keep this file
# ASCII only. The clipboard is saved first and put back in `finally`.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')

if (-not ('GhosttyE2e.ClipFormats' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name ClipFormats -MemberDefinition @"
[DllImport("user32.dll", SetLastError = true)] static extern bool OpenClipboard(IntPtr h);
[DllImport("user32.dll")] static extern bool CloseClipboard();
[DllImport("user32.dll")] static extern uint EnumClipboardFormats(uint f);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClipboardFormatNameW(uint f, System.Text.StringBuilder s, int n);
// Names of the registered formats only (the standard ones have no name); the
// content is never read.
public static string[] Names() {
    for (int i = 0; i < 30; i++) {
        if (OpenClipboard(IntPtr.Zero)) break;
        System.Threading.Thread.Sleep(50);
        if (i == 29) throw new System.Exception("OpenClipboard failed");
    }
    try {
        var l = new System.Collections.Generic.List<string>();
        uint f = 0;
        while ((f = EnumClipboardFormats(f)) != 0) {
            var sb = new System.Text.StringBuilder(256);
            if (GetClipboardFormatNameW(f, sb, 256) > 0) l.Add(sb.ToString());
        }
        return l.ToArray();
    } finally { CloseClipboard(); }
}
"@
}

Invoke-E2eScenario 'secure-input' {
    $saved = Save-ClipboardText
    try {
        $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'cmd')
        if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
        [void](Wait-SurfaceCount $g 1)

        function Get-Sec { (Get-IpcData (Get-GhosttyState -Class $g.Class)).m5.secure_input }
        function Format-Wins($s) { ($s.windows | ForEach-Object { '{0}:{1}:a{2}:v{3}' -f $_.class, $_.hwnd, $_.affinity, $_.visible }) -join ' ' }
        function Assert-Affinity($s, [int]$Want, [string]$What) {
            if (@($s.windows).Count -lt 1) { throw "$What : no top-level window listed" }
            $bad = @($s.windows | Where-Object { $_.affinity -ne $Want })
            if ($bad.Count -gt 0) { throw "$What : windows without affinity $Want : $(Format-Wins $s)" }
        }

        $s = Get-Sec
        if ($s.on) { throw 'secure input is on at start' }
        Assert-Affinity $s 0 'before'

        # 1. The palette popup exists when the toggle runs: the sweep covers it.
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_command_palette')
        if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { (Get-IpcData (Get-GhosttyState -Class $g.Class)).m3.palette.open })) { throw 'the palette did not open' }
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_secure_input')
        if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { (Get-Sec).on })) { throw 'toggle_secure_input did not turn it on' }
        $s = Get-Sec
        Assert-Affinity $s 17 'on'
        if (@($s.windows).Count -lt 3) { throw "expected the window, the palette and a badge, got: $(Format-Wins $s)" }

        # 2. One visible badge per surface, in the top right corner.
        $ok = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { @((Get-Sec).badges | Where-Object { $_.visible }).Count -eq 1 }
        if (-not $ok) { throw "expected one visible badge, got $(@((Get-Sec).badges).Count): $((Get-Sec).badges | ConvertTo-Json -Compress)" }
        $b = @((Get-Sec).badges)[0]
        if ($b.affinity -ne 17) { throw "the badge has affinity $($b.affinity)" }
        $w = $b.rect[2] - $b.rect[0]
        if ($w -lt 30 -or $w -ne ($b.rect[3] - $b.rect[1])) { throw "the badge is not a square of about 35 DIP: $($b.rect -join ',')" }

        # 3. A copy carries the exclusion formats (names only are read).
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_command_palette')
        Send-Line $g.Hwnd 'echo secure-copy'
        Start-Sleep -Milliseconds 800
        if (-not (Invoke-GhosttyAction -Class $g.Class -Action 'select_all')) { throw 'select_all was not performed' }
        if (-not (Invoke-GhosttyAction -Class $g.Class -Action 'copy_to_clipboard')) { throw 'copy_to_clipboard was not performed' }
        Update-ClipboardMark
        Start-Sleep -Milliseconds 300
        $names = [GhosttyE2e.ClipFormats]::Names()
        foreach ($want in 'ExcludeClipboardContentFromMonitorProcessing', 'CanIncludeInClipboardHistory', 'CanUploadToCloudClipboard') {
            if ($names -notcontains $want) { throw "the clipboard has no '$want' format after a secure copy: $($names -join ', ')" }
        }

        # 4. Windows made while it is on get the affinity too (a new palette popup, a new window).
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_command_palette')
        if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { (Get-IpcData (Get-GhosttyState -Class $g.Class)).m3.palette.open })) { throw 'the palette did not reopen' }
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_window')
        $two = Wait-Until -TimeoutSec 10 -PollMs 100 -Condition { @((Get-Sec).badges).Count -ge 2 }
        if (-not $two) { throw 'a second window did not get a badge' }
        Start-Sleep -Milliseconds 300
        Assert-Affinity (Get-Sec) 17 'after new_window'

        # 5. A badge click opens the explainer, which is excluded as well.
        $b = @((Get-Sec).badges | Where-Object { $_.visible })[0]
        $bh = [IntPtr][Convert]::ToInt64($b.hwnd, 16)
        [void][GhosttyE2e.Win]::PostMessageW($bh, 0x202, [IntPtr]::Zero, [IntPtr]::Zero)
        $dlg = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { [GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyDialog') | Select-Object -First 1 }
        if (-not $dlg) { throw 'a badge click did not open the explainer dialog' }
        Assert-Affinity (Get-Sec) 17 'with the explainer'
        [void][GhosttyE2e.Win]::PostMessageW($dlg, 0x466, [IntPtr]100, [IntPtr]::Zero)
        if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { -not [GhosttyE2e.Win]::IsWindow($dlg) })) { throw 'the explainer did not close' }

        # 6. Off: every affinity is cleared and the badges go.
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_secure_input')
        if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { -not (Get-Sec).on })) { throw 'the second toggle did not turn it off' }
        Assert-Affinity (Get-Sec) 0 'off'
        if (@((Get-Sec).badges | Where-Object { $_.visible }).Count -ne 0) { throw 'a badge is still visible after turning it off' }
        Start-Sleep -Milliseconds 300
        Save-Evidence 'secure-badge-off' $g -Window
    } finally {
        Restore-ClipboardText $saved
    }
}
