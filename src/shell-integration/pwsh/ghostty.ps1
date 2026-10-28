# Ghostty shell integration for PowerShell (Windows).
#
# Injected by Ghostty with `-NoExit -Command ". '<this file>'"`, so it runs
# after the user's profile. It marks the prompt with OSC 133 (A and B around
# the prompt, C when a command starts, D with its exit code when it ends).
# With the `title` feature it also emits OSC 2 titles (the working directory
# at the prompt and the command line while it runs) and OSC 7 with the
# working directory.

if ($Host.Name -ne 'ConsoleHost') { return }
if ($global:__ghostty_integrated) { return }
$global:__ghostty_integrated = $true

$script:__ghostty_title = $env:GHOSTTY_SHELL_FEATURES -like '*title*'
$script:__ghostty_esc = [char]27
$script:__ghostty_bel = [char]7
# Set when a command was accepted and its end (D) is still to be reported.
$script:__ghostty_pending = $false
# $LASTEXITCODE as it was before the command: the wrapper clears it, so that a
# value set afterwards tells that a native command ran.
$script:__ghostty_saved_exit = $null

function global:__ghostty_title([string]$text) {
    $text = $text -replace '[\x00-\x1f\x7f]', ' '
    [Console]::Out.Write("$([char]27)]2;$text$([char]7)")
}

# The working directory as OSC 7, `file:///C:/Users/x` with every
# segment percent-encoded. Anything but a drive path (UNC, other providers)
# reports no directory, which clears the previous one.
function global:__ghostty_pwd([string]$path) {
    $url = ''
    if ($path -match '^[A-Za-z]:([\\/]|$)') {
        $segments = $path.Replace('\', '/').Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }
        $segments[0] = $path.Substring(0, 2)
        $url = 'file:///' + ($segments -join '/')
    }
    [Console]::Out.Write("$([char]27)]7;$url$([char]7)")
}

# The prompt: D for the command that just ended, then A + the prompt text + B
# (the host prints what `prompt` returns), titled with the working directory
# (home shown as ~) when the title feature is on.
$script:__ghostty_prompt = $function:prompt
function global:prompt {
    $ok = $?
    $exit = $global:LASTEXITCODE
    if ($script:__ghostty_pending) {
        $script:__ghostty_pending = $false
        $code = if ($ok) { 0 }
                elseif ($null -ne $exit -and $exit -ne 0) { $exit }
                else { 1 }
        # No native command ran: the value from before stays visible.
        if ($null -eq $exit) { $global:LASTEXITCODE = $script:__ghostty_saved_exit }
        [Console]::Out.Write("$script:__ghostty_esc]133;D;$code$script:__ghostty_bel")
    }
    $result = if ($script:__ghostty_prompt) {
        & $script:__ghostty_prompt
    } else {
        "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
    }
    if ($script:__ghostty_title) {
        $location = $executionContext.SessionState.Path.CurrentLocation
        $path = if ($location.Provider.Name -eq 'FileSystem') { $location.ProviderPath } else { $location.Path }
        __ghostty_pwd $(if ($location.Provider.Name -eq 'FileSystem') { $location.ProviderPath } else { '' })
        $home_dir = $HOME
        if ($home_dir -and ($path -eq $home_dir -or $path.StartsWith($home_dir + '\', [StringComparison]::OrdinalIgnoreCase))) {
            $path = '~' + $path.Substring($home_dir.Length)
        }
        __ghostty_title $path
    }
    "$script:__ghostty_esc]133;A$script:__ghostty_bel$result$script:__ghostty_esc]133;B$script:__ghostty_bel"
}

# C goes out after the line is accepted, so the wrapper writes it once
# ReadLine returns (the Windows Terminal pattern). Without PSReadLine there is
# no C and no D, only A and B. PSReadLine's own function is replaced by a call
# of the overload this version has (3 arguments from PSReadLine 2.2, 2 before:
# Windows PowerShell 5.1); a function of somebody else's is chained.
if (Get-Module PSReadLine) {
    $existing = Get-Command PSConsoleHostReadLine -CommandType Function -ErrorAction SilentlyContinue
    $script:__ghostty_inner = if ($existing -and $existing.Source -ne 'PSReadLine') { $existing.ScriptBlock } else { $null }
    $script:__ghostty_rl3 = $null -ne [Microsoft.PowerShell.PSConsoleReadLine].GetMethod('ReadLine',
        [Type[]]@([System.Management.Automation.Runspaces.Runspace], [System.Management.Automation.EngineIntrinsics], [Nullable[bool]]))
    function global:PSConsoleHostReadLine {
        # As PSReadLine's own: the status of the last command comes first.
        $lastRunStatus = $?
        Set-StrictMode -Off
        $line = if ($script:__ghostty_inner) {
            & $script:__ghostty_inner
        } elseif ($script:__ghostty_rl3) {
            [Microsoft.PowerShell.PSConsoleReadLine]::ReadLine($Host.Runspace, $ExecutionContext, $lastRunStatus)
        } else {
            [Microsoft.PowerShell.PSConsoleReadLine]::ReadLine($Host.Runspace, $ExecutionContext)
        }
        if ($line -and $line.Trim()) {
            $script:__ghostty_pending = $true
            $script:__ghostty_saved_exit = $global:LASTEXITCODE
            $global:LASTEXITCODE = $null
            [Console]::Out.Write("$([char]27)]133;C$([char]7)")
        }
        $line
    }
}

# The command line, titled when Enter accepts it. The key keeps the
# function it was bound to; a custom script block binding is left alone.
if ($script:__ghostty_title) {
    try {
        $enter = Get-PSReadLineKeyHandler -Bound | Where-Object { $_.Key -eq 'Enter' } | Select-Object -First 1
        $accept = if ($enter) { $enter.Function } else { 'AcceptLine' }
        if ($accept -in 'AcceptLine', 'ValidateAndAcceptLine') {
            Set-PSReadLineKeyHandler -Key Enter -BriefDescription 'GhosttyAcceptLine' -ScriptBlock {
                $line = $null
                $cursor = $null
                [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
                if ($line -and $line.Trim()) { __ghostty_title $line.Trim() }
                if ($accept -eq 'ValidateAndAcceptLine') {
                    [Microsoft.PowerShell.PSConsoleReadLine]::ValidateAndAcceptLine()
                } else {
                    [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
                }
            }.GetNewClosure()
        }
    } catch {
        # No PSReadLine: only the working directory is titled.
    }
}
