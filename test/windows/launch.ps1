<#
.SYNOPSIS
Starts zig-out\bin\ghostty.exe with an isolated config and prints
"pid=<n> hwnd=<0x...>" once its main window exists.

.DESCRIPTION
The config is copied to a temporary XDG_CONFIG_HOME, so the user's own
config is never read. The process is registered with the harness so
Stop-OwnGhostty kills it; when run standalone it is left running and the
caller must stop it.

.PARAMETER Config
Config file to use as config.ghostty.

.PARAMETER Driver
Value for GHOSTTY_D3D11_DRIVER (for example "warp").

.PARAMETER DumpDir
Directory for GHOSTTY_D3D11_DUMP frame dumps.
#>
param(
    [Parameter(Mandatory)][string]$Config,
    [string]$Driver,
    [string]$DumpDir
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\Harness.psm1')

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exe = Join-Path $root 'zig-out\bin\ghostty.exe'
if (-not (Test-Path $exe)) { throw "missing $exe (run zig build first)" }

$xdg = Join-Path $env:TEMP "ghostty-e2e\xdg-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path (Join-Path $xdg 'ghostty') | Out-Null
Copy-Item -LiteralPath $Config -Destination (Join-Path $xdg 'ghostty\config.ghostty')

if ($DumpDir) { New-Item -ItemType Directory -Force -Path $DumpDir | Out-Null }

# Set for the child only: restored below so an in-process caller keeps its
# environment.
$names = 'XDG_CONFIG_HOME', 'GHOSTTY_D3D11_DRIVER', 'GHOSTTY_D3D11_DUMP'
$saved = @{}
foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }

try {
    $env:XDG_CONFIG_HOME = $xdg
    [Environment]::SetEnvironmentVariable('GHOSTTY_D3D11_DRIVER', $Driver, 'Process')
    [Environment]::SetEnvironmentVariable('GHOSTTY_D3D11_DUMP', $DumpDir, 'Process')
    # An instance class of its own: never the owner's instance.
    $class = 'ghostty-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $proc = Start-Process -FilePath $exe -WorkingDirectory $root -ArgumentList "--class=$class" -PassThru
} finally {
    foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
}

Register-OwnGhostty -ProcessId $proc.Id

$deadline = [DateTime]::UtcNow.AddSeconds(10)
while ([DateTime]::UtcNow -lt $deadline) {
    $proc.Refresh()
    if ($proc.HasExited) { throw "ghostty exited early with code $($proc.ExitCode)" }
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
        'pid={0} hwnd=0x{1:X}' -f $proc.Id, $proc.MainWindowHandle.ToInt64()
        return
    }
    Start-Sleep -Milliseconds 100
}

Stop-OwnGhostty
throw 'ghostty did not create a main window within 10 s'
