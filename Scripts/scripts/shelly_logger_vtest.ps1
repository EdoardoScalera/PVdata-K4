param(
    [string]$OutFile = "C:\Users\scalere1\OneDrive - Aalto University\Desktop\shelly_data.txt"
)

$ServerUri = "https://shelly-269-eu.shelly.cloud"

$Devices = @{
    "206ef102c9d8" = "ps1"
    "98a3167b6a8c" = "ps2"
    "98a3166b6128" = "ps3"
}

$AuthKey = "NDNjNTY2dWlk1D1F1B180829FDCE99E643ADD908CB1444A568CF4735F062A4213FE319E3EDAB909C61CC9E7055EE"


$PollIntervalSeconds = 60

$Headers = @(
    "ts",
    "total_power_w",
    "status",
    "error"
)


function Ensure-Header {
    param([string]$Path)

    if (-not (Test-Path $Path) -or ((Get-Item $Path).Length -eq 0)) {
        ($Headers -join "`t") | Out-File -FilePath $Path -Encoding utf8
    }
}

function Fetch-Status {
    param([string]$DeviceId)

    $body = @{
        id       = $DeviceId
        auth_key = $AuthKey
    }

    $delay = 2

    for ($i = 1; $i -le 5; $i++) {
        try {
            return Invoke-RestMethod `
                -Method Post `
                -Uri "$ServerUri/device/status" `
                -Body $body `
                -ErrorAction Stop
        }
        catch {
            if ($_.Exception.Response -and
                $_.Exception.Response.StatusCode.value__ -eq 429) {

                Start-Sleep -Seconds $delay
                $delay *= 2
            }
            else {
                throw
            }
        }
    }

    throw "Too many requests after retries for device $DeviceId"
}

# Like Fetch-Status, but reports offline as $null instead of throwing, so the
# loop can continue checking the remaining devices and report their status.
function Fetch-StatusSafe {
    param([string]$DeviceId)
    try {
        return Fetch-Status -DeviceId $DeviceId
    }
    catch {
        return $null
    }
}

function Get-DeviceTotalPower {
    param(
        [object]$DeviceStatus
    )

    $totalPower = 0.0

    foreach ($property in $DeviceStatus.PSObject.Properties) {

        if ($property.Name -like "switch:*") {

            $socket = $property.Value

            if ($null -ne $socket -and $null -ne $socket.apower) {
                $totalPower += [double]$socket.apower
            }
        }
    }

    return $totalPower
}

# Classify a single device read into one of three research-grade states. It
# relies only on the current response (no history kept):
#   OK      - valid measurement received and usable
#   OFFLINE - device/API unreachable (connection failed/timeout)
#   INVALID - response received but unusable (isok=false / no device_status)
# Returns [PSCustomObject]@{ status; power_w ($null when not OK); error }.
function Get-DeviceReadState {
    param(
        [string]$DeviceId
    )

    $payload = Fetch-StatusSafe -DeviceId $DeviceId

    if ($null -eq $payload) {
        # Fetch-StatusSafe swallowed an exception: offline/timeout/connection.
        return [PSCustomObject]@{
            status  = 'OFFLINE'
            power_w = $null
            error   = 'connection failed'
        }
    }

    if (-not $payload.isok) {
        return [PSCustomObject]@{
            status  = 'INVALID'
            power_w = $null
            error   = 'isok=false'
        }
    }

    $deviceStatus = $payload.data.device_status
    if ($null -eq $deviceStatus) {
        return [PSCustomObject]@{
            status  = 'INVALID'
            power_w = $null
            error   = 'no device_status'
        }
    }

    # Classification relies only on the current response. No history is kept,
    # so a brief online interval (e.g. the load turning on for a single minute
    # after being off) is recorded as OK based on the live data in this poll;
    # it is not penalized by how long the device was offline before.
    return [PSCustomObject]@{
        status  = 'OK'
        power_w = Get-DeviceTotalPower -DeviceStatus $deviceStatus
        error   = ''
    }
}

