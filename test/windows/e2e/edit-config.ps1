# e2e: milestone=M5 timeout=90 order=966
# edit-config: `ghostty.exe +edit-config` with EDITOR=<sandbox>\fake-editor.cmd
# (a console program) exits 0 at once and starts a separate Ghostty of the
# configured class that runs the editor with the sandbox config path as its
# last argument. The fake editor writes its arguments to a marker file. The
# child exits by itself (wait-after-command = false, quit-after-last-window-
# closed); the harness kills it otherwise. Keep this file ASCII only (Windows
# PowerShell 5.1 reads a BOM-less script as ANSI).
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'edit-config' {
    $sbx = $script:Sbx
    $class = 'ghostty-e2e-edit-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $configDir = Join-Path $sbx.Home '.config\ghostty'
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    $configPath = Join-Path $configDir 'config.ghostty'
    $extra = "quit-after-last-window-closed = true`nwait-after-command = false`nconfirm-close-surface = false`n"
    [IO.File]::WriteAllText($configPath, (New-GhosttyConfigText -Class $class -Extra $extra), (New-Object Text.UTF8Encoding $false))

    $marker = Join-Path $sbx.Tmp 'editor-args.txt'
    $editor = Join-Path $sbx.Tmp 'fake-editor.cmd'
    [IO.File]::WriteAllText($editor, "@echo off`r`necho %*> `"$marker`"`r`n", (New-Object Text.ASCIIEncoding))

    $psi = [System.Diagnostics.ProcessStartInfo]::new((Resolve-Path -LiteralPath $script:Exe).Path)
    $psi.Arguments = '+edit-config'
    $psi.WorkingDirectory = $script:Root
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['USERPROFILE'] = $sbx.Home
    $psi.EnvironmentVariables['HOME'] = $sbx.Home
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $sbx.Local
    $psi.EnvironmentVariables['APPDATA'] = $sbx.Roaming
    $psi.EnvironmentVariables['TEMP'] = $sbx.Tmp
    $psi.EnvironmentVariables['TMP'] = $sbx.Tmp
    $psi.EnvironmentVariables['XDG_CONFIG_HOME'] = Join-Path $sbx.Home '.config'
    $psi.EnvironmentVariables['GHOSTTY_WIN32_TEST_IPC'] = '1'
    $psi.EnvironmentVariables['EDITOR'] = $editor
    [void]$psi.EnvironmentVariables.Remove('VISUAL')

    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(20000)) {
        try { $p.Kill() } catch {}
        throw '+edit-config did not exit within 20 s'
    }
    if ($p.ExitCode -ne 0) { throw "+edit-config exited $($p.ExitCode): $($err.Result)" }

    # The separate Ghostty: --class=<class> -e <editor> <config path>.
    $child = Wait-Until -TimeoutSec 15 -PollMs 200 -Condition {
        Get-CimInstance Win32_Process -Filter "Name='ghostty.exe'" |
            Where-Object { $_.CommandLine -like "*--class=$class*" -and $_.CommandLine -like '* -e *' } |
            Select-Object -First 1
    }
    if (-not $child) { throw "no child ghostty with --class=$class after +edit-config (stdout: $($out.Result))" }
    Register-OwnGhostty -ProcessId ([int]$child.ProcessId)
    if ($child.CommandLine -notlike "*$configPath*") { throw "the child command line lacks the config path: $($child.CommandLine)" }

    if (-not (Wait-File $marker 20)) { throw "the fake editor never wrote $marker" }
    $args_ = (Get-Content -LiteralPath $marker -Raw).Trim()
    if ($args_ -notlike "*$configPath*") { throw "the editor got '$args_', expected the config path $configPath" }

    # The child ends with its only window; the harness kills it otherwise.
    $gone = Wait-Until -TimeoutSec 20 -PollMs 300 -Condition { -not (Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue) }
    if (-not $gone) { Write-E2eInfo 'the child ghostty is still running after the editor ended; the harness stops it' }
}
