# e2e: milestone=M8 timeout=150 order=1210
# csi8-resize: `CSI 8 ; rows ; cols t` (resize_window) like macOS and GTK. With
# `vt-window-resize-allowed = true` it resizes the window by the surface delta
# only for a lone surface in a single-tab, plain window: not with two tabs, not
# with a split, not for the quick terminal, not while maximized. With the
# default config (false) nothing changes and the log says so. After our own
# resize the pseudo console's echo of the size is swallowed (`stty size` stays).
# The bundled ConPTY is used: the inbox one drops CSI 8 t now and then
# (test/windows/conpty-probe/RESULT.md).
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

if (-not ('GhosttyE2e.Csi8' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Csi8 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
'@
}

$script:Esc8 = 'printf ' + [char]39 + '\033[8;30;100t' + [char]39

function Get-Win($G) {
    $s = Get-GhosttyState -Class $G.Class
    $d = if ($s.PSObject.Properties['data']) { $s.data } else { $s }
    @($d.windows)[0]
}

# "rows cols" from `stty size` in the window $Hwnd; it waits for a fresh file.
function Get-SttySize($G, [IntPtr]$Hwnd, [string]$Name) {
    $f = Join-Path $G.Sandbox.Tmp "$Name.txt"
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    Invoke-SendInput -Hwnd $Hwnd -Keys 'enter'; Start-Sleep -Milliseconds 400
    Send-Line $Hwnd ('stty size > "$TEMP/' + $Name + '.txt"')
    if (-not (Wait-File $f 8)) { throw "stty size did not run ($Name)" }
    Start-Sleep -Milliseconds 200
    (Read-ShellFile $f).Utf8.Trim()
}

function Get-Rect($G) { @((Get-Win $G).window | ForEach-Object { [int]$_ }) -join ',' }

# Sends the request and waits long enough for a resize to show.
function Send-Csi8($Hwnd) {
    Send-Line $Hwnd $script:Esc8
    Start-Sleep -Milliseconds 1200
}

Invoke-E2eScenario 'csi8-resize' {
    $bundled = "windows-conpty = bundled`n"
    $allowed = "vt-window-resize-allowed = true`n"

    # --- default config: nothing changes, the log says why -------------------
    $g = Start-BashE2e -ExtraConfig $bundled
    $before = Get-SttySize $g $g.Hwnd 'def0'
    $rect0 = Get-Rect $g
    Send-Csi8 $g.Hwnd
    if ((Get-Rect $g) -ne $rect0) { throw "default config: the window changed: $rect0 -> $(Get-Rect $g)" }
    $after = Get-SttySize $g $g.Hwnd 'def1'
    if ($after -ne $before) { throw "default config: stty size changed '$before' -> '$after' (the console resized its own buffer on CSI 8 t; Ghostty ignored it)" }
    if (-not (Select-String -LiteralPath $g.Log -SimpleMatch 'resize_window requested, but disabled via config' -Quiet)) {
        throw 'the log has no "resize_window requested, but disabled via config"'
    }
    Invoke-GhosttyAction -Class $g.Class -Action 'close_all_windows' | Out-Null
    [void](Wait-ProcessExit $g 5)

    # --- allowed: a lone surface in a plain window resizes ---------------------
    $g = Start-BashE2e -ExtraConfig ($bundled + $allowed)
    $rect0 = Get-Rect $g
    Send-Csi8 $g.Hwnd
    $got = Get-SttySize $g $g.Hwnd 'ok1'
    if ($got -ne '30 100') { throw "CSI 8;30;100 t gave '$got', expected '30 100' (window $rect0 -> $(Get-Rect $g))" }
    # The echo of the new size from the pseudo console is swallowed: stable.
    Start-Sleep -Milliseconds 1500
    $again = Get-SttySize $g $g.Hwnd 'ok2'
    if ($again -ne '30 100') { throw "the grid did not stay 30 100: '$again'" }

    # --- maximized: unchanged --------------------------------------------------
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_maximize')
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { [GhosttyE2e.Csi8]::IsZoomed($g.Hwnd) })) { throw 'toggle_maximize did not maximize' }
    Start-Sleep -Milliseconds 600
    $max = Get-SttySize $g $g.Hwnd 'max0'
    Send-Line $g.Hwnd ($script:Esc8)
    Start-Sleep -Milliseconds 1200
    if (-not [GhosttyE2e.Csi8]::IsZoomed($g.Hwnd)) { throw 'the window left the maximized state' }
    $max1 = Get-SttySize $g $g.Hwnd 'max1'; if ($max1 -ne $max) { throw "maximized: the grid changed: '$max' -> '$max1'" }
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_maximize')
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { -not [GhosttyE2e.Csi8]::IsZoomed($g.Hwnd) })) { throw 'toggle_maximize did not restore' }
    Start-Sleep -Milliseconds 600

    # --- a split: unchanged ---------------------------------------------------
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_split:right')
    if (-not (Wait-Until -TimeoutSec 10 -PollMs 100 -Condition { @(@((Get-Win $g).tabs)[0].surfaces).Count -eq 2 })) { throw 'the split did not open' }
    Start-Sleep -Milliseconds 800
    $rectS = Get-Rect $g
    Send-Csi8 $g.Hwnd
    if ((Get-Rect $g) -ne $rectS) { throw "split: the window changed: $rectS -> $(Get-Rect $g)" }
    $surfaces = @(@((Get-Win $g).tabs)[0].surfaces)
    [void](Invoke-GhosttyAction -Class $g.Class -Surface $surfaces[1].id -Action 'text:exit\r')
    if (-not (Wait-Until -TimeoutSec 10 -PollMs 100 -Condition { @(@((Get-Win $g).tabs)[0].surfaces).Count -eq 1 })) { throw 'the split did not close' }
    Start-Sleep -Milliseconds 800

    # --- two tabs: unchanged ----------------------------------------------------
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
    if (-not (Wait-Until -TimeoutSec 10 -PollMs 100 -Condition { @((Get-Win $g).tabs).Count -eq 2 })) { throw 'the tab did not open' }
    Start-Sleep -Milliseconds 800
    $rectT = Get-Rect $g
    Send-Csi8 $g.Hwnd
    if ((Get-Rect $g) -ne $rectT) { throw "two tabs: the window changed: $rectT -> $(Get-Rect $g)" }

    # --- the quick terminal: unchanged -------------------------------------------
    $p = Start-Launch $g.Class @('+toggle-quick-terminal')
    if (-not $p.WaitForExit(5000)) { throw 'the +toggle-quick-terminal launch did not finish in 5 s' }
    $q = Wait-Until -TimeoutSec 6 -PollMs 100 -Condition {
        $s = Get-GhosttyState -Class $g.Class
        $d = if ($s.PSObject.Properties['data']) { $s.data } else { $s }
        $x = $d.m3.quick
        if ($x -and $x.shown -and $x.visible -and -not $x.animating) { $x }
    }
    if (-not $q) { throw 'the quick terminal did not show' }
    $qh = [IntPtr][Convert]::ToInt64(([string]$q.hwnd).Substring(2), 16)
    Start-Sleep -Milliseconds 1500
    $qrect = "$($q.rect.x),$($q.rect.y),$($q.rect.w),$($q.rect.h)"
    Send-Csi8 $qh
    $s = Get-GhosttyState -Class $g.Class
    $d = if ($s.PSObject.Properties['data']) { $s.data } else { $s }
    $q2 = $d.m3.quick
    if ("$($q2.rect.x),$($q2.rect.y),$($q2.rect.w),$($q2.rect.h)" -ne $qrect) { throw "quick terminal: the window changed: $qrect" }

    Invoke-GhosttyAction -Class $g.Class -Action 'close_all_windows' | Out-Null
    [void](Wait-ProcessExit $g 5)
}
