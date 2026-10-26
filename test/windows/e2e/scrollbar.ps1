# e2e: milestone=M2 timeout=120 order=400
# scrollbar: with `scrollbar = system` the surface has WS_VSCROLL from the start
# and its width does not change when scrollback appears; 300 lines make the
# scrollback longer than the screen, WM_VSCROLL SB_TOP scrolls to row 0 and
# SB_BOTTOM back. With `scrollbar = never` the surface has no WS_VSCROLL.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

if (-not ('GhosttyE2e.Style' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Style -MemberDefinition @"
[DllImport("user32.dll", EntryPoint = "GetWindowLongW")] public static extern int GetWindowLong(IntPtr h, int index);
[DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
"@
}

$WS_VSCROLL = 0x00200000
$WM_VSCROLL = 0x0115
$SB_TOP = 6
$SB_BOTTOM = 7

function Get-FirstSurface($Class, [scriptblock]$Predicate = { $true }) {
    $s = Wait-GhosttyState -Class $Class -TimeoutSec 15 -Predicate {
        @($_.windows).Count -eq 1 -and @(@($_.windows)[0].tabs).Count -eq 1 -and
        (& $Predicate (@(@($_.windows)[0].tabs)[0].surfaces)[0])
    }.GetNewClosure()
    @(@($s.windows)[0].tabs)[0].surfaces[0]
}

function Get-SurfaceHwnd($Surface) { [IntPtr][Convert]::ToInt64($Surface.hwnd, 16) }

function Get-SurfaceWidth($Surface) {
    $r = $Surface.rect
    $r[2] - $r[0]
}

Invoke-E2eScenario 'scrollbar' {
    $g = Start-E2eGhostty
    $class = $g.Class
    Wait-BashReady $g

    $before = Get-FirstSurface $class
    $hwnd = Get-SurfaceHwnd $before
    $style = [GhosttyE2e.Style]::GetWindowLong($hwnd, -16)
    if (($style -band $WS_VSCROLL) -eq 0) { throw 'scrollbar = system: the surface has no WS_VSCROLL' }
    $widthBefore = Get-SurfaceWidth $before

    [void](Invoke-GhosttyAction -Class $class -Action 'text:seq 1 300\r')
    $filled = Get-FirstSurface $class { param($s) $s.scrollbar.len -gt 0 -and $s.scrollbar.total -gt $s.scrollbar.len }
    Write-E2eInfo ("scrollbar total {0} offset {1} len {2}" -f $filled.scrollbar.total, $filled.scrollbar.offset, $filled.scrollbar.len)
    if ((Get-SurfaceWidth $filled) -ne $widthBefore) {
        throw "the surface width changed from $widthBefore to $(Get-SurfaceWidth $filled) when scrollback appeared"
    }

    [void][GhosttyE2e.Style]::PostMessageW($hwnd, $WM_VSCROLL, [IntPtr]$SB_TOP, [IntPtr]::Zero)
    [void](Get-FirstSurface $class { param($s) $s.scrollbar.offset -eq 0 })
    Start-Sleep -Milliseconds 400
    Save-Evidence 'top' $g -Window
    if (-not (Read-Dump $g.Dump)) { throw 'no frame dump after SB_TOP' }

    [void][GhosttyE2e.Style]::PostMessageW($hwnd, $WM_VSCROLL, [IntPtr]$SB_BOTTOM, [IntPtr]::Zero)
    $bottom = Get-FirstSurface $class { param($s) $s.scrollbar.offset -eq ($s.scrollbar.total - $s.scrollbar.len) }
    Write-E2eInfo ("bottom offset {0}" -f $bottom.scrollbar.offset)

    $errors = @(Get-LogErrors $g)
    if ($errors.Count) { throw "ghostty.log has $($errors.Count) error line(s), first: $($errors[0])" }

    # scrollbar = never: no WS_VSCROLL at all.
    $never = Start-E2eGhostty -ConfigText ($script:BaseConfig + "`nscrollbar = never`n")
    $s2 = Get-FirstSurface $never.Class
    $style2 = [GhosttyE2e.Style]::GetWindowLong((Get-SurfaceHwnd $s2), -16)
    if (($style2 -band $WS_VSCROLL) -ne 0) { throw 'scrollbar = never: the surface still has WS_VSCROLL' }
}
