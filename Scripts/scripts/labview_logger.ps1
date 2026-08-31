[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Start', 'Stop', 'Status', 'Poll')]
    [string]$Action,

    [Parameter(Mandatory = $false)]
    [string]$DataFile,

    [Parameter(Mandatory = $false)]
    [string]$LabVIEWPath = 'C:\Program Files\National Instruments\LabVIEW 2023\LabVIEW.exe',

    [Parameter(Mandatory = $false)]
    [string]$VIPath = 'C:\Path\To\AcquireAndSave.vi',

    [Parameter(Mandatory = $false)]
    [string]$PidFile = "$env:TEMP\labview_logger.pid",

    [Parameter(Mandatory = $false)]
    [string]$DashboardFile = 'C:\Users\5CG7471GSJ\Documents\DATA\Dashboard\dashboard_values.json'
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

function To-Double([string]$Value) {
    try {
        if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
        return [double]($Value.Trim() -replace ',', '.')
    }
    catch { return $null }
}

# Shared helper to merge a section into dashboard_values.json (same pattern as
# the Shelly/Tarom loggers), so the live dashboard can read the LabVIEW POA
# sensor values even though they are not pushed separately.
function Update-DashboardValues {
    param(
        [string]$Path,
        [string]$SectionName,
        [hashtable]$SectionValues,
        [int]$TimeoutSeconds = 15
    )

    $lockPath = "$Path.lock"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lockStream = $null

    try {
        while ($true) {
            try {
                $lockStream = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
                break
            }
            catch {
                if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                    throw "Timeout waiting for dashboard file lock: $lockPath"
                }
                Start-Sleep -Milliseconds 200
            }
        }

        $dashboard = $null

        if (Test-Path $Path) {
            $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $dashboard = $raw | ConvertFrom-Json -ErrorAction Stop
            }
        }

        if ($null -eq $dashboard) {
            $dashboard = [PSCustomObject]@{}
        }

        $section = $dashboard.PSObject.Properties[$SectionName].Value
        if ($null -eq $section) {
            $section = [PSCustomObject]@{}
            $dashboard | Add-Member -MemberType NoteProperty -Name $SectionName -Value $section -Force
        }

        foreach ($key in $SectionValues.Keys) {
            $section | Add-Member -MemberType NoteProperty -Name $key -Value $SectionValues[$key] -Force
        }

        $dashboard | Add-Member -MemberType NoteProperty -Name 'ts_local' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Force

        $json = $dashboard | ConvertTo-Json -Depth 20
        $tempPath = "$Path.$PID.tmp"

        [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))

        if (Test-Path $Path) {
            Remove-Item -Path $Path -Force
        }

        Move-Item -Path $tempPath -Destination $Path -Force
    }
    finally {
        if ($lockStream) {
            $lockStream.Close()
            $lockStream.Dispose()
        }

        if (Test-Path $lockPath) {
            Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue
        }
    }
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

    # Spawn a background dashboard poller: it reads the last line of the LabVIEW
    # data file and updates the 'sensors' section of dashboard_values.json so the
    # live dashboard can display the POA irradiance/temperature values.
    $pollArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath,
        '-Action', 'Poll',
        '-DataFile', ([IO.Path]::GetFullPath($DataFile)),
        '-PidFile', $PidFile,
        '-DashboardFile', $DashboardFile
    )
    Start-Process -FilePath 'powershell.exe' -ArgumentList $pollArgs -WindowStyle Hidden | Out-Null

    Write-Output "Started PID=$($p.Id) (dashboard poller spawned)"
    exit 0
}

if ($Action -eq 'Poll') {
    # Single background poller per run; exit if another poller is already active.
    $pollerPidFile = "$PidFile.poll"
    if (Test-Path -LiteralPath $pollerPidFile) {
        try {
            $existingPollPid = [int](Get-Content -LiteralPath $pollerPidFile -Raw).Trim()
            if (Get-Process -Id $existingPollPid -ErrorAction SilentlyContinue) {
                exit 0
            }
        }
        catch { }
    }
    Set-Content -LiteralPath $pollerPidFile -Value $PID -Encoding ascii

    $lastValues = @{ ts_local = Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }

    while ($true) {
        # Stop polling together with the LabVIEW process.
        if ($null -eq (Get-TrackedProcess)) { break }

        try {
            $lastLine = Get-Content -LiteralPath $DataFile -Tail 4 |
                Where-Object { $_ -and $_.Trim() -ne '' } |
                Select-Object -Last 1

            if (-not [string]::IsNullOrWhiteSpace($lastLine)) {
                $parts = $lastLine -split "`t"
                $current = @{ ts_local = Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }

                if ($parts.Count -ge 3) {
                    $current.Ge_front = To-Double $parts[1]
                    $current.Ge_back = To-Double $parts[2]
                }
                if ($parts.Count -ge 8) {
                    $current.TC1 = To-Double $parts[3]
                    $current.TC2 = To-Double $parts[4]
                    $current.TC3 = To-Double $parts[5]
                    $current.TC4 = To-Double $parts[6]
                }

                # Keep last known values when nothing new could be parsed.
                foreach ($key in $current.Keys) {
                    if ($null -ne $current[$key]) { $lastValues[$key] = $current[$key] }
                }
                $lastValues['ts_local'] = $current['ts_local']
            }

            Update-DashboardValues -Path $DashboardFile -SectionName 'sensors' -SectionValues $lastValues
        }
        catch { }

        Start-Sleep -Seconds 10
    }

    Remove-Item -LiteralPath $pollerPidFile -Force -ErrorAction SilentlyContinue
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
