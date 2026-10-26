# e2e: milestone=M2 timeout=360 order=470
# drop-files: files and folders dragged from an OLE source onto a surface are
# pasted as shell-quoted, space-separated paths: msys paths in Git Bash, the
# Windows paths in pwsh and cmd. There is no highlight (as on macOS);
# the drop never presses Enter; in a two-split tab the text lands
# in the split under the pointer, which becomes focused; the tab strip refuses
# the drop. Interactive desktop only (a real OLE drag with the real mouse).
# Keep this file ASCII only (Windows PowerShell 5.1 reads a BOM-less script as ANSI).
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')
. (Join-Path $PSScriptRoot '_drop.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force

# The five paths of the scenario, created in the sandbox: a plain name with a
# space, quotes/ampersand/parentheses, Cyrillic, a folder, and a path longer
# than 260 characters (made and passed with the \\?\ prefix).
function New-DropFiles([string]$Root) {
    $cyrDir = ConvertFrom-CodePoints @(0x420, 0x430, 0x431, 0x43E, 0x447, 0x430, 0x44F, 0x20, 0x43F, 0x430, 0x43F, 0x43A, 0x430)
    $cyrFile = ConvertFrom-CodePoints @(0x444, 0x430, 0x439, 0x43B, 0x2E, 0x74, 0x78, 0x74)
    $base = Join-Path $Root 'drop'
    [void](New-Item -ItemType Directory -Force -Path $base)
    $a = Join-Path $base 'a b.txt'
    $b = Join-Path $base "it's & (x).txt"
    $c = Join-Path (Join-Path $base $cyrDir) $cyrFile
    $d = Join-Path $base 'dir with space'
    $longDir = '\\?\' + (Join-Path (Join-Path (Join-Path $base ('d' * 100)) ('e' * 100)) ('f' * 60))
    $e = $longDir + '\long.txt'
    foreach ($f in @($a, $b)) { Set-Content -LiteralPath $f -Value 'x' }
    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $c))
    Set-Content -LiteralPath $c -Value 'x'
    [void](New-Item -ItemType Directory -Force -Path $d)
    [void][IO.Directory]::CreateDirectory($longDir)
    [IO.File]::WriteAllText($e, 'x')
    if ($e.Length -le 260) { throw "the long path is only $($e.Length) characters" }
    @($a, $b, $c, $d, $e)
}

