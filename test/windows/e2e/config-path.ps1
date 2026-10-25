# config-path: with no config and a fresh USERPROFILE the template is created
# at <USERPROFILE>\.config\ghostty\config.ghostty (and nowhere else).
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'config-path' {
    $home_ = $script:Sbx.Home
    $want = Join-Path $home_ '.config\ghostty\config.ghostty'
    if (Test-Path -LiteralPath $want) { throw 'sandbox already has a config' }

    $g = Start-E2eGhostty -NoConfig -NoXdg
    if (-not (Wait-File $want 15)) {
        $found = @(Get-ChildItem -LiteralPath $script:Sbx.Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'config*' } | ForEach-Object { $_.FullName })
        throw "no template at $want; config-like files in the sandbox: $($found -join '; ')"
    }

    $text = Get-Content -LiteralPath $want -Raw -Encoding UTF8
    if (-not $text.StartsWith('#')) { throw 'template does not start with a comment' }
    if (-not $text.Contains($want)) { throw "template does not name its own path $want" }

    $legacy = Join-Path $home_ '.config\ghostty\config'
    if (Test-Path -LiteralPath $legacy) { throw "legacy config file created: $legacy" }
    foreach ($other in (Join-Path $script:Sbx.Roaming 'ghostty'), (Join-Path $home_ '.ghostty')) {
        if (Test-Path -LiteralPath $other) { throw "config-ish location created: $other" }
    }
    if (-not (Test-Path -LiteralPath $g.Log)) { throw "no log at $($g.Log) (expected under LOCALAPPDATA)" }
    Start-Sleep -Milliseconds 1000
    if ($g.Process.HasExited) { throw "ghostty exited (code $($g.Process.ExitCode)) after creating the template" }
    Write-E2eInfo "template created, $($text.Length) chars, log at $($g.Log)"
}
