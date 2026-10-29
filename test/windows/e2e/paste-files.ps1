# e2e: milestone=M7 timeout=150 order=1140
# paste-files: files copied in Explorer (a CF_HDROP and no text on the
# clipboard) paste as shell-quoted paths, the same text a drop gives
# (R-M7-7). Two sandbox files, one with a space in its name, are put on the
# clipboard with SetFileDropList; Ctrl+Shift+V pastes in Git Bash (`echo `
# + paste + Enter) and in cmd, and the shell output names both files. The
# owner's clipboard is saved first and restored in `finally`.
# Interactive desktop only. Keep this file ASCII only.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'paste-files' {
    $tmp = $script:Sbx.Tmp
    $dir = Join-Path $tmp 'paste-files'
    [void](New-Item -ItemType Directory -Force -Path $dir)
    $a = Join-Path $dir 'plain.txt'
    $b = Join-Path $dir 'with space.txt'
    foreach ($f in @($a, $b)) { Set-Content -LiteralPath $f -Value 'x' }

    function Set-ClipboardFiles([string[]]$Paths) {
        Invoke-ClipboardRetry {
            $list = New-Object System.Collections.Specialized.StringCollection
            [void]$list.AddRange($Paths)
            [System.Windows.Forms.Clipboard]::SetFileDropList($list)
        }
        Update-ClipboardMark
    }

    $saved = Save-ClipboardText
    $ran = 0
    try {
        # --- Git Bash: Windows paths, single quotes where needed -----------------
        if (Find-GitBash) {
            $g = Start-BashE2e 'unsafe-paste'
            if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
            $oracle = Join-Path $tmp 'gt-pastefiles.txt'
            Remove-Item -LiteralPath $oracle -Force -ErrorAction SilentlyContinue
            Set-ClipboardFiles @($a, $b)
            Send-Typed $g.Hwnd "printf '%s\n' "
            Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+shift+v'
            Start-Sleep -Milliseconds 800
            Send-Typed $g.Hwnd ' > "$TEMP/gt-pastefiles.txt"'
            Save-Evidence 'gitbash-pasted' $g -Window
            if (Test-Path -LiteralPath $oracle) { throw 'gitbash: the paste pressed Enter' }
            Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
            if (-not (Wait-File $oracle 20)) { Save-Evidence 'gitbash-fail' $g -Window; throw 'gitbash: the shell never wrote the oracle file' }
            Start-Sleep -Milliseconds 500
            $got = @((Get-Content -LiteralPath $oracle -Encoding UTF8) | Where-Object { $_ -ne '' })
            if ($got.Count -ne 2 -or $got[0] -ne $a -or $got[1] -ne $b) {
                throw "gitbash: expected '$a' and '$b', got: $($got -join ' | ')"
            }
            $ran++
            Stop-OwnGhostty
        } else {
            Write-E2eInfo 'Git Bash not found; msys case skipped'
        }

        # --- cmd: double quotes where needed -----------------------------------------
        $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'cmd')
        if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
        if (-not (Wait-ChildNamed $g @('cmd.exe') 20)) { throw 'cmd did not start' }
        Start-Sleep -Milliseconds 1500
        $oracle = Join-Path $tmp 'gt-pastefiles-cmd.txt'
        Remove-Item -LiteralPath $oracle -Force -ErrorAction SilentlyContinue
        Set-ClipboardFiles @($a, $b)
        Send-Typed $g.Hwnd '(for %f in ('
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+shift+v'
        Start-Sleep -Milliseconds 800
        Send-Typed $g.Hwnd ') do @echo %~f) > "%TEMP%\gt-pastefiles-cmd.txt"'
        Save-Evidence 'cmd-pasted' $g -Window
        if (Test-Path -LiteralPath $oracle) { throw 'cmd: the paste pressed Enter' }
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
        if (-not (Wait-File $oracle 20)) { Save-Evidence 'cmd-fail' $g -Window; throw 'cmd: the shell never wrote the oracle file' }
        Start-Sleep -Milliseconds 500
        $got = @((Get-Content -LiteralPath $oracle -Encoding UTF8) | Where-Object { $_ -ne '' })
        if ($got.Count -ne 2 -or $got[0] -ne $a -or $got[1] -ne $b) {
            throw "cmd: expected '$a' and '$b', got: $($got -join ' | ')"
        }
        $ran++
    } finally {
        Restore-ClipboardText $saved
    }
    if ($ran -eq 0) { throw 'E2E-SKIP: no shell available' }
}
