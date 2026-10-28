# e2e: milestone=M5 timeout=180 order=966
# term-terminfo: TERM defaults to xterm-ghostty on Windows and the compiled
# terminfo under share/terminfo is found by Git Bash programs (tput, infocmp,
# vim) through TERMINFO (the /c/... form: ncurses splits C:/ at the colon); pwsh sees TERM too.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'term-terminfo' {
    $entry = Join-Path (Split-Path -Parent (Split-Path -Parent $script:Exe)) 'share\terminfo\78\xterm-ghostty'
    if (-not (Test-Path -LiteralPath $entry)) { throw "E2E-SKIP: $entry is not installed (no tic at build time)" }

    # --- Git Bash ---
    $g = Start-BashE2e
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
    $out = Join-Path $script:Sbx.Tmp 'term.txt'
    Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
    $cmd = '{ echo "TERM=$TERM"; echo "TERMINFO=$TERMINFO"; ' +
        'echo "COLORS=$(tput colors 2>&1)"; ' +
        'echo "SMULX=$(tput Smulx 2>&1 | od -An -c | head -c 40)"; ' +
        'echo "INFOCMP=$(infocmp xterm-ghostty 2>&1 | head -n 1)"; ' +
        'vim -u NONE -c q >/dev/null 2>"$TEMP/vimerr.txt"; echo "VIM=$?"; ' +
        'echo "VIMERR=$(grep -c E558 "$TEMP/vimerr.txt")"; ' +
        'less -V >/dev/null 2>&1; echo "LESS=$?"; echo END; } > "$TEMP/term.txt" 2>&1'
    Send-Line $g.Hwnd $cmd
    $ok = Wait-Until -TimeoutSec 30 -PollMs 200 -Condition {
        (Test-Path -LiteralPath $out) -and ((Get-Content -LiteralPath $out -Raw) -match 'END')
    }
    if (-not $ok) { throw 'the shell never finished the probe' }
    $text = (Read-ShellFile $out).Utf8
    Write-E2eInfo ("bash probe:`n" + $text)
    $v = @{}
    foreach ($l in ($text -split "`r?`n")) { if ($l -match '^([A-Z]+)=(.*)$') { $v[$Matches[1]] = $Matches[2] } }
    if ($v.TERM -ne 'xterm-ghostty') { throw "TERM is '$($v.TERM)' in Git Bash" }
    if ($v.TERMINFO -notmatch '^/[a-z]/') { throw "TERMINFO is '$($v.TERMINFO)', expected the POSIX drive form (/c/...): ncurses splits C:/ at the colon" }
    if ($v.COLORS -ne '256') { throw "tput colors gave '$($v.COLORS)'" }
    if ($v.INFOCMP -notmatch 'xterm-ghostty') { throw "infocmp did not find the entry: '$($v.INFOCMP)'" }
    if ($v.SMULX -match '^\s*$|not|unknown|No ' ) { Write-E2eInfo "Smulx empty or missing: '$($v.SMULX)'" }
    if ($v.VIM -ne '0' -or $v.VIMERR -ne '0') { throw "vim exit=$($v.VIM) E558 count=$($v.VIMERR)" }
    if ($v.LESS -ne '0') { throw "less -V exit=$($v.LESS)" }
    Save-Evidence -Tag 'term-terminfo-bash' -G $g -Window
    Stop-OwnGhostty

    # --- pwsh ---
    if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
        $g = Start-E2eGhostty -ConfigText "command = direct:pwsh.exe -NoLogo`nconfirm-close-surface = false`n"
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        if (-not (Wait-ChildNamed $g @('pwsh.exe') 20)) { throw 'pwsh did not start' }
        Start-Sleep -Seconds 2
        $pout = Join-Path $script:Sbx.Tmp 'pwsh-term.txt'
        Send-Line $g.Hwnd "Set-Content -LiteralPath '$pout' -Value `$env:TERM -Encoding ascii"
        if (-not (Wait-File $pout 20)) { throw 'pwsh never wrote TERM' }
        $t = (Read-ShellFile $pout).Utf8.Trim()
        if ($t -ne 'xterm-ghostty') { throw "TERM is '$t' in pwsh" }
        Stop-OwnGhostty
    } else {
        Write-E2eInfo 'pwsh not found; pwsh case skipped'
    }
}
