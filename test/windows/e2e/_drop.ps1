# OLE drag source helper of the file-drop scenarios. Dot-source it after
# _common.ps1 and import lib\MouseInput.psm1 first. Keep this file ASCII only
# (Windows PowerShell 5.1 reads a BOM-less script as ANSI).
#
# A drag source is a small WinForms window in a runspace of its own (STA): its
# MouseDown calls DoDragDrop, which blocks that thread until the button is
# released, so the scenario's thread stays free to move the real mouse. The
# data object is made by SetFileDropList, i.e. CF_HDROP exactly as Explorer
# makes it (the paths need not exist). Interactive desktop only.

Set-StrictMode -Version Latest

if (-not ('GhosttyE2e.DropNative' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name DropNative -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
'@
}

# Screen rectangle of a window as @{ L; T; R; B }.
function Get-ScreenRect([IntPtr]$Hwnd) {
    $r = New-Object GhosttyE2e.DropNative+RECT
    if (-not [GhosttyE2e.DropNative]::GetWindowRect($Hwnd, [ref]$r)) { throw "GetWindowRect failed for $Hwnd" }
    [pscustomobject]@{ L = $r.L; T = $r.T; R = $r.R; B = $r.B }
}

# Starts dragging -Files (full Windows paths) from a source window and leaves
# the left button held with the pointer at client point (-X, -Y) of -ToHwnd,
# i.e. mid-drag. Returns a handle for Stop-OleFileDrag.
function Start-OleFileDrag {
    param(
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][IntPtr]$ToHwnd,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y
    )

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $state = [hashtable]::Synchronized(@{ Stop = $false })
    $rs.SessionStateProxy.SetVariable('files', $Files)
    $rs.SessionStateProxy.SetVariable('state', $state)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        Add-Type -AssemblyName System.Windows.Forms
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'gt-drop-source'
        $form.FormBorderStyle = 'FixedToolWindow'
        $form.ShowInTaskbar = $false
        $form.TopMost = $true
        $form.StartPosition = 'Manual'
        $form.Size = New-Object System.Drawing.Size(120, 80)
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $form.Location = New-Object System.Drawing.Point(($wa.Right - 140), ($wa.Bottom - 100))
        $form.Add_MouseDown({
            $list = New-Object System.Collections.Specialized.StringCollection
            [void]$list.AddRange([string[]]$files)
            $data = New-Object System.Windows.Forms.DataObject
            $data.SetFileDropList($list)
            [void]$form.DoDragDrop($data, [System.Windows.Forms.DragDropEffects]::Copy)
        })
        $form.Show()
        while (-not $state.Stop) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 5 }
        $form.Close()
        $form.Dispose()
    })
    $async = $ps.BeginInvoke()

    # Wait for the form, then press inside it and nudge past the drag threshold.
    $src = Wait-Until -TimeoutSec 10 -PollMs 100 -Condition {
        $h = [GhosttyE2e.DropNative]::FindWindowW($null, 'gt-drop-source')
        $owner = [uint32]0
        if ($h -ne [IntPtr]::Zero) { [void][GhosttyE2e.DropNative]::GetWindowThreadProcessId($h, [ref]$owner) }
        if ($h -ne [IntPtr]::Zero -and $owner -eq [uint32]$PID) { $h }
    }
    if (-not $src) {
        $why = (@($ps.Streams.Error) | ForEach-Object { $_.ToString() }) -join '; '
        throw "the OLE drag source window did not appear (runspace errors: $why)"
    }
    $rc = Get-ScreenRect $src
    $cx = [int](($rc.L + $rc.R) / 2)
    $cy = [int](($rc.T + $rc.B) / 2)
    Send-MouseMove -ScreenX $cx -ScreenY $cy
    Start-Sleep -Milliseconds 150
    Send-MouseDown
    Start-Sleep -Milliseconds 100
    Send-MouseMove -ScreenX ($cx - 20) -ScreenY ($cy - 20) -Steps 4
    Send-MouseMove -Hwnd $ToHwnd -X $X -Y $Y -Steps 12
    Start-Sleep -Milliseconds 200

    [pscustomobject]@{ Runspace = $rs; Shell = $ps; Async = $async; Source = $src; State = $state }
}

# Moves the held drag to another client point of -ToHwnd.
function Move-OleFileDrag($Drag, [IntPtr]$ToHwnd, [int]$X, [int]$Y) {
    Send-MouseMove -Hwnd $ToHwnd -X $X -Y $Y -Steps 8
    Start-Sleep -Milliseconds 150
}

# Releases the button (the drop happens here) and tears the source down.
function Stop-OleFileDrag($Drag) {
    Send-MouseUp
    Start-Sleep -Milliseconds 300
    $Drag.State.Stop = $true
    [void]$Drag.Async.AsyncWaitHandle.WaitOne(5000)
    $Drag.Shell.Dispose()
    $Drag.Runspace.Dispose()
}
