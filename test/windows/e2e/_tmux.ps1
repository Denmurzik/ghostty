# Shared helpers of the M4 tmux scenarios. Dot-source it after _common.ps1.
# Keep this file ASCII only (Windows PowerShell 5.1 reads a BOM-less script
# as ANSI).
#
# tmux.exe is always called by its full path (never through PATH), with a
# clean environment (no inherited TMUX / TMUX_PANE / GHOSTTY_TMUX_TRACE) and
# with -S set to the pipe of the scenario's own Ghostty, so the owner's
# running Ghostty is never addressed.

$script:TmuxExe = Join-Path (Split-Path -Parent $script:Exe) 'tmux.exe'

# The pipe name of the Ghostty $G, from the test IPC state.
function Get-TmuxPipe($G) {
    $s = Get-GhosttyState -Class $G.Class
    $p = [string]$s.tmux.pipe
    if (-not $p) { throw "ghostty $($G.Class) has no tmux pipe in its state" }
    $p
}

# The panes of the Ghostty $G: pane (%N), surface, tab, window, env_tmux_pane.
function Get-TmuxPanes($G) {
    $s = Get-GhosttyState -Class $G.Class
    @($s.tmux.panes)
}

# Starts `tmux.exe -S <pipe of $G> <TmuxArgs>` without waiting. $Pane is the
# TMUX_PANE of the caller ("%N"); $Pipe overrides the pipe of $G (a Ghostty
# that is gone). $StdinText is sent to stdin (UTF-8, no BOM) when given.
function Start-TmuxProc($G, [string[]]$TmuxArgs, [string]$StdinText = $null, [string]$Pane = '', [string]$Pipe = '', [hashtable]$Env = @{}) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:TmuxExe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $script:Sbx.Tmp
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding $false
    $pipeName = if ($Pipe) { $Pipe } else { Get-TmuxPipe $G }
    $all = @('-S', $pipeName) + @($TmuxArgs)
    # .NET Framework (Windows PowerShell 5.1) has no ArgumentList.
    $psi.Arguments = (@($all | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' ')
    foreach ($n in 'TMUX', 'TMUX_PANE', 'GHOSTTY_TMUX_TRACE', 'GHOSTTY_TMUX_STATS') {
        [void]$psi.EnvironmentVariables.Remove($n)
    }
    if ($Pane) { $psi.EnvironmentVariables['TMUX_PANE'] = $Pane }
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$Env[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($null -ne $StdinText) {
        $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($StdinText)
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    }
    $p.StandardInput.Close()
    [pscustomobject]@{
        Process = $p
        Args    = $TmuxArgs
        Out     = $p.StandardOutput.ReadToEndAsync()
        Err     = $p.StandardError.ReadToEndAsync()
        Watch   = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

# Waits for a Start-TmuxProc; returns Code, Stdout, Stderr, Ms.
function Wait-TmuxProc($Run, [int]$TimeoutMs = 15000) {
    $p = $Run.Process
    if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch {}; throw "tmux.exe $($Run.Args -join ' ') did not exit within $TimeoutMs ms" }
    [pscustomobject]@{ Code = $p.ExitCode; Stdout = $Run.Out.Result; Stderr = $Run.Err.Result; Ms = $Run.Watch.ElapsedMilliseconds }
}

# Runs `tmux.exe -S <pipe of $G> <TmuxArgs>`; returns Code, Stdout, Stderr.
function Invoke-Tmux($G, [string[]]$TmuxArgs, [string]$StdinText = $null, [int]$TimeoutMs = 15000, [string]$Pane = '', [string]$Pipe = '', [hashtable]$Env = @{}) {
    Wait-TmuxProc (Start-TmuxProc $G $TmuxArgs $StdinText $Pane $Pipe $Env) $TimeoutMs
}

# C:\a\b -> /c/a/b, the form Git Bash prints for a Windows path.
function ConvertTo-MsysPath([string]$Path) {
    $p = $Path -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') { $p = '/' + $Matches[1].ToLowerInvariant() + $Matches[2] }
    $p
}
