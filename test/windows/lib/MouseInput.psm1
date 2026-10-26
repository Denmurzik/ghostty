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
[DllImport("user32.dll")] public static extern bool GetCursorPos(ref POINT p);
"@
}

$script:Down = @{ left = 0x0002; right = 0x0008; middle = 0x0020 }
$script:Up = @{ left = 0x0004; right = 0x0010; middle = 0x0040 }
$script:MOVE = 0x0001
$script:ABSOLUTE = 0x8000
$script:VIRTUALDESK = 0x4000

function Send-MouseEvent([int]$Flags, [int]$Nx = 0, [int]$Ny = 0) {
    # A nested struct is returned by value, so fill MOUSEINPUT first and assign it whole.
    $mi = New-Object 'GhosttyE2e.Mouse+MOUSEINPUT'
    $mi.dx = $Nx
    $mi.dy = $Ny
    $mi.dwFlags = [uint32]$Flags
    $i = New-Object 'GhosttyE2e.Mouse+INPUT'
    $i.type = 0
    $i.mi = $mi
    $size = [Runtime.InteropServices.Marshal]::SizeOf([type]'GhosttyE2e.Mouse+INPUT')
    if ([GhosttyE2e.Mouse]::SendInput(1, @($i), $size) -ne 1) {
        throw "SendInput failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
}

function Convert-ClientToScreen([IntPtr]$Hwnd, [int]$X, [int]$Y) {
    $p = New-Object GhosttyE2e.Mouse+POINT
    $p.X = $X
    $p.Y = $Y
    if (-not [GhosttyE2e.Mouse]::ClientToScreen($Hwnd, [ref]$p)) { throw 'ClientToScreen failed' }
    $p
}

# Moves the pointer to a screen point. Absolute coordinates are 0..65535 over
# the virtual desktop.
function Move-MouseToScreen([int]$Sx, [int]$Sy) {
    $vx = [GhosttyE2e.Mouse]::GetSystemMetrics(76)
    $vy = [GhosttyE2e.Mouse]::GetSystemMetrics(77)
    $vw = [GhosttyE2e.Mouse]::GetSystemMetrics(78)
    $vh = [GhosttyE2e.Mouse]::GetSystemMetrics(79)
    $nx = [int](($Sx - $vx) * 65535 / [Math]::Max(1, $vw - 1))
    $ny = [int](($Sy - $vy) * 65535 / [Math]::Max(1, $vh - 1))
    Send-MouseEvent ($script:MOVE -bor $script:ABSOLUTE -bor $script:VIRTUALDESK) $nx $ny
}

function Get-MouseScreenPos {
    $p = New-Object GhosttyE2e.Mouse+POINT
    [void][GhosttyE2e.Mouse]::GetCursorPos([ref]$p)
    $p
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
    $sp = Convert-ClientToScreen $Hwnd $X $Y
    Move-MouseToScreen $sp.X $sp.Y
    Start-Sleep -Milliseconds 40
    $n = if ($Double) { 2 } else { 1 }
    for ($k = 0; $k -lt $n; $k++) {
        Send-MouseEvent $script:Down[$Button]
        Send-MouseEvent $script:Up[$Button]
        if ($k + 1 -lt $n) { Start-Sleep -Milliseconds 40 }
    }
}

# Moves the pointer to (X, Y) in the client coordinates of -Hwnd, or to
# -ScreenX/-ScreenY, in -Steps equal steps from where it is now (a drag needs
# several WM_MOUSEMOVE messages).
function Send-MouseMove {
    param(
        [IntPtr]$Hwnd = [IntPtr]::Zero,
        [int]$X = 0,
        [int]$Y = 0,
        [Nullable[int]]$ScreenX = $null,
        [Nullable[int]]$ScreenY = $null,
        [ValidateRange(1, 1000)][int]$Steps = 1
    )
    if ($null -ne $ScreenX -and $null -ne $ScreenY) {
        $tx = [int]$ScreenX
        $ty = [int]$ScreenY
    } else {
        $sp = Convert-ClientToScreen $Hwnd $X $Y
        $tx = $sp.X
        $ty = $sp.Y
    }
    $from = Get-MouseScreenPos
    for ($k = 1; $k -le $Steps; $k++) {
        Move-MouseToScreen ([int]($from.X + ($tx - $from.X) * $k / $Steps)) ([int]($from.Y + ($ty - $from.Y) * $k / $Steps))
        if ($Steps -gt 1) { Start-Sleep -Milliseconds 15 }
    }
}

# Presses the button at the current pointer position.
function Send-MouseDown {
    param([ValidateSet('left', 'middle', 'right')][string]$Button = 'left')
    Send-MouseEvent $script:Down[$Button]
}

function Send-MouseUp {
    param([ValidateSet('left', 'middle', 'right')][string]$Button = 'left')
    Send-MouseEvent $script:Up[$Button]
}

# Press at (X, Y) of -Hwnd, move to (-ToX, -ToY) of -Hwnd or to the screen
# point (-ToScreenX, -ToScreenY) in -Steps steps, hold -HoldMs, release.
function Send-MouseDrag {
    param(
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [Nullable[int]]$ToX = $null,
        [Nullable[int]]$ToY = $null,
        [Nullable[int]]$ToScreenX = $null,
        [Nullable[int]]$ToScreenY = $null,
        [ValidateRange(1, 1000)][int]$Steps = 1,
        [int]$HoldMs = 0,
        [ValidateSet('left', 'middle', 'right')][string]$Button = 'left'
    )
    if (($null -eq $ToX -or $null -eq $ToY) -and ($null -eq $ToScreenX -or $null -eq $ToScreenY)) {
        throw 'Send-MouseDrag needs -ToX -ToY or -ToScreenX -ToScreenY'
    }
    Send-MouseMove -Hwnd $Hwnd -X $X -Y $Y
    Start-Sleep -Milliseconds 40
    Send-MouseDown -Button $Button
    try {
        Start-Sleep -Milliseconds 40
        if ($null -ne $ToScreenX -and $null -ne $ToScreenY) {
            Send-MouseMove -ScreenX $ToScreenX -ScreenY $ToScreenY -Steps $Steps
        } else {
            Send-MouseMove -Hwnd $Hwnd -X $ToX -Y $ToY -Steps $Steps
        }
        if ($HoldMs -gt 0) { Start-Sleep -Milliseconds $HoldMs }
    } finally {
        Send-MouseUp -Button $Button
    }
}

Export-ModuleMember -Function Send-MouseClick, Send-MouseMove, Send-MouseDown, Send-MouseUp, Send-MouseDrag
