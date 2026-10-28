# e2e: milestone=M5 timeout=120 order=966
# edit-config: `ghostty.exe +edit-config` exits 0 at once.
# 1. EDITOR="<sandbox>\fake-editor.cmd" (a launcher script, treated as GUI):
#    it runs detached with the sandbox config path as its last argument and no
#    extra Ghostty window is started.
# 2. EDITOR="cmd.exe" /c "<sandbox>\fake-editor2.cmd" (a console program): a
#    separate Ghostty of the configured class runs it (-e), the config path
#    last. The child exits by itself (wait-after-command = false,
#    quit-after-last-window-closed); the harness kills it otherwise.
# Keep this file ASCII only (Windows PowerShell 5.1 reads a BOM-less script as ANSI).
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'edit-config' {
    $sbx = $script:Sbx
    $class = 'ghostty-e2e-edit-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $configDir = Join-Path $sbx.Home '.config\ghostty'
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    $configPath = Join-Path $configDir 'config.ghostty'
    $extra = "quit-after-last-window-closed = true`nwait-after-command = false`nconfirm-close-surface = false`n"
    [IO.File]::WriteAllText($configPath, (New-GhosttyConfigText -Class $class -Extra $extra), (New-Object Text.UTF8Encoding $false))

    function Write-FakeEditor([string]$Name, [string]$Marker) {
        $file = Join-Path $sbx.Tmp $Name
        [IO.File]::WriteAllText($file, "@echo off`r`necho %*> `"$Marker`"`r`n", (New-Object Text.ASCIIEncoding))
        $file
    }

    function Invoke-EditConfig([string]$EditorSpec) {
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
        $psi.EnvironmentVariables['EDITOR'] = $EditorSpec
        [void]$psi.EnvironmentVariables.Remove('VISUAL')

        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(20000)) {
            try { $p.Kill() } catch {}
            throw '+edit-config did not exit within 20 s'
        }
        if ($p.ExitCode -ne 0) { throw "+edit-config exited $($p.ExitCode): $($err.Result)" }
    }

    function Find-EditChild {
        Get-CimInstance Win32_Process -Filter "Name='ghostty.exe'" |
            Where-Object { $_.CommandLine -like "*--class=$class*" -and $_.CommandLine -like '* -e *' } |
            Select-Object -First 1
    }

    # 1. A launcher script: run directly, no Ghostty window.
    $marker1 = Join-Path $sbx.Tmp 'editor-args-1.txt'
    $editor1 = Write-FakeEditor 'fake-editor.cmd' $marker1
    Invoke-EditConfig ('"' + $editor1 + '"')
    if (-not (Wait-File $marker1 20)) { throw "the launcher never wrote $marker1" }
    $args1 = (Get-Content -LiteralPath $marker1 -Raw).Trim()
    if ($args1 -notlike "*$configPath*") { throw "the launcher got '$args1', expected the config path $configPath" }
    Start-Sleep -Milliseconds 1500
    if (Find-EditChild) { throw 'a .cmd editor started a Ghostty window' }

    # 2. A console program: a separate Ghostty runs it.
    $marker2 = Join-Path $sbx.Tmp 'editor-args-2.txt'
    $editor2 = Write-FakeEditor 'fake-editor2.cmd' $marker2
    Invoke-EditConfig ('"' + (Join-Path $env:SystemRoot 'System32\cmd.exe') + '" /c "' + $editor2 + '"')
    $child = Wait-Until -TimeoutSec 15 -PollMs 200 -Condition { Find-EditChild }
    if (-not $child) { throw "no child ghostty with --class=$class after +edit-config" }
    Register-OwnGhostty -ProcessId ([int]$child.ProcessId)
    if ($child.CommandLine -notlike "*$configPath*") { throw "the child command line lacks the config path: $($child.CommandLine)" }
    if (-not (Wait-File $marker2 20)) { throw "the console editor never wrote $marker2" }
    $args2 = (Get-Content -LiteralPath $marker2 -Raw).Trim()
    if ($args2 -notlike "*$configPath*") { throw "the editor got '$args2', expected the config path $configPath" }

    $gone = Wait-Until -TimeoutSec 20 -PollMs 300 -Condition { -not (Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue) }
    if (-not $gone) { Write-E2eInfo 'the child ghostty is still running after the editor ended; the harness stops it' }
}
