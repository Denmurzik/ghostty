# e2e: milestone=M2 timeout=120 order=320
# tab-rename: a double click on a tab opens an inline Edit control over it;
# Enter commits (the tab title changes), Esc cancels, an empty commit would
# clear the title. The prompt_surface_title action opens the editor too, and
# its commit sets the surface title.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

if (-not ('GhosttyE2e.EditProbe' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name EditProbe -MemberDefinition @"
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
"@
}

Invoke-E2eScenario 'tab-rename' {
    $g = Start-E2eGhostty -ConfigText "confirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = always`n"
    if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "no frame dump at $($g.Dump)" }
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)

    function Get-Win {
        $d = Get-GhosttyState -Class $g.Class
        @($d.windows)[0]
    }
    function Wait-Win([string]$What, [scriptblock]$Predicate, [double]$TimeoutSec = 6) {
        $w = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
            $w = Get-Win
            if ($w -and (& $Predicate $w)) { $w }
        }
        if (-not $w) { throw "timeout waiting for: $What; state: $(Get-Win | ConvertTo-Json -Depth 8 -Compress)" }
        $w
    }
    function Get-Centre($R) { , @([int](($R[0] + $R[2]) / 2), [int](($R[1] + $R[3]) / 2)) }
    function Get-Edit { [GhosttyE2e.EditProbe]::FindWindowExW($g.Hwnd, [IntPtr]::Zero, 'Edit', $null) }
    function Wait-Edit([bool]$Present, [string]$What) {
        $ok = Wait-Until -TimeoutSec 4 -PollMs 50 -Condition { ((Get-Edit) -ne [IntPtr]::Zero) -eq $Present }
        if (-not $ok) { throw "$What : the Edit control is $(if ($Present) { 'missing' } else { 'still there' })" }
    }

    # 1. Double click on the tab, type, Enter.
    $w = Get-Win
    $c = Get-Centre @($w.strip.tabs)[0]
    Send-MouseClick -Hwnd $g.Hwnd -X ($c[0] - 40) -Y $c[1] -Double
    Wait-Edit $true 'double click'
    Invoke-SendInput -Hwnd $g.Hwnd -Text 'renamed'
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
    Wait-Edit $false 'Enter'
    $w = Wait-Win 'tab title renamed' { param($w) @($w.tabs)[0].title -eq 'renamed' }
    $caption = Wait-Until -TimeoutSec 4 -PollMs 100 -Condition {
        $t = [GhosttyE2e.Win]::TextOf($g.Hwnd)
        if ($t -eq 'renamed') { $t }
    }
    if (-not $caption) { throw "window caption '$([GhosttyE2e.Win]::TextOf($g.Hwnd))', want 'renamed'" }

    # 2. Again, type, Esc: unchanged.
    $c = Get-Centre @($w.strip.tabs)[0]
    Send-MouseClick -Hwnd $g.Hwnd -X ($c[0] - 40) -Y $c[1] -Double
    Wait-Edit $true 'second double click'
    Invoke-SendInput -Hwnd $g.Hwnd -Text 'discarded'
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'esc'
    Wait-Edit $false 'Esc'
    Start-Sleep -Milliseconds 300
    $w = Get-Win
    if (@($w.tabs)[0].title -ne 'renamed') { throw "Esc changed the title to '$(@($w.tabs)[0].title)'" }

    # 3. prompt_surface_title opens the editor, Enter sets the surface title.
    if (-not (Invoke-GhosttyAction -Class $g.Class -Action 'prompt_surface_title')) { throw 'prompt_surface_title was not performed' }
    Wait-Edit $true 'prompt_surface_title'
    Invoke-SendInput -Hwnd $g.Hwnd -Text 'surf'
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
    Wait-Edit $false 'Enter after prompt_surface_title'
    $w = Wait-Win 'surface title surf' { param($w) @(@($w.tabs)[0].surfaces)[0].title -eq 'surf' }

    # 4. An empty commit on the tab clears the user's title.
    $c = Get-Centre @($w.strip.tabs)[0]
    Send-MouseClick -Hwnd $g.Hwnd -X ($c[0] - 40) -Y $c[1] -Double
    Wait-Edit $true 'third double click'
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'backspace'
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
    Wait-Edit $false 'Enter with empty text'
    [void](Wait-Win 'title back to the surface title' { param($w) @($w.tabs)[0].title -eq 'surf' })

    Save-Evidence -Tag 'tab-rename' -G $g -Window
}
