# e2e: milestone=M5 timeout=240 order=966
# term-terminfo: TERM defaults to xterm-ghostty on Windows and the compiled
# terminfo under share/terminfo is found by Git's MSYS tools through TERMINFO
# (the /c/... form: ncurses splits C:/ at the colon). Checked from Git Bash,
# pwsh and cmd: tput colors, tput Smulx, tput cup, infocmp and vim. Also
# TERMINUS_SUBLIME=1 (Node CLIs such as Claude Code draw Unicode symbols), absent
# with another TERM, and a user value kept.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'term-terminfo' {
    # The same lookup as resourcesDir (src/os/resourcesdir.zig): climb from the
    # exe's folder to the first <dir>\share holding terminfo\ghostty.terminfo.
    # It finds both zig-out\bin\ghostty.exe + zig-out\share and the portable
    # layout (share next to ghostty.exe).
    $share = $null
    $dir = Split-Path -Parent $script:Exe
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir 'share\terminfo\ghostty.terminfo')) { $share = Join-Path $dir 'share\terminfo'; break }
        $up = Split-Path -Parent $dir
        if ($up -eq $dir) { break }
        $dir = $up
    }
    # Ghostty itself would find no resources: a real gap, never a skip.
    if (-not $share) { throw "no share\terminfo\ghostty.terminfo above $(Split-Path -Parent $script:Exe): ghostty finds no resources" }
    if (-not ((Test-Path -LiteralPath (Join-Path $share '78\xterm-ghostty')) -or (Test-Path -LiteralPath (Join-Path $share 'x\xterm-ghostty')))) {
        # A source build without tic may lack it; a package (share next to the exe) may not.
        if ((Split-Path -Parent $share) -ieq (Join-Path (Split-Path -Parent $script:Exe) 'share')) {
            throw "the package has no compiled xterm-ghostty entry under $share"
        }
        throw "E2E-SKIP: the compiled xterm-ghostty entry is not installed under $share (no tic at build time)"
    }
    Write-E2eInfo "terminfo: $share"
    $bashExe = Find-GitBash
    if (-not $bashExe) { throw 'E2E-SKIP: Git for Windows not found' }
    $gitBin = Join-Path (Split-Path -Parent (Split-Path -Parent $bashExe)) 'usr\bin'

    # --- Git Bash ---
    $g = Start-BashE2e
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
    $out = Join-Path $script:Sbx.Tmp 'term.txt'
    Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
    $cmd = '{ echo "TERM=$TERM"; echo "TERMINFO=$TERMINFO"; ' +
        'echo "COLORS=$(tput colors 2>&1)"; ' +
        'echo "SMULX=$(tput Smulx 2>&1 | od -An -c | head -c 40)"; ' +
        'echo "CUP=$(tput cup 1 1 2>&1 | od -An -c | head -c 40)"; ' +
        'echo "INFOCMP=$(infocmp xterm-ghostty 2>&1 | head -n 1)"; ' +
        'vim -u NONE -c q >/dev/null 2>"$TEMP/vimerr.txt"; echo "VIM=$?"; ' +
        'echo "VIMERR=$(grep -c E558 "$TEMP/vimerr.txt")"; echo "SUBLIME=$TERMINUS_SUBLIME"; echo END; } > "$TEMP/term.txt" 2>&1'
    Send-Line $g.Hwnd $cmd
    $ok = Wait-Until -TimeoutSec 30 -PollMs 200 -Condition {
        (Test-Path -LiteralPath $out) -and ((Get-Content -LiteralPath $out -Raw) -match 'END')
    }
    if (-not $ok) { throw 'the shell never finished the probe' }
    $text = (Read-ShellFile $out).Utf8
    Write-E2eInfo ("bash probe: " + ($text -replace "`r?`n", ' | '))
    $v = @{}
    foreach ($l in ($text -split "`r?`n")) { if ($l -match '^([A-Z]+)=(.*)$') { $v[$Matches[1]] = $Matches[2] } }
    if ($v.TERM -ne 'xterm-ghostty') { throw "TERM is '$($v.TERM)' in Git Bash" }
    if ($v.TERMINFO -notmatch '^/[a-z]/') { throw "TERMINFO is '$($v.TERMINFO)', expected the POSIX drive form (/c/...)" }
    if ($v.COLORS -ne '256') { throw "tput colors gave '$($v.COLORS)'" }
    if ($v.INFOCMP -notmatch 'xterm-ghostty') { throw "infocmp did not find the entry: '$($v.INFOCMP)'" }
    if ($v.SMULX -notmatch '4\s+:\s+%') { throw "tput Smulx gave '$($v.SMULX)'" }
    if ($v.CUP -notmatch '2\s+;\s+2\s+H') { throw "tput cup 1 1 gave '$($v.CUP)'" }
    if ($v.VIM -ne '0' -or $v.VIMERR -ne '0') { throw "vim exit=$($v.VIM) E558 count=$($v.VIMERR)" }
    if ($v.SUBLIME -ne '1') { throw "TERMINUS_SUBLIME is '$($v.SUBLIME)' in Git Bash, expected 1" }
    Save-Evidence -Tag 'term-terminfo-bash' -G $g -Window
    Stop-OwnGhostty

    # --- pwsh: TERM, then Git's tput and vim (MSYS tools read TERMINFO) ---
    if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
        $g = Start-E2eGhostty -ConfigText "command = direct:pwsh.exe -NoLogo`nconfirm-close-surface = false`n"
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        if (-not (Wait-ChildNamed $g @('pwsh.exe') 20)) { throw 'pwsh did not start' }
        Start-Sleep -Seconds 2
        $pout = Join-Path $script:Sbx.Tmp 'pwsh-term.txt'
        Remove-Item -LiteralPath $pout -ErrorAction SilentlyContinue
        Send-Line $g.Hwnd ("& '$gitBin\vim.exe' -u NONE -c q 2>`$null | Out-Null; `$e = `$LASTEXITCODE; `$o = @(`$env:TERM, (& '$gitBin\tput.exe' colors 2>&1), `$e, `$env:TERMINUS_SUBLIME); " +
            "Set-Content -LiteralPath '$pout' -Value `$o -Encoding ascii")
        if (-not (Wait-File $pout 20)) { throw 'pwsh never wrote its probe' }
        $p = @((Read-ShellFile $pout).Utf8 -split "`r?`n" | Where-Object { $_ })
        Write-E2eInfo ("pwsh probe: " + ($p -join ' | '))
        if ($p[0] -ne 'xterm-ghostty') { throw "TERM is '$($p[0])' in pwsh" }
        if ($p[1] -ne '256') { throw "Git tput colors from pwsh gave '$($p[1])'" }
        if ($p[2] -ne '0') { throw "Git vim from pwsh exited $($p[2])" }
        if ($p[3] -ne '1') { throw "TERMINUS_SUBLIME is '$($p[3])' in pwsh, expected 1" }
        Stop-OwnGhostty
    } else {
        Write-E2eInfo 'pwsh not found; pwsh case skipped'
    }

    # --- cmd ---
    $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'cmd')
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
    if (-not (Wait-ChildNamed $g @('cmd.exe') 20)) { throw 'cmd did not start' }
    Start-Sleep -Seconds 1
    $cout = Join-Path $script:Sbx.Tmp 'cmd-term.txt'
    Remove-Item -LiteralPath $cout -ErrorAction SilentlyContinue
    # A batch file: %ERRORLEVEL% expands per line there. The space before >> keeps
    # the digit from being read as a handle number.
    $bat = Join-Path $script:Sbx.Tmp 'probe.cmd'
    [IO.File]::WriteAllText($bat, (@(
        '@echo off',
        "echo %TERM%> `"$cout`"",
        "`"$gitBin\tput.exe`" colors >> `"$cout`" 2>&1",
        "`"$gitBin\vim.exe`" -u NONE -c q >nul 2>&1",
        "echo VIM=%ERRORLEVEL% >> `"$cout`"",
        "echo SUB=%TERMINUS_SUBLIME% >> `"$cout`""
    ) -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
    Send-Line $g.Hwnd "call `"$bat`""
    $okc = Wait-Until -TimeoutSec 20 -PollMs 200 -Condition {
        try { (Get-Content -LiteralPath $cout -Raw -ErrorAction Stop) -match 'SUB=' } catch { $false }
    }
    if (-not $okc) { Save-Evidence -Tag 'term-terminfo-cmd' -G $g -Window; throw "cmd never finished its probe: [$(if (Test-Path -LiteralPath $cout) { Get-Content -LiteralPath $cout -Raw })]" }
    $c = @((Read-ShellFile $cout).Utf8 -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Write-E2eInfo ("cmd probe: " + ($c -join ' | '))
    if ($c[0] -ne 'xterm-ghostty') { throw "TERM is '$($c[0])' in cmd" }
    if ($c[1] -ne '256') { throw "Git tput colors from cmd gave '$($c[1])'" }
    if ($c[2] -ne 'VIM=0') { throw "Git vim from cmd: '$($c[2])'" }
    if ($c[3] -ne 'SUB=1') { throw "TERMINUS_SUBLIME in cmd: '$($c[3])', expected SUB=1" }
    Stop-OwnGhostty

    # --- TERMINUS_SUBLIME: absent with another TERM, a user value is kept ---
    # A batch file prints it (an unset variable expands to nothing).
    $subBat = Join-Path $script:Sbx.Tmp 'sub.cmd'
    foreach ($case in @(
            @{ Tag = 'xterm-256color'; Env = "env = TERM=xterm-256color`n"; Want = 'SUB=' },
            @{ Tag = 'user-value'; Env = "env = TERMINUS_SUBLIME=yes`n"; Want = 'SUB=yes' })) {
        $sout = Join-Path $script:Sbx.Tmp "sub-$($case.Tag).txt"
        Remove-Item -LiteralPath $sout -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText($subBat, (@('@echo off', "echo SUB=%TERMINUS_SUBLIME%> `"$sout`"") -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
        $cfg = (Get-Content -LiteralPath (Get-ConfigPath 'cmd') -Raw -Encoding UTF8).TrimEnd() + "`n" + $case.Env
        $g = Start-E2eGhostty -ConfigText $cfg -Env @{ TERMINUS_SUBLIME = $null }
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        if (-not (Wait-ChildNamed $g @('cmd.exe') 20)) { throw "cmd did not start ($($case.Tag))" }
        Start-Sleep -Seconds 1
        Send-Line $g.Hwnd "call `"$subBat`""
        if (-not (Wait-File $sout 20)) { throw "cmd never wrote its probe ($($case.Tag))" }
        $got = ((Read-ShellFile $sout).Utf8 -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 1)
        Write-E2eInfo "TERMINUS_SUBLIME $($case.Tag): '$got'"
        if ($got -ne $case.Want) { throw "TERMINUS_SUBLIME with $($case.Tag): '$got', expected '$($case.Want)'" }
        Stop-OwnGhostty
    }
}