# What Git Bash should receive for one Windows path: C:\a\b -> /c/a/b,
# a \\?\ prefix dropped.
function ConvertTo-MsysPath([string]$p) {
    if ($p.StartsWith('\\?\')) { $p = $p.Substring(4) }
    if ($p -match '^([A-Za-z]):(.*)$') { $p = '/' + $Matches[1].ToLowerInvariant() + $Matches[2] }
    $p.Replace('\', '/')
}


function Read-OracleLines([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = (New-Object Text.UTF8Encoding $false).GetString($bytes).TrimStart([char]0xFEFF)
    @($text -split "`r?`n" | Where-Object { $_ -ne '' })
}

# One shell: type -Prefix, drop the five paths, check nothing ran, type -Suffix
# + Enter, and compare the oracle file with -Expected (for each line, any of
# the alternatives of that entry).
function Invoke-DropCase($G, [string]$Name, [string]$Prefix, [string]$Suffix, [string[]]$Files, [object[]]$Expected) {
    $oracle = Join-Path $G.Sandbox.Tmp 'gt-drop.txt'
    Remove-Item -LiteralPath $oracle -Force -ErrorAction SilentlyContinue
    Send-Typed $G.Hwnd $Prefix
    Start-Sleep -Milliseconds 400

    $st = Get-SplitState $G
    $box = (Get-SurfaceBoxes $st)[0]
    $cx = [int](($box.L + $box.R) / 2)
    $cy = [int](($box.T + $box.B) / 2)

    $drag = Start-OleFileDrag -Files $Files -ToHwnd $G.Hwnd -X $cx -Y $cy
    try {
        Start-Sleep -Milliseconds 200
        Save-Evidence "$Name-middrag" $G -Window
    } finally {
        Stop-OleFileDrag $drag
    }
    Start-Sleep -Milliseconds 1200
    if (Test-Path -LiteralPath $oracle) { throw "$Name : the oracle file exists before the line was completed (the drop pressed Enter)" }
    Save-Evidence "$Name-dropped" $G -Window

    Send-Typed $G.Hwnd $Suffix
    Invoke-SendInput -Hwnd $G.Hwnd -Keys 'enter'
    if (-not (Wait-File $oracle 20)) { Save-Evidence "$Name-fail" $G -Window; throw "$Name : the oracle file was not written" }
    Start-Sleep -Milliseconds 500
    $lines = Read-OracleLines $oracle
    if ($lines.Count -ne $Expected.Count) {
        throw "$Name : expected $($Expected.Count) lines, got $($lines.Count): $($lines -join ' | ')"
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (@($Expected[$i]) -notcontains $lines[$i]) {
            throw "$Name : line $i is '$($lines[$i])', expected '$(@($Expected[$i]) -join "' or '")'"
        }
    }
}

Invoke-E2eScenario 'drop-files' {
    $tmp = $script:Sbx.Tmp
    $files = New-DropFiles $tmp
    $ran = 0

    # --- Git Bash: msys paths ---------------------------------------------------
    if (Find-GitBash) {
        $g = Start-BashE2e 'unsafe-paste'
        if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
        $expected = @($files | ForEach-Object { ConvertTo-MsysPath $_ })
        $bash = Find-GitBash
        $cyg = Join-Path (Split-Path -Parent (Split-Path -Parent $bash)) 'usr\bin\cygpath.exe'
        if (Test-Path -LiteralPath $cyg) {
            # Cross-check the rule with cygpath for the paths it can express.
            foreach ($i in 0..3) {
                # cygpath -u would alias the sandbox TEMP to /tmp; resolve the rule back instead.
                $back = (& $cyg -w $expected[$i]).Trim()
                if ($back -ne $files[$i]) { throw "msys rule '$($expected[$i])' resolves to '$back' by cygpath, expected '$($files[$i])'" }
            }
        }
        Invoke-DropCase $g 'gitbash' "printf '%s\n' " ' > "$TEMP/gt-drop.txt"' $files $expected

        # Two splits: the text lands in the split under the pointer, which gets focused.
        Invoke-SplitAction $g 'new_split:right'
        $st = Wait-SurfaceCount $g 2
        $boxes = @(Get-SurfaceBoxes $st | Sort-Object L)
        Invoke-SplitAction $g 'goto_split:left'
        Start-Sleep -Milliseconds 400
        foreach ($b in $boxes) {
            # Prefix in both splits, so either could finish the line.
            Send-MouseClick -Hwnd $g.Hwnd -X ([int](($b.L + $b.R) / 2)) -Y ([int](($b.T + $b.B) / 2))
            Send-Typed $g.Hwnd "printf '%s\n' "
        }
        Invoke-SplitAction $g 'goto_split:left'
        Start-Sleep -Milliseconds 300
        $right = $boxes[1]
        $drag = Start-OleFileDrag -Files $files -ToHwnd $g.Hwnd -X ([int](($right.L + $right.R) / 2)) -Y ([int](($right.T + $right.B) / 2))
        try { Start-Sleep -Milliseconds 200 } finally { Stop-OleFileDrag $drag }
        $ok = Wait-Until -TimeoutSec 4 -PollMs 100 -Condition {
            $f = @(Get-SurfaceBoxes (Get-SplitState $g) | Where-Object { $_.Focused })
            $f.Count -eq 1 -and $f[0].Id -eq $right.Id
        }
        if (-not $ok) { throw 'the split under the pointer did not get the focus after the drop' }
        $oracle = Join-Path $tmp 'gt-drop.txt'
        Remove-Item -LiteralPath $oracle -Force -ErrorAction SilentlyContinue
        Send-Typed $g.Hwnd ' > "$TEMP/gt-drop.txt"'
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
        if (-not (Wait-File $oracle 20)) { throw 'split: the oracle file was not written by the split that got the drop' }
        Start-Sleep -Milliseconds 500
        $lines = Read-OracleLines $oracle
        if ($lines.Count -ne $files.Count) { throw "split: expected $($files.Count) lines, got $($lines.Count)" }

        # The tab strip refuses: nothing is typed (an empty printf line is written).
        $top = ($boxes | Measure-Object -Property T -Minimum).Minimum
        if ($top -ge 8) {
            Remove-Item -LiteralPath $oracle -Force -ErrorAction SilentlyContinue
            $drag = Start-OleFileDrag -Files $files -ToHwnd $g.Hwnd -X ([int]($boxes[0].R)) -Y ([int]($top / 2))
            try {
                Start-Sleep -Milliseconds 300
            } finally { Stop-OleFileDrag $drag }
            Start-Sleep -Milliseconds 800
            Send-Typed $g.Hwnd ' > "$TEMP/gt-drop.txt"'
            Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
            if (-not (Wait-File $oracle 20)) { throw 'strip: the oracle file was not written' }
            Start-Sleep -Milliseconds 500
            $lines = Read-OracleLines $oracle
            if ($lines.Count -ne 0) { throw "strip: the refused drop typed text: $($lines -join ' | ')" }
        } else {
            Write-E2eInfo 'no tab strip above the surfaces; strip refusal not checked'
        }
        $ran++
        Stop-OwnGhostty
    } else {
        Write-E2eInfo 'Git Bash not found; msys case skipped'
    }

    # --- pwsh: the Windows paths in single quotes ---------------------------------
    if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
        $g = Start-E2eGhostty -ConfigText "command = direct:pwsh.exe -NoLogo`nconfirm-close-surface = false`n"
        if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
        if (-not (Wait-ChildNamed $g @('pwsh.exe') 20)) { throw 'pwsh did not start' }
        Start-Sleep -Milliseconds 3000
        $expected = @($files | ForEach-Object { , @($_, $_.Replace('\\?\', '')) })
        Invoke-DropCase $g 'pwsh' 'Write-Output ' ' | Set-Content -Encoding utf8 -LiteralPath "$env:TEMP\gt-drop.txt"' $files $expected
        $ran++
        Stop-OwnGhostty
    } else {
        Write-E2eInfo 'pwsh not found; pwsh case skipped'
    }

    # --- cmd: the Windows paths, double quotes where needed -------------------------
    $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'cmd')
    if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
    if (-not (Wait-ChildNamed $g @('cmd.exe') 20)) { throw 'cmd did not start' }
    Start-Sleep -Milliseconds 1500
    $expected = @($files | ForEach-Object { , @($_, $_.Replace('\\?\', '')) })
    Invoke-DropCase $g 'cmd' '(for %f in (' ') do @echo %~f) > "%TEMP%\gt-drop.txt"' $files $expected
    $ran++

    if ($ran -eq 0) { throw 'E2E-SKIP: no shell available' }
}
