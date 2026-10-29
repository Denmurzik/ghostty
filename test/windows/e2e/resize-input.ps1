# e2e: milestone=M3 timeout=420 order=665
# resize-input: the first line typed after a resize arrives whole. Git Bash
# (MSYS2) sometimes takes in the pseudo console's window-size event only
# with the next input record and loses that record, so `echo` ran as `cho`
# after a split or a window resize. Ghostty sends a Shift key-up ahead of
# the first write after a resize. Each check types one line and compares
# the file the line writes, byte for byte. The resizes come from the
# window (a drag), a split opening and closing, and the tab strip
# appearing and going (a second tab). In cmd.exe and pwsh the extra
# key-up must change nothing.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'resize-input' {
    $st = @{ Bad = (New-Object System.Collections.Generic.List[string]); Checks = 0; Total = 0; Lost = 0 }
    $variant = if ($env:GHOSTTY_E2E_VARIANT) { $env:GHOSTTY_E2E_VARIANT } else { 'default' }
    # bundled: Git Bash gets the bundled OpenConsole (windows-conpty = bundled)
    # instead of the inbox one that `auto` gives it.
    $bashExtra = if ($variant -eq 'bundled') { 'windows-conpty = bundled' } else { $null }
    try {

    function Get-Win($G) {
        $s = Get-GhosttyState -Class $G.Class
        $d = if ($s.PSObject.Properties['data']) { $s.data } else { $s }
        @($d.windows)[0]
    }
    function Get-SurfaceCount($G) {
        $n = 0
        foreach ($t in @((Get-Win $G).tabs)) { $n += @($t.surfaces).Count }
        $n
    }

    # Types $Line (formats one command that writes {0} to $TEMP/{0}.txt)
    # into $Surface (0: the focused one) and checks the file.
    function Test-Line($G, [string]$Line, [string]$Name, [string]$What, [int]$Surface = 0) {
        $st.Checks++
        $st.Total++
        [void](Invoke-GhosttyAction -Class $G.Class -Surface $Surface -Action ('text:' + ($Line -f $Name) + '\r'))
        $f = Join-Path $G.Sandbox.Tmp "$Name.txt"
        $got = $null
        if (Wait-File $f 5) {
            [void](Wait-Until -TimeoutSec 2 -PollMs 50 -Condition { (Read-ShellFile $f).Utf8.Trim() })
            $got = (Read-ShellFile $f).Utf8.Trim()
        }
        if ($got -ne $Name) {
            $st.Lost++
            $st.Bad.Add("$Name ($What): $(if ($null -eq $got) { 'no file (the line did not run)' } else { "wrote '$got'" })")
            [void](Invoke-GhosttyAction -Class $G.Class -Surface $Surface -Action 'text:\x03')
            Start-Sleep -Milliseconds 400
        }
    }

    # Window resizes (a drag), then a line after each.
    function Invoke-Cycles($G, [string]$Shell, [string]$Line, [int[]]$DelaysMs, [int]$Reps) {
        $w = 900
        $i = 0
        foreach ($d in $DelaysMs) {
            for ($r = 0; $r -lt $Reps; $r++) {
                $w = if ($w -eq 900) { 1100 } else { 900 }
                Set-WindowSize $G.Hwnd $w 600
                Start-Sleep -Milliseconds $d
                Test-Line $G $Line "$Shell$i" "window resize, $d ms"
                $i++
            }
        }
    }

    # Types the line until one run proves the shell reads input.
    function Wait-ShellReady($G, [string]$Line, [int]$Surface = 0) {
        for ($k = 0; $k -lt 15; $k++) {
            $n = "ready$([guid]::NewGuid().ToString('N').Substring(0, 6))"
            [void](Invoke-GhosttyAction -Class $G.Class -Surface $Surface -Action ('text:' + ($Line -f $n) + '\r'))
            if (Wait-File (Join-Path $G.Sandbox.Tmp "$n.txt") 2) { Start-Sleep -Milliseconds 500; return }
        }
        throw 'the shell never ran a typed line'
    }

    function Assert-NoBad([string]$Shell) {
        Write-E2eInfo "${Shell}: $($st.Checks) checks, $($st.Bad.Count) bad"
        if ($st.Bad.Count) { throw "${Shell}: input after a resize was not delivered whole: $($st.Bad -join '; ')" }
        $st.Checks = 0
    }

    # --- Git Bash: the losing case. 50 ms is after the state forms; 300 ms
    # is a person typing after a drag.
    $bashLine = 'echo {0} > \"$TEMP/{0}.txt\"'
    $g = Start-BashE2e -ExtraConfig $bashExtra
    Invoke-Cycles $g 'bash' $bashLine @(50, 300) 10
    $first = @(@((Get-Win $g).tabs)[0].surfaces)[0].id

    # A split opening halves the first pane; its shell closing gives the
    # width back. A line into the first pane after each.
    for ($i = 0; $i -lt 4; $i++) {
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_split:right')
        if (-not (Wait-Until -TimeoutSec 10 -PollMs 100 -Condition { (Get-SurfaceCount $g) -eq 2 })) { throw 'the split did not open' }
        $split = @(@(@((Get-Win $g).tabs)[0].surfaces) | Where-Object { $_.id -ne $first })[0].id
        Start-Sleep -Milliseconds 300
        Test-Line $g $bashLine "split$i" 'split opened' $first
        Wait-ShellReady $g $bashLine $split
        [void](Invoke-GhosttyAction -Class $g.Class -Surface $split -Action 'text:exit\r')
        if (-not (Wait-Until -TimeoutSec 10 -PollMs 100 -Condition { (Get-SurfaceCount $g) -eq 1 })) { throw 'the split did not close' }
        Start-Sleep -Milliseconds 300
        Test-Line $g $bashLine "unsplit$i" 'split closed' $first
    }

    # A second tab brings the tab strip, which shortens the first tab's
    # pane when it is shown again; closing the tab takes the strip away.
    for ($i = 0; $i -lt 4; $i++) {
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
        if (-not (Wait-Until -TimeoutSec 10 -PollMs 100 -Condition { @((Get-Win $g).tabs).Count -eq 2 })) { throw 'the tab did not open' }
        $tab2 = @(@((Get-Win $g).tabs)[1].surfaces)[0].id
        Wait-ShellReady $g $bashLine $tab2
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'goto_tab:1')
        Start-Sleep -Milliseconds 300
        Test-Line $g $bashLine "tabback$i" 'first tab shown again' $first
        [void](Invoke-GhosttyAction -Class $g.Class -Surface $tab2 -Action 'text:exit\r')
        if (-not (Wait-Until -TimeoutSec 10 -PollMs 100 -Condition { @((Get-Win $g).tabs).Count -eq 1 })) { throw 'the tab did not close' }
        Start-Sleep -Milliseconds 300
        Test-Line $g $bashLine "tabgone$i" 'tab strip gone' $first
    }
    Assert-NoBad 'bash'
    Invoke-GhosttyAction -Class $g.Class -Action 'close_all_windows' | Out-Null
    [void](Wait-ProcessExit $g 5)

    # --- cmd.exe: the key-up adds nothing to the line ------------------------
    $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'cmd')
    if (-not (Wait-ChildNamed $g @('cmd.exe') 20)) { throw 'cmd did not start' }
    $cmdLine = 'echo {0}> \"%TEMP%/{0}.txt\"'
    Wait-ShellReady $g $cmdLine
    Invoke-Cycles $g 'cmd' $cmdLine @(50, 300) 3
    Assert-NoBad 'cmd'
    Invoke-GhosttyAction -Class $g.Class -Action 'close_all_windows' | Out-Null
    [void](Wait-ProcessExit $g 5)

    # --- pwsh (PSReadLine reads key records) ----------------------------------
    if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
        $g = Start-E2eGhostty -ConfigText "command = direct:pwsh.exe -NoLogo -NoProfile`nconfirm-close-surface = false`n"
        if (-not (Wait-ChildNamed $g @('pwsh.exe') 20)) { throw 'pwsh did not start' }
        $pwshLine = 'Set-Content -LiteralPath \"$env:TEMP/{0}.txt\" -Value {0}'
        Wait-ShellReady $g $pwshLine
        Invoke-Cycles $g 'pwsh' $pwshLine @(50, 300) 3
        Assert-NoBad 'pwsh'
        Invoke-GhosttyAction -Class $g.Class -Action 'close_all_windows' | Out-Null
        [void](Wait-ProcessExit $g 5)
    } else {
        Write-E2eInfo 'pwsh not found; pwsh case skipped'
    }
    } finally {
        Write-E2eInfo "resize-input variant=$variant lost=$($st.Lost)/$($st.Total)"
    }
}
