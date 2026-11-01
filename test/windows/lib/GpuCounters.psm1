# Per-process GPU memory / GPU engine load / CPU load of one process, without
# localized counter paths: the CIM performance classes have fixed English
# class and property names, whatever the Windows language.
#
#   Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory
#       instances `pid_<PID>_luid_0x........_0x........_phys_<n>`
#       DedicatedUsage, SharedUsage (bytes)
#   Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine
#       instances `pid_<PID>_luid_..._phys_<n>_eng_<m>_engtype_3D`
#       UtilizationPercentage
#
# The classes are absent on some drivers and VMs (WARP has no per-process GPU
# memory): every function returns $null then and callers write empty columns.
# Used by measure-ram.ps1 and e2e/hidden-render.ps1. Windows PowerShell 5.1,
# ASCII only.

Set-StrictMode -Version Latest

$script:MemClass = 'Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory'
$script:EngClass = 'Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine'

# Pure: the rows (objects with a Name) of one process, optionally only those
# whose name matches `$NameRegex` too.
function Select-GpuPidRows {
    param([object[]]$Rows, [int]$ProcessId, [string]$NameRegex)
    $prefix = '^pid_{0}_' -f $ProcessId
    @($Rows | Where-Object {
        $n = [string]$_.Name
        $n -match $prefix -and (-not $NameRegex -or $n -match $NameRegex)
    })
}

function Test-GpuCounterClass([string]$ClassName) {
    try {
        [bool](Get-CimClass -ClassName $ClassName -ErrorAction Stop)
    } catch {
        $false
    }
}

# True when both classes exist.
function Test-GpuCounters {
    (Test-GpuCounterClass $script:MemClass) -and (Test-GpuCounterClass $script:EngClass)
}

# Dedicated and shared GPU memory of the process in MB (summed over its
# adapter instances), or $null when the class is absent.
function Get-GpuProcessMemoryMb {
    param([Parameter(Mandatory)][int]$ProcessId)
    if (-not (Test-GpuCounterClass $script:MemClass)) { return $null }
    try {
        $rows = @(Get-CimInstance -ClassName $script:MemClass -ErrorAction Stop)
    } catch {
        return $null
    }
    $mine = @(Select-GpuPidRows -Rows $rows -ProcessId $ProcessId)
    $ded = 0.0
    $shr = 0.0
    foreach ($r in $mine) {
        $ded += [double]$r.DedicatedUsage
        $shr += [double]$r.SharedUsage
    }
    [pscustomobject]@{
        Dedicated = [math]::Round($ded / 1MB, 1)
        Shared    = [math]::Round($shr / 1MB, 1)
        Total     = [math]::Round(($ded + $shr) / 1MB, 1)
        Instances = $mine.Count
    }
}

# GPU 3D engine load of the process in percent right now (all its 3D engine
# instances summed), or $null when the class is absent.
function Get-GpuEngine3dPercent {
    param([Parameter(Mandatory)][int]$ProcessId)
    if (-not (Test-GpuCounterClass $script:EngClass)) { return $null }
    try {
        $rows = @(Get-CimInstance -ClassName $script:EngClass -ErrorAction Stop)
    } catch {
        return $null
    }
    $sum = 0.0
    foreach ($r in @(Select-GpuPidRows -Rows $rows -ProcessId $ProcessId -NameRegex '_engtype_3D$')) {
        $sum += [double]$r.UtilizationPercentage
    }
    $sum
}

function Get-CpuSeconds([Diagnostics.Process]$Process) {
    $Process.Refresh()
    $Process.TotalProcessorTime.TotalSeconds
}

# Pure: CPU seconds used over a wall-clock window as a percentage of one core
# (`-PerMachine`: of the whole machine, divided by the logical CPU count).
function ConvertTo-CpuPercent {
    param([double]$CpuSeconds, [double]$WallSeconds, [int]$LogicalCpus = 1, [switch]$PerMachine)
    if ($WallSeconds -le 0) { return 0.0 }
    $p = $CpuSeconds / $WallSeconds * 100.0
    if ($PerMachine -and $LogicalCpus -gt 0) { $p = $p / $LogicalCpus }
    $p
}

# Pure: nearest-rank percentile of a list (P in 0..100); $null for an empty list.
function Get-Percentile {
    param([double[]]$Values, [double]$P)
    $v = @($Values | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    $rank = [math]::Ceiling($P / 100.0 * $v.Count)
    if ($rank -lt 1) { $rank = 1 }
    if ($rank -gt $v.Count) { $rank = $v.Count }
    [double]$v[[int]$rank - 1]
}

# Watches the process for `-Seconds`: CPU from the TotalProcessorTime delta
# over the wall time (percent of one core, and of the whole machine) and the
# GPU 3D load as the mean of one sample per second. `Gpu3d` is $null when the
# engine class is absent. `-Tick` runs once a second (the GUI lock refresh).
function Measure-ProcessLoad {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [int]$Seconds = 10,
        [scriptblock]$Tick
    )
    $cpu0 = Get-CpuSeconds $Process
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $gpu = [System.Collections.Generic.List[double]]::new()
    $haveGpu = Test-GpuCounterClass $script:EngClass
    for ($i = 0; $i -lt $Seconds; $i++) {
        Start-Sleep -Milliseconds 1000
        if ($Process.HasExited) { throw 'the process exited while it was being measured' }
        if ($haveGpu) {
            $g = Get-GpuEngine3dPercent -ProcessId $Process.Id
            if ($null -ne $g) { $gpu.Add([double]$g) }
        }
        if ($Tick) { & $Tick }
    }
    $wall = $sw.Elapsed.TotalSeconds
    $cpu1 = Get-CpuSeconds $Process
    $n = [Environment]::ProcessorCount
    [pscustomobject]@{
        CpuCore    = ConvertTo-CpuPercent -CpuSeconds ($cpu1 - $cpu0) -WallSeconds $wall
        CpuMachine = ConvertTo-CpuPercent -CpuSeconds ($cpu1 - $cpu0) -WallSeconds $wall -LogicalCpus $n -PerMachine
        Gpu3d      = $(if ($gpu.Count) { [math]::Round((($gpu | Measure-Object -Average).Average), 2) } else { $null })
        Seconds    = [math]::Round($wall, 2)
    }
}

Export-ModuleMember -Function Select-GpuPidRows, Test-GpuCounters, Test-GpuCounterClass, Get-GpuProcessMemoryMb, Get-GpuEngine3dPercent, Get-CpuSeconds, ConvertTo-CpuPercent, Get-Percentile, Measure-ProcessLoad
