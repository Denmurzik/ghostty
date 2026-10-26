# e2e: milestone=M2 timeout=150 order=360
# windows-multi: new_window cascades from the first window, goto_window
# changes the foreground window, move_tab_to_new_window keeps the surface's
# hwnd and its shell, close_window / close_all_windows end the process, and
# the window class has the exe's icon.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

if (-not ('GhosttyE2e.Multi' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Multi -MemberDefinition @"
[DllImport("user32.dll", EntryPoint = "GetClassLongPtrW")] public static extern IntPtr GetClassLongPtr(IntPtr h, int index);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr LoadIconW(IntPtr inst, IntPtr name);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
[DllImport("user32.dll")] public static extern int GetSystemMetricsForDpi(int index, uint dpi);
"@
}

Invoke-E2eScenario 'windows-multi' {
    $g = Start-BashE2e

    function Get-Wins {
        $r = Get-GhosttyState -Class $g.Class
        $d = if ($r.PSObject.Properties['data']) { $r.data } else { $r }
        @($d.windows)
    }
    function Wait-Wins([string]$What, [scriptblock]$Predicate, [double]$TimeoutSec = 10) {
        $w = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
            $all = @(Get-Wins)
            if (& $Predicate $all) { , $all }
        }
        if (-not $w) { throw "timeout waiting for: $What; state: $((Get-Wins) | ConvertTo-Json -Depth 8 -Compress)" }
        $w
    }
    function Invoke-Act([string]$Action) {
        [void](Invoke-GhosttyAction -Class $g.Class -Action $Action)
    }

    $first = (Get-Wins)[0]
    $firstId = $first.id

    # 1. new_window: a second window, cascaded by the caption height.
    Invoke-Act 'new_window'
    $wins = Wait-Wins 'two windows' { param($a) $a.Count -eq 2 }
    $second = @($wins | Where-Object { $_.id -ne $firstId })[0]
    $dpi = [GhosttyE2e.Multi]::GetDpiForWindow([IntPtr][Convert]::ToInt64($first.hwnd, 16))
    $step = [GhosttyE2e.Multi]::GetSystemMetricsForDpi(4, $dpi)   # SM_CYCAPTION
    $dx = $second.window[0] - $first.window[0]
    $dy = $second.window[1] - $first.window[1]
    if ($dx -eq $step -and $dy -eq $step) {
        Write-E2eInfo "second window cascaded by $step px"
    } elseif ($second.window[0] -eq 0 -or $second.window[1] -eq 0 -or $dx -le 0) {
        # The cascade wrapped to the work area's origin.
        Write-E2eInfo "second window wrapped: ($($second.window[0]), $($second.window[1]))"
    } else {
        throw "second window origin delta ($dx, $dy), want ($step, $step)"
    }

    # 2. goto_window:next changes the foreground window (interactive only:
    # a background process may be refused the foreground).
    $fg = [GhosttyE2e.Multi]::GetForegroundWindow()
    Invoke-Act 'goto_window:next'
    $changed = Wait-Until -TimeoutSec 3 -PollMs 100 -Condition { [GhosttyE2e.Multi]::GetForegroundWindow() -ne $fg }
    if (-not $changed) { Write-E2eInfo 'goto_window: foreground unchanged (focus stealing prevention?)' }

    # 3. close the second window.
    Invoke-Act 'close_window'
    [void](Wait-Wins 'back to one window' { param($a) $a.Count -eq 1 })
    $last = (Get-Wins)[0]
    $lastHwnd = [IntPtr][Convert]::ToInt64($last.hwnd, 16)

    # 4. Two tabs in the window; move the active one to a new window.
    Invoke-Act 'new_tab'
    $w = Wait-Wins 'two tabs' { param($a) @($a[0].tabs).Count -eq 2 }
    $surf = @($w[0].tabs)[1].surfaces[0]
    $hwndBefore = $surf.hwnd
    $sid = $surf.id
    Invoke-Act 'move_tab_to_new_window'
    $w = Wait-Wins 'two windows, one tab each' { param($a) $a.Count -eq 2 -and @($a[0].tabs).Count -eq 1 -and @($a[1].tabs).Count -eq 1 }
    $moved = $null
    foreach ($win in $w) {
        foreach ($t in @($win.tabs)) {
            foreach ($s in @($t.surfaces)) { if ($s.id -eq $sid) { $moved = $s } }
        }
    }
    if (-not $moved) { throw "surface $sid not found after the move" }
    if ($moved.hwnd -ne $hwndBefore) { throw "surface hwnd changed: $hwndBefore -> $($moved.hwnd)" }

    # The moved shell is alive: it answers the focused surface.
    $ok = Join-Path $g.Sandbox.Tmp 'gt-multi.txt'
    Remove-Item -LiteralPath $ok -ErrorAction SilentlyContinue
    Invoke-Act 'text:echo moved-ok> "$TEMP/gt-multi.txt"\r'
    if (-not (Wait-File $ok 20)) { throw 'the moved shell never answered' }

    # 5. The class icon is the exe's, not the generic application icon.
    $icon = [GhosttyE2e.Multi]::GetClassLongPtr($lastHwnd, -14)   # GCLP_HICON
    $generic = [GhosttyE2e.Multi]::LoadIconW([IntPtr]::Zero, [IntPtr]32512)   # IDI_APPLICATION
    if ($icon -eq [IntPtr]::Zero -or $icon -eq $generic) { throw "window class icon $icon is the generic one ($generic)" }

    # 6. close_all_windows ends the process (quit-after-last-window-closed).
    Invoke-Act 'close_all_windows'
    $exit = Wait-ProcessExit $g 3
    Write-E2eInfo "ghostty exited after $($exit.Ms) ms"
    if (-not $exit.Exited) { throw 'ghostty still running 3 s after close_all_windows' }
}
