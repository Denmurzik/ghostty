# e2e: milestone=M2 timeout=120 order=200
# ipc-state: the IPC pipe answers from startup. `state` describes one window,
# one tab and one surface whose HWND is below the window; `action` types into
# the shell; the test-ops variable is not inherited by the shell; a Ghostty
# without it refuses the test ops.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

if (-not ('GhosttyE2e.Parent' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Parent -MemberDefinition @"
[DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
"@
}

function ConvertTo-HwndText([IntPtr]$Hwnd) { '0x{0:x}' -f $Hwnd.ToInt64() }

Invoke-E2eScenario 'ipc-state' {
    $g = Start-E2eGhostty
    $class = $g.Class

    $s = Wait-GhosttyState -Class $class -TimeoutSec 15 -Predicate { @($_.windows).Count -eq 1 }
    if (-not $s.serving) { throw 'state.serving is false' }
    if ($s.class -ne $class) { throw "state.class is '$($s.class)', expected '$class'" }
    $windows = @($s.windows)
    $tabs = @($windows[0].tabs)
    if ($tabs.Count -ne 1) { throw "expected 1 tab, got $($tabs.Count)" }
    $surfaces = @($tabs[0].surfaces)
    if ($surfaces.Count -ne 1) { throw "expected 1 surface, got $($surfaces.Count)" }
    if ($windows[0].hwnd -ne (ConvertTo-HwndText $g.Hwnd)) {
        throw "state window hwnd $($windows[0].hwnd) is not the harness window $(ConvertTo-HwndText $g.Hwnd)"
    }
    $child = [IntPtr][Convert]::ToInt64($surfaces[0].hwnd, 16)
    $parent = [GhosttyE2e.Parent]::GetParent($child)
    # The surface is a child of the tab container, itself a child of the window.
    $grand = [GhosttyE2e.Parent]::GetParent($parent)
    if ($parent -ne $g.Hwnd -and $grand -ne $g.Hwnd) {
        throw "surface hwnd $($surfaces[0].hwnd) is not below the window (parent $parent, grandparent $grand)"
    }
    if (-not $surfaces[0].focused) { throw 'the only surface is not focused' }
    Write-E2eInfo ("state: window {0}, tab {1}, surface {2}, dpi {3}" -f $windows[0].hwnd, $tabs[0].id, $surfaces[0].id, $windows[0].dpi)

    Wait-BashReady $g
    $ok = Join-Path $g.Sandbox.Tmp 'gt-ipc.txt'
    if (-not (Invoke-GhosttyAction -Class $class -Action 'text:echo ipc-ok> "$TEMP/gt-ipc.txt"\r')) {
        throw 'the text action was not performed'
    }
    if (-not (Wait-File $ok 20)) { throw 'gt-ipc.txt never appeared' }
    if ((Get-Content -LiteralPath $ok -Raw) -notmatch 'ipc-ok') { throw 'gt-ipc.txt does not contain ipc-ok' }

    # The shell must not inherit the test-ops switch (env lists what it has).
    $envFile = Join-Path $g.Sandbox.Tmp 'gt-env.txt'
    [void](Invoke-GhosttyAction -Class $class -Action 'text:env > "$TEMP/gt-env.txt"\r')
    if (-not (Wait-File $envFile 20)) { throw 'gt-env.txt never appeared' }
    Start-Sleep -Milliseconds 300
    $envText = Get-Content -LiteralPath $envFile -Raw
    if ($envText -notmatch '(?m)^HOME=') { throw 'env output looks incomplete (no HOME)' }
    if ($envText -match 'GHOSTTY_WIN32_TEST_IPC') { throw 'the shell inherited GHOSTTY_WIN32_TEST_IPC' }

    # Without the variable the test ops do not exist (code 2).
    $plain = Start-E2eGhostty -NoTestIpc
    $r = Invoke-GhosttyIpc -Class $plain.Class -Request @{ op = 'state' }
    if ($r.code -ne 2) { throw "state without test ops answered code $($r.code), expected 2" }
    $r = Invoke-GhosttyIpc -Class $plain.Class -Request @{ op = 'action'; action = 'text:x' }
    if ($r.code -ne 2) { throw "action without test ops answered code $($r.code), expected 2" }
}
