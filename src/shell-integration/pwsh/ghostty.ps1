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
$script:__ghostty_last_exit = $null

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
                elseif ($null -ne $exit -and $exit -ne 0 -and $exit -ne $script:__ghostty_last_exit) { $exit }
                else { 1 }
        [Console]::Out.Write("$script:__ghostty_esc]133;D;$code$script:__ghostty_bel")
    }
    $script:__ghostty_last_exit = $exit
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
# no C and no D, only A and B.
if (Get-Module PSReadLine) {
    function global:PSConsoleHostReadLine {
        # As PSReadLine's own: the status of the last command comes first.
        $lastRunStatus = $?
        $line = [Microsoft.PowerShell.PSConsoleReadLine]::ReadLine($Host.Runspace, $ExecutionContext, $lastRunStatus)
        if ($line -and $line.Trim()) {
            $script:__ghostty_pending = $true
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
