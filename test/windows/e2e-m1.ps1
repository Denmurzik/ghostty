<#
.SYNOPSIS
The M1 scenarios: e2e.ps1 -Milestone M1.

.PARAMETER Only
Run just these scenarios (names without .ps1).

.PARAMETER EvidenceDir
Where scenarios put PNG captures and logs of failures. Optional.
#>
param(
    [string[]]$Only,
    [string]$EvidenceDir
)

& (Join-Path $PSScriptRoot 'e2e.ps1') -Milestone M1 @PSBoundParameters
exit $LASTEXITCODE