function Append-Record {
    param(
        [string]$Timestamp,
        [Nullable[double]]$TotalPower,
        [string]$Status,
        [string]$ErrorText,
        [string]$Path
    )

    Ensure-Header -Path $Path

    $powerCell = ""
    if ($null -ne $TotalPower) {
        $powerCell = $TotalPower.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }

    $line = @(
        $Timestamp
        $powerCell
        $Status
        $ErrorText
    ) -join "`t"

    Add-Content `
        -Path $Path `
        -Value $line `
        -Encoding utf8
}

# Fixed-time scheduling: each cycle is anchored to the start of the previous
# cycle plus the poll interval, so reads happen at a steady cadence without
# cumulative drift regardless of how long the API calls take.
$nextRun = Get-Date

while ($true) {

    $cycleStart = Get-Date

    try {

        # Read and classify every device.
        $readStates = @()
        foreach ($deviceId in $Devices.Keys) {

            $readStates += [PSCustomObject]@{
                device_id = $deviceId
                name      = $Devices[$deviceId]
                state     = Get-DeviceReadState -DeviceId $deviceId
            }

            # Small delay between API requests
            Start-Sleep -Milliseconds 1200
        }

        # Aggregate to a single status for this loop.
        $onlineCount  = 0
        $offlineCount = 0
        $invalidCount = 0
        $errorParts   = @()
        foreach ($read in $readStates) {
            switch ($read.state.status) {
                'OK'      { $onlineCount++ }
                'OFFLINE' { $offlineCount++ }
                'INVALID' { $invalidCount++ }
            }
            if ($read.state.error) {
                $errorParts += ("{0}: {1}" -f $read.name, $read.state.error)
            }
        }
        $errorText = $errorParts -join "; "

        if ($onlineCount -eq $Devices.Count) {
            $overallStatus = 'OK'
        }
        elseif ($onlineCount -gt 0) {
            # Some but not all devices usable; total still computed from online ones.
            $overallStatus = 'PARTIAL'
        }
        elseif ($offlineCount -gt 0) {
            $overallStatus = 'OFFLINE'
        }
        else {
            $overallStatus = 'INVALID'
        }

        # Always calculate total power from the available (online) devices.
        # Offline/unusable devices contribute 0 but are noted in the error column.
        $grandTotalPower = 0.0
        foreach ($read in $readStates) {
            if ($read.state.status -eq 'OK') {
                $grandTotalPower += [double]$read.state.power_w
            }
        }

        # Feedback on connection status of every device, printed every loop.
        $statusParts = foreach ($read in $readStates) {
            "{0} ({1})={2}" -f $read.name, $read.device_id, $read.state.status
        }
        Write-Host (
            "[{0}]  Device status: {1}" -f `
            (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), `
            ($statusParts -join "  ")
        )

        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Append-Record `
            -Timestamp $ts `
            -TotalPower $grandTotalPower `
            -Status $overallStatus `
            -ErrorText $errorText `
            -Path $OutFile

        Write-Host (
            "[{0}]  aggregate total: {1:N2} W (status {2})" -f `
            (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), `
            $grandTotalPower, `
            $overallStatus
        )

    }
    catch {

        # Final safety net for unexpected loop errors (e.g. file write): record
        # the failure as an OFFLINE-style row rather than silently continuing.
        try {
            Append-Record `
                -Timestamp (Get-Date -Format "yyyy-MM-dd HH:mm:ss") `
                -TotalPower 0 `
                -Status 'OFFLINE' `
                -ErrorText $_.Exception.Message `
                -Path $OutFile
        }
        catch { }

        Write-Host "error: $($_.Exception.Message)"

    }

    # Fixed 60s cadence: sleep until the next cycle deadline (previous start + interval).
    $nextRun = $cycleStart.AddSeconds($PollIntervalSeconds)
    $sleepMilliseconds = ($nextRun - (Get-Date)).TotalMilliseconds
    if ($sleepMilliseconds -gt 0) {
        Start-Sleep -Milliseconds ([int]$sleepMilliseconds)
    }
}
