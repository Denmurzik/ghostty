# e2e: milestone=M3 timeout=300 order=665
# resize-input: the first line typed after a resize arrives whole. Git Bash
# (MSYS2) sometimes takes in the pseudo console's window-size event only
# with the next input record and loses that record, so `echo` ran as `cho`
# after a split or a window resize. Ghostty sends a Shift key-up ahead of
# the first write after a resize. Each cycle resizes the window, waits,
# types one line and checks the file the line writes, byte for byte. In
# cmd.exe and pwsh the extra key-up must change nothing.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'resize-input' {
    # $Line formats one command that writes {0} to $TEMP/{0}.txt.
    function Invoke-Cycles($G, [string]$Shell, [string]$Line, [int[]]$DelaysMs, [int]$Reps) {
        $bad = New-Object System.Collections.Generic.List[string]
        $w = 900
        $i = 0
        foreach ($d in $DelaysMs) {
            for ($r = 0; $r -lt $Reps; $r++) {
                $n = "$Shell$i"
                $i++
                $w = if ($w -eq 900) { 1100 } else { 900 }
                Set-WindowSize $G.Hwnd $w 600
                Start-Sleep -Milliseconds $d
                [void](Invoke-GhosttyAction -Class $G.Class -Action ('text:' + ($Line -f $n) + '\r'))
                $f = Join-Path $G.Sandbox.Tmp "$n.txt"
                $got = $null
                if (Wait-File $f 5) {
                    [void](Wait-Until -TimeoutSec 2 -PollMs 50 -Condition { (Read-ShellFile $f).Utf8.Trim() })
                    $got = (Read-ShellFile $f).Utf8.Trim()
                }
                if ($got -ne $n) {
                    $bad.Add("$n after $d ms: $(if ($null -eq $got) { 'no file (the line did not run)' } else { "wrote '$got'" })")
                    [void](Invoke-GhosttyAction -Class $G.Class -Action 'text:\x03')
                    Start-Sleep -Milliseconds 400
                }
            }
        }
        Write-E2eInfo "${Shell}: $i cycles, $($bad.Count) bad"
        if ($bad.Count) { throw "${Shell}: input after a resize was not delivered whole: $($bad -join '; ')" }
    }

    # Types the line until one run proves the shell reads input.
    function Wait-ShellReady($G, [string]$Line) {
        for ($k = 0; $k -lt 15; $k++) {
            [void](Invoke-GhosttyAction -Class $G.Class -Action ('text:' + ($Line -f "ready$k") + '\r'))
            if (Wait-File (Join-Path $G.Sandbox.Tmp "ready$k.txt") 2) { Start-Sleep -Milliseconds 500; return }
        }
        throw 'the shell never ran a typed line'
    }

    # --- Git Bash: the losing case. 50 ms is after the state forms; 300 ms
    # is a person typing after a drag.
    $g = Start-BashE2e
    Invoke-Cycles $g 'bash' 'echo {0} > \"$TEMP/{0}.txt\"' @(50, 300) 10
    Invoke-GhosttyAction -Class $g.Class -Action 'close_all_windows' | Out-Null
    [void](Wait-ProcessExit $g 5)

    # --- cmd.exe: the key-up adds nothing to the line ------------------------
    $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'cmd')
    if (-not (Wait-ChildNamed $g @('cmd.exe') 20)) { throw 'cmd did not start' }
    $cmdLine = 'echo {0}> \"%TEMP%/{0}.txt\"'
    Wait-ShellReady $g $cmdLine
    Invoke-Cycles $g 'cmd' $cmdLine @(50, 300) 3
    Invoke-GhosttyAction -Class $g.Class -Action 'close_all_windows' | Out-Null
    [void](Wait-ProcessExit $g 5)

    # --- pwsh (PSReadLine reads key records) ----------------------------------
    if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
        $g = Start-E2eGhostty -ConfigText "command = direct:pwsh.exe -NoLogo -NoProfile`nconfirm-close-surface = false`n"
        if (-not (Wait-ChildNamed $g @('pwsh.exe') 20)) { throw 'pwsh did not start' }
        $pwshLine = 'Set-Content -LiteralPath \"$env:TEMP/{0}.txt\" -Value {0}'
        Wait-ShellReady $g $pwshLine
        Invoke-Cycles $g 'pwsh' $pwshLine @(50, 300) 3
        Invoke-GhosttyAction -Class $g.Class -Action 'close_all_windows' | Out-Null
        [void](Wait-ProcessExit $g 5)
    } else {
        Write-E2eInfo 'pwsh not found; pwsh case skipped'
    }
}
