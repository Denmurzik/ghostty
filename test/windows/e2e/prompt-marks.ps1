# e2e: milestone=M5 timeout=300 order=700
# prompt-marks: OSC 133 prompt marks arrive from Git Bash, pwsh and cmd.
# After `echo a`, a long output and a failing command, `jump_to_prompt:-1`
# moves the viewport. Git Bash and pwsh report command_finished with the exit
# code (cmd's D has none: a documented gap). No unknown OSC 133 in the log;
# Git Bash's PATH has no stray `C` entry after a nested `bash -i` (the `path`
# feature is skipped under MSYS).
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

$script:Notify = "`nnotify-on-command-finish = always`nnotify-on-command-finish-after = 0s`nnotify-on-command-finish-action = no-bell,notify`n"

function Get-Offset($G) {
    $d = Get-GhosttyState -Class $G.Class
    foreach ($t in @(@($d.windows)[0].tabs)) {
        foreach ($s in @($t.surfaces)) { if ($s.focused) { return [int]$s.scrollbar.offset } }
    }
    -1
}

function Wait-Exit3($G, [string]$What) {
    $ok = Wait-Until -TimeoutSec 15 -PollMs 150 -Condition {
        @((Get-GhosttyState -Class $G.Class).m3.notify.recorded) |
            Where-Object { $_.title -eq 'Command Failed' -and $_.body -like '*exited with code 3*' } |
            Select-Object -First 1
    }
    if (-not $ok) {
        Save-Evidence -Tag "marks-$($What -replace 's','-')" -G $G
        throw "$What : no command_finished with exit 3, state: $((Get-GhosttyState -Class $G.Class).m3.notify | ConvertTo-Json -Compress -Depth 6)"
    }
}

# Two commands around a long output, then the jump.
function Test-Marks($G, [string]$What, [string]$Echo, [string]$Long, [string]$Fail, [bool]$ExpectExit) {
    [void](Set-ForegroundSafe -Hwnd $G.Hwnd)
    Send-Line $G.Hwnd $Echo
    Start-Sleep -Milliseconds 700
    Send-Line $G.Hwnd $Long
    Start-Sleep -Milliseconds 1200
    Send-Line $G.Hwnd $Fail
    Start-Sleep -Milliseconds 1200
    if ($ExpectExit) { Wait-Exit3 $G $What }
    $before = Get-Offset $G
    [void](Invoke-GhosttyAction -Class $G.Class -Action 'jump_to_prompt:-1')
    $moved = Wait-Until -TimeoutSec 8 -PollMs 150 -Condition { (Get-Offset $G) -ne $before }
    if (-not $moved) { throw "$What : jump_to_prompt:-1 did not move the viewport (offset stays $before)" }
    if (Test-Path -LiteralPath $G.Log) {
        $bad = @(Select-String -LiteralPath $G.Log -Pattern 'unknown OSC 133' | ForEach-Object { $_.Line })
        if ($bad.Count) { throw "$What : $($bad.Count) unknown OSC 133 line(s): $($bad[0])" }
    }
}

Invoke-E2eScenario 'prompt-marks' {
    # --- Git Bash ---
    $g = Start-BashE2e -ExtraConfig $script:Notify
    Test-Marks $g 'git bash' 'echo a' 'seq 1 150' 'false' $false
    Stop-OwnGhostty

    # A failing command in Git Bash reports 1; exit 3 comes from a subshell.
    $g = Start-BashE2e -ExtraConfig $script:Notify
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
    Send-Line $g.Hwnd '(exit 3)'
    Wait-Exit3 $g 'git bash'
    # The path feature is skipped under MSYS: no `C` entry from `C:/...`.
    $out = Join-Path $g.Sandbox.Tmp 'path-count.txt'
    Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
    Send-Line $g.Hwnd 'bash -i'
    Start-Sleep -Seconds 3
    # A bare `C` entry can come from the host PATH itself (a `C:/c/...` entry), so the
    # check is for the fragment the path feature would leave: `/D/...` from `C:/D/...`.
    Send-Line $g.Hwnd 'echo "$PATH" > "$TEMP/path-full.txt"; echo "$PATH" | tr : "\n" | grep -cE "^/[A-Z]/" > "$TEMP/path-count.txt"; exit'
    if (-not (Wait-File $out 15)) { throw 'git bash: no PATH count written' }
    $n = ([IO.File]::ReadAllText($out)).Trim()
    if ($n -ne '0') { throw "git bash: PATH has $n drive-fragment entries, expected 0: $([IO.File]::ReadAllText((Join-Path $g.Sandbox.Tmp 'path-full.txt')))" }
    Stop-OwnGhostty

    # --- pwsh 7 and Windows PowerShell 5.1 (an older PSReadLine) ---
    foreach ($exe in 'pwsh.exe', 'powershell.exe') {
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
            Write-E2eInfo "$exe not found; case skipped"
            continue
        }
        $g = Start-E2eGhostty -ConfigText ("command = direct:$exe -NoLogo`nconfirm-close-surface = false`n" + $script:Notify)
        if (-not (Wait-ChildNamed $g @($exe) 20)) { throw "$exe did not start" }
        Start-Sleep -Seconds 3
        Test-Marks $g $exe 'echo a' '1..150' 'cmd /c exit 3' $true
        # The same failing command again still reports its own code.
        Send-Line $g.Hwnd 'cmd /c exit 3'
        $two = Wait-Until -TimeoutSec 15 -PollMs 150 -Condition {
            @(@((Get-GhosttyState -Class $g.Class).m3.notify.recorded) | Where-Object { $_.body -like '*exited with code 3*' }).Count -ge 2
        }
        if (-not $two) { throw "$exe : the repeated exit 3 was not reported" }
        Stop-OwnGhostty
    }

    # --- cmd (no exit code in D: no command_finished with a code) ---
    $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'cmd')
    if (-not (Wait-ChildNamed $g @('cmd.exe') 20)) { throw 'cmd did not start' }
    Start-Sleep -Seconds 1
    Test-Marks $g 'cmd' 'echo a' 'for /l %i in (1,1,150) do @echo %i' 'cmd /c exit 3' $false
}
