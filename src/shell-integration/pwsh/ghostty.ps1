# Ghostty shell integration for PowerShell (Windows).
#
# Injected by Ghostty with `-NoExit -Command ". '<this file>'"`, so it runs
# after the user's profile. It emits OSC 2 titles (the working directory at
# the prompt and the command line while it runs) and OSC 7 with the working
# directory.

if ($Host.Name -ne 'ConsoleHost') { return }
if ($env:GHOSTTY_SHELL_FEATURES -notlike '*title*') { return }
if ($global:__ghostty_integrated) { return }
$global:__ghostty_integrated = $true

function global:__ghostty_title([string]$text) {
    $text = $text -replace '[\x00-\x1f\x7f]', ' '
    [Console]::Out.Write("$([char]27)]2;$text$([char]7)")
}

# The working directory as OSC 7, `file://HOST/C:/Users/x` with every
# segment percent-encoded. Anything but a drive path (UNC, other providers)
# reports no directory, which clears the previous one.
function global:__ghostty_pwd([string]$path) {
    $url = ''
    if ($path -match '^[A-Za-z]:([\\/]|$)') {
        $segments = $path.Replace('\', '/').Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }
        $segments[0] = $path.Substring(0, 2)
        $url = "file://$($env:COMPUTERNAME)/" + ($segments -join '/')
    }
    [Console]::Out.Write("$([char]27)]7;$url$([char]7)")
}

# The prompt, titled with the working directory (home shown as ~).
$script:__ghostty_prompt = $function:prompt
function global:prompt {
    $result = if ($script:__ghostty_prompt) {
        & $script:__ghostty_prompt
    } else {
        "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
    }
    $location = $executionContext.SessionState.Path.CurrentLocation
    $path = if ($location.Provider.Name -eq 'FileSystem') { $location.ProviderPath } else { $location.Path }
    __ghostty_pwd $(if ($location.Provider.Name -eq 'FileSystem') { $location.ProviderPath } else { '' })
    $home_dir = $HOME
    if ($home_dir -and ($path -eq $home_dir -or $path.StartsWith($home_dir + '\', [StringComparison]::OrdinalIgnoreCase))) {
        $path = '~' + $path.Substring($home_dir.Length)
    }
    __ghostty_title $path
    $result
}

# The command line, titled when Enter accepts it. The key keeps the
# function it was bound to; a custom script block binding is left alone.
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
