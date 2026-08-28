[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Start', 'Stop', 'Status')]
    [string]$Action,

    [Parameter(Mandatory = $false)]
    [string]$DataFile,

    [Parameter(Mandatory = $false)]
    [string]$LabVIEWPath = 'C:\Program Files\National Instruments\LabVIEW 2023\LabVIEW.exe',

    [Parameter(Mandatory = $false)]
    [string]$VIPath = 'C:\Path\To\AcquireAndSave.vi',

    [Parameter(Mandatory = $false)]
    [string]$PidFile = "$env:TEMP\labview_logger.pid"
)

$ErrorActionPreference = 'Stop'

function Get-TrackedProcess {
    if (-not (Test-Path -LiteralPath $PidFile)) { return $null }
    try { $id = [int](Get-Content -LiteralPath $PidFile -Raw).Trim() } catch { return $null }
    try { Get-Process -Id $id -ErrorAction Stop } catch { return $null }
}

function Save-Pid([int]$Id) {
    Set-Content -LiteralPath $PidFile -Value $Id -Encoding ascii
}

function Remove-Pid {
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
}

if ($Action -eq 'Status') {
    $p = Get-TrackedProcess
    if ($null -eq $p) {
        Remove-Pid
        Write-Output 'Stopped'
        exit 0
    }
    Write-Output "Running PID=$($p.Id)"
    exit 0
}

if ($Action -eq 'Start') {
    if ([string]::IsNullOrWhiteSpace($DataFile)) { throw 'DataFile is required for Start.' }
    if (-not (Test-Path -LiteralPath $LabVIEWPath -PathType Leaf)) { throw "LabVIEW.exe not found: $LabVIEWPath" }
    if (-not (Test-Path -LiteralPath $VIPath -PathType Leaf)) { throw "VI not found: $VIPath" }

    $existing = Get-TrackedProcess
    if ($null -ne $existing) {
        Write-Output "Already running PID=$($existing.Id)"
        exit 0
    }

    $dataDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($DataFile))
    if (-not (Test-Path -LiteralPath $dataDirectory)) {
        New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
    }

    $labviewArgs = @($VIPath, '--', ([IO.Path]::GetFullPath($DataFile)))
    $p = Start-Process -FilePath $LabVIEWPath -ArgumentList $labviewArgs -WorkingDirectory (Split-Path -Parent $VIPath) -PassThru
    Save-Pid $p.Id
    Write-Output "Started PID=$($p.Id)"
    exit 0
}

if ($Action -eq 'Stop') {
    $p = Get-TrackedProcess
    if ($null -eq $p) {
        Remove-Pid
        Write-Output 'Not running'
        exit 0
    }

    # Graceful close is preferred. This closes the tracked LabVIEW process;
    # replace with VI Server control if you need to preserve the IDE instance.
    Stop-Process -Id $p.Id -Force
    Remove-Pid
    Write-Output "Stopped PID=$($p.Id)"
    exit 0
}
