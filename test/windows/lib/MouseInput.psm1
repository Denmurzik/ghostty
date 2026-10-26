# Mouse input through SendInput. Only for use inside a scenario that holds the
# GUI lock: it moves the real pointer. Keep this file ASCII only.
Set-StrictMode -Version Latest

if (-not ('GhosttyE2e.Mouse' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Mouse -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
    public int dx, dy; public uint mouseData, dwFlags, time; public UIntPtr dwExtraInfo;
}
[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public MOUSEINPUT mi; }
[DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
[DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
"@
}

$script:Down = @{ left = 0x0002; right = 0x0008; middle = 0x0020 }
$script:Up = @{ left = 0x0004; right = 0x0010; middle = 0x0040 }
$script:MOVE = 0x0001
$script:ABSOLUTE = 0x8000
$script:VIRTUALDESK = 0x4000

function Send-MouseEvent([int]$Flags, [int]$Nx = 0, [int]$Ny = 0) {
    $i = New-Object 'GhosttyE2e.Mouse+INPUT'
    $i.type = 0
    $i.mi.dx = $Nx
    $i.mi.dy = $Ny
    $i.mi.dwFlags = [uint32]$Flags
    $size = [Runtime.InteropServices.Marshal]::SizeOf([type]'GhosttyE2e.Mouse+INPUT')
    if ([GhosttyE2e.Mouse]::SendInput(1, @($i), $size) -ne 1) {
        throw "SendInput failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
}

# Click at (X, Y) in the client coordinates of -Hwnd; -Double sends two clicks
# inside the double-click time.
function Send-MouseClick {
    param(
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [ValidateSet('left', 'middle', 'right')][string]$Button = 'left',
        [switch]$Double
    )
    $p = New-Object GhosttyE2e.Mouse+POINT
    $p.X = $X
    $p.Y = $Y
    if (-not [GhosttyE2e.Mouse]::ClientToScreen($Hwnd, [ref]$p)) { throw 'ClientToScreen failed' }

    # Absolute coordinates are 0..65535 over the virtual desktop.
    $vx = [GhosttyE2e.Mouse]::GetSystemMetrics(76)
    $vy = [GhosttyE2e.Mouse]::GetSystemMetrics(77)
    $vw = [GhosttyE2e.Mouse]::GetSystemMetrics(78)
    $vh = [GhosttyE2e.Mouse]::GetSystemMetrics(79)
    $nx = [int](($p.X - $vx) * 65535 / [Math]::Max(1, $vw - 1))
    $ny = [int](($p.Y - $vy) * 65535 / [Math]::Max(1, $vh - 1))

    Send-MouseEvent ($script:MOVE -bor $script:ABSOLUTE -bor $script:VIRTUALDESK) $nx $ny
    Start-Sleep -Milliseconds 40
    $n = if ($Double) { 2 } else { 1 }
    for ($k = 0; $k -lt $n; $k++) {
        Send-MouseEvent $script:Down[$Button]
        Send-MouseEvent $script:Up[$Button]
        if ($k + 1 -lt $n) { Start-Sleep -Milliseconds 40 }
    }
}

Export-ModuleMember -Function Send-MouseClick
