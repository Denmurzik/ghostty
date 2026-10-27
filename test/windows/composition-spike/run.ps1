<#
.SYNOPSIS
Runs the composition spike (risk R10, M3 Task 8) and collects the raw evidence
for RESULT.md: DirectComposition child targets, transparent client area,
Acrylic, re-parenting, swap-chain mode switches, tearing, DComp device
lifetime, pacing and memory.

.DESCRIPTION
Build first:  zig build -j6 --build-file test/windows/composition-spike/build.zig

Every window launch and screen capture happens inside a Harness scenario
(Invoke-GuiScenario), i.e. under the shared desktop lock %TEMP%\gui-e2e.lock;
a locked or non-interactive session is a SKIP. Only processes started here are
killed. The spike captures its own windows in-process (a full-monitor striped
backdrop window sits behind them, so nothing else is on screen in the shots);
this script only converts the BMPs to PNG.

Runs (-Only takes names, comma separated):
  pacing                    (g) waitable-object pacing, hwnd vs composition chain
  memory                    (h) private bytes per DComp device / target+visual / swap chain
  t-<frame>-<backdrop>[-nr][-cb]
                            (a)(b)(c)(d)(f)(g)(i) transparent client; <frame> is the
                            transparency recipe: ext = DwmExtendFrameIntoClientArea(-1),
                            blur = DwmEnableBlurBehindWindow empty region, both;
                            <backdrop> is none (DWMSBT_NONE) or acrylic
                            (DWMSBT_TRANSIENTWINDOW); -nr = child with
                            WS_EX_NOREDIRECTIONBITMAP; -cb = child erases itself with the
                            black class brush. Blur and acrylic runs without -quick also
                            resize, maximize, scale by 1.5 and minimize/restore.
  reparent                  (e) SetParent of the composited child
  cycle                     (j) hwnd chain <-> composition chain on the same child
  tearing                   (k) ALLOW_TEARING on a composition chain
  devrecreate               (l) DComp device outlives the D3D device

