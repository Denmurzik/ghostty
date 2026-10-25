# typing-us: every printable ASCII key reaches the shell on the US layout.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'typing-us' {
    $g = Start-BashE2e
    $payload = 'AbZ09 !@#$%^&*()_+-=[]{}\|;:,.<>/?~"'
    $path = Invoke-PayloadCase $g 'gt-us.txt' { Send-RealKeys $g.Hwnd $payload }
    Assert-ShellText $path $payload 'US layout'
}