Each run appends its CHECK-PASS/CHECK-FAIL/INFO lines to <ShotsDir>\results.txt.
A CHECK-FAIL is a finding, not a script failure: the scenario fails only when
the spike does not start, crashes or hangs.
#>
param(
    [string]$Exe = (Join-Path $PSScriptRoot 'zig-out\bin\composition-spike.exe'),
    [string]$ShotsDir = (Join-Path $env:TEMP 'composition-spike-shots'),
    # Frame variant for the runs that do not sweep it (reparent, cycle, ...).
    [string]$Backdrop = 'blur',
    [string[]]$Only = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# `-File run.ps1 -Only a,b` arrives as one string.
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

Import-Module (Join-Path $PSScriptRoot '..\lib\Harness.psm1') -Force

if (-not (Test-Path -LiteralPath $Exe)) { throw "spike exe not found: $Exe (build it first)" }
New-Item -ItemType Directory -Force -Path $ShotsDir | Out-Null
$Results = Join-Path $ShotsDir 'results.txt'

$freeKb = [int64](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory
if ($freeKb -lt 2.5GB / 1KB) {
    "SKIP composition-spike: free RAM $([math]::Round($freeKb / 1MB, 2)) GB < 2.5 GB"
    return
}

Add-Type -AssemblyName System.Drawing

function Out-Result([string]$Line) {
    Write-Host $Line
    Add-Content -LiteralPath $Results -Value $Line -Encoding UTF8
}

function Read-SpikeLog([string]$Path) {
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { '' }
}

function Wait-LogMatch([string]$Path, [string]$Pattern, [int]$TimeoutMs = 20000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $m = [regex]::Match((Read-SpikeLog $Path), $Pattern)
        if ($m.Success) { return $m }
        Start-Sleep -Milliseconds 50
    }
    throw "timeout waiting for /$Pattern/ in $Path"
}

function Convert-Shots([string]$Dir, [string]$Prefix) {
    Get-ChildItem -LiteralPath $Dir -Filter '*.bmp' | ForEach-Object {
        $png = [IO.Path]::ChangeExtension($_.FullName, '.png')
        $bmp = New-Object Drawing.Bitmap($_.FullName)
        try { $bmp.Save($png, [Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
        Remove-Item -LiteralPath $_.FullName -Force
        Out-Result "INFO [$Prefix] shot: $png"
    }
}

function Invoke-Spike([string]$Name, [string[]]$SpikeArgs, [int]$TimeoutSec = 120) {
    $log = Join-Path $ShotsDir "$Name.log"
    $go = Join-Path $ShotsDir "$Name.go"
    Remove-Item -LiteralPath $log, $go -Force -ErrorAction SilentlyContinue
    $all = @($SpikeArgs) + @("--out=$ShotsDir", "--log=$log", "--go=$go")
    $proc = Start-Process -FilePath $Exe -ArgumentList $all -PassThru
    try {
        $m = Wait-LogMatch $log 'frame hwnd=0x([0-9a-f]+)'
        $hwnd = [IntPtr][Convert]::ToInt64($m.Groups[1].Value, 16)
        $fg = Set-ForegroundSafe -Hwnd $hwnd
        Out-Result "INFO [$Name] window is foreground: $fg"
        Start-Sleep -Milliseconds 300
        New-Item -ItemType File -Path $go -Force | Out-Null
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            throw "spike did not finish in $TimeoutSec s"
        }
    } finally {
        $proc.Refresh()
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $go -Force -ErrorAction SilentlyContinue
    }
    $text = Read-SpikeLog $log
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '(CHECK-PASS|CHECK-FAIL|INFO) \(' -or $line -match 'frame hwnd=|backdrop hwnd=|fatal|failed') {
            Out-Result "[$Name] $line"
        }
    }
    Convert-Shots $ShotsDir $Name
    if ($text -match 'fatal what=') { throw "spike reported a fatal error (see $log)" }
    if ($text -notmatch '\] done') { throw "spike did not log 'done' (exit code $($proc.ExitCode); see $log)" }
}

$plan = @(
    @{ Name = 'pacing'; Args = @('--mode=pacing', '--backdrop=ext', '--sbt=none') }
    @{ Name = 'memory'; Args = @('--mode=memory', '--backdrop=ext', '--sbt=none') }
    # Child leaves the parent surface under it alone (no erase), GDI redirection surface.
    @{ Name = 't-ext-none'; Args = @('--mode=transparent', '--backdrop=ext', '--sbt=none') }
    @{ Name = 't-blur-none'; Args = @('--mode=transparent', '--backdrop=blur', '--sbt=none', '--quick') }
    @{ Name = 't-both-none'; Args = @('--mode=transparent', '--backdrop=both', '--sbt=none', '--quick') }
    @{ Name = 't-ext-acrylic'; Args = @('--mode=transparent', '--backdrop=ext', '--sbt=acrylic') }
    @{ Name = 't-blur-acrylic'; Args = @('--mode=transparent', '--backdrop=blur', '--sbt=acrylic', '--quick') }
    @{ Name = 't-both-acrylic'; Args = @('--mode=transparent', '--backdrop=both', '--sbt=acrylic', '--quick') }
    # Same with WS_EX_NOREDIRECTIONBITMAP on the child.
    @{ Name = 't-ext-none-nr'; Args = @('--mode=transparent', '--backdrop=ext', '--sbt=none', '--noredir', '--quick') }
    @{ Name = 't-blur-none-nr'; Args = @('--mode=transparent', '--backdrop=blur', '--sbt=none', '--noredir') }
    @{ Name = 't-both-none-nr'; Args = @('--mode=transparent', '--backdrop=both', '--sbt=none', '--noredir', '--quick') }
    @{ Name = 't-ext-acrylic-nr'; Args = @('--mode=transparent', '--backdrop=ext', '--sbt=acrylic', '--noredir', '--quick') }
    @{ Name = 't-blur-acrylic-nr'; Args = @('--mode=transparent', '--backdrop=blur', '--sbt=acrylic', '--noredir') }
    @{ Name = 't-both-acrylic-nr'; Args = @('--mode=transparent', '--backdrop=both', '--sbt=acrylic', '--noredir', '--quick') }
    # The child erases itself with the black class brush (alpha 0 on glass).
    @{ Name = 't-blur-none-cb'; Args = @('--mode=transparent', '--backdrop=blur', '--sbt=none', '--childblack') }
    @{ Name = 't-blur-none-nr-cb'; Args = @('--mode=transparent', '--backdrop=blur', '--sbt=none', '--noredir', '--childblack', '--quick') }
    @{ Name = 't-ext-none-cb'; Args = @('--mode=transparent', '--backdrop=ext', '--sbt=none', '--childblack', '--quick') }
    @{ Name = 't-both-none-cb'; Args = @('--mode=transparent', '--backdrop=both', '--sbt=none', '--childblack', '--quick') }
    @{ Name = 't-blur-acrylic-cb'; Args = @('--mode=transparent', '--backdrop=blur', '--sbt=acrylic', '--childblack') }
    @{ Name = 't-ext-acrylic-cb'; Args = @('--mode=transparent', '--backdrop=ext', '--sbt=acrylic', '--childblack') }
    @{ Name = 't-both-acrylic-cb'; Args = @('--mode=transparent', '--backdrop=both', '--sbt=acrylic', '--childblack', '--quick') }
    @{ Name = 'reparent'; Args = @('--mode=reparent', "--backdrop=$Backdrop", '--sbt=none', '--childblack') }
    @{ Name = 'cycle'; Args = @('--mode=cycle', "--backdrop=$Backdrop", '--sbt=none', '--childblack') }
    @{ Name = 'tearing'; Args = @('--mode=tearing', "--backdrop=$Backdrop", '--sbt=none', '--childblack') }
    @{ Name = 'devrecreate'; Args = @('--mode=devrecreate', "--backdrop=$Backdrop", '--sbt=none', '--childblack') }
)

foreach ($step in $plan) {
    if ($Only.Count -gt 0 -and $Only -notcontains $step.Name) { continue }
    $name = $step.Name
    $stepArgs = $step.Args
    Invoke-GuiScenario -Name "composition-spike-$name" -ScriptBlock {
        Invoke-Spike $name $stepArgs
    }
}
