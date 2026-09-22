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
$MaxDataAgeSeconds  = 180  # 3 minutes — data older than this is considered stale
$MinUptimeSeconds   = 60   # device must have been up for at least one poll cycle

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

# Verify that a device_status payload represents current, live data rather than
# a stale cached response from an offline device.  Handles both Gen1 and Gen4
# field layouts.  Returns @{ fresh; reason }.
function Test-DeviceDataFresh {
    param([object]$DeviceStatus)

    # --- Cloud connectivity (same for Gen1 and Gen4) ---
    $cloudProp = $DeviceStatus.PSObject.Properties['cloud']
    if ($null -ne $cloudProp -and $null -ne $cloudProp.Value) {
        if ($cloudProp.Value.connected -eq $false) {
            return @{ fresh = $false; reason = 'cloud.connected=false' }
        }
    }

    # --- WiFi connectivity ---
    # Gen4: wifi.status is a string ("connected", "got ip", "disconnected")
    $wifiProp = $DeviceStatus.PSObject.Properties['wifi']
    if ($null -ne $wifiProp -and $null -ne $wifiProp.Value) {
        $status = $wifiProp.Value.status
        if ($status -in @('disconnected', 'connecting')) {
            return @{ fresh = $false; reason = "wifi.status=$status" }
        }
    }
    # Gen1 fallback: wifi_sta.connected is a boolean
    $wifiStaProp = $DeviceStatus.PSObject.Properties['wifi_sta']
    if ($null -ne $wifiStaProp -and $null -ne $wifiStaProp.Value) {
        if ($wifiStaProp.Value.connected -eq $false) {
            return @{ fresh = $false; reason = 'wifi_sta.connected=false' }
        }
    }

    # --- Uptime: device likely just rebooted and may report stale initial data ---
    $sysProp = $DeviceStatus.PSObject.Properties['sys']
    if ($null -ne $sysProp -and $null -ne $sysProp.Value) {
        $uptimeProp = $sysProp.Value.PSObject.Properties['uptime']
        if ($null -ne $uptimeProp -and $null -ne $uptimeProp.Value) {
            if ([long]$uptimeProp.Value -lt $MinUptimeSeconds) {
                return @{
                    fresh  = $false
                    reason = "uptime=$($uptimeProp.Value)s (< ${MinUptimeSeconds}s)"
                }
            }
        }
    }

    # --- Data freshness via switch aenergy.minute_ts (Gen4, strongest signal) ---
    # When the device is offline this timestamp freezes; when online it advances
    # every minute.
    foreach ($property in $DeviceStatus.PSObject.Properties) {
        if ($property.Name -like "switch:*" -and $null -ne $property.Value) {
            $aenergy = $property.Value.aenergy
            if ($null -ne $aenergy -and $null -ne $aenergy.minute_ts) {
                $minuteTs = [long]$aenergy.minute_ts
                if ($minuteTs -gt 0) {
                    $nowUnix = [long][Math]::Floor(
                        ([DateTimeOffset]::UtcNow).ToUnixTimeSeconds()
                    )
                    $ageSeconds = $nowUnix - $minuteTs
                    if ($ageSeconds -gt $MaxDataAgeSeconds) {
                        return @{
                            fresh  = $false
                            reason = "aenergy stale (${ageSeconds}s old)"
                        }
                    }
                    break
                }
            }
        }
    }

    # --- Fallback: data freshness via sys.unixtime (Gen4) or unixtime (Gen1) ---
    if ($null -ne $sysProp -and $null -ne $sysProp.Value) {
        $unixProp = $sysProp.Value.PSObject.Properties['unixtime']
        if ($null -ne $unixProp -and $null -ne $unixProp.Value) {
            $deviceUnix = [long]$unixProp.Value
            if ($deviceUnix -gt 0) {
                $nowUnix = [long][Math]::Floor(
                    ([DateTimeOffset]::UtcNow).ToUnixTimeSeconds()
                )
                $ageSeconds = $nowUnix - $deviceUnix
                if ($ageSeconds -gt $MaxDataAgeSeconds) {
                    return @{
                        fresh  = $false
                        reason = "sys.unixtime stale (${ageSeconds}s old)"
                    }
                }
            }
        }
    }
    $unixtimeRoot = $DeviceStatus.PSObject.Properties['unixtime']
    if ($null -ne $unixtimeRoot -and $null -ne $unixtimeRoot.Value) {
        $deviceUnix = [long]$unixtimeRoot.Value
        if ($deviceUnix -gt 0) {
            $nowUnix = [long][Math]::Floor(
                ([DateTimeOffset]::UtcNow).ToUnixTimeSeconds()
            )
            $ageSeconds = $nowUnix - $deviceUnix
            if ($ageSeconds -gt $MaxDataAgeSeconds) {
                return @{
                    fresh  = $false
                    reason = "unixtime stale (${ageSeconds}s old)"
                }
            }
        }
    }

    return @{ fresh = $true; reason = '' }
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

    $freshness = Test-DeviceDataFresh -DeviceStatus $deviceStatus
    if (-not $freshness.fresh) {
        return [PSCustomObject]@{
            status  = 'OFFLINE'
            power_w = $null
            error   = $freshness.reason
        }
    }

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

Write-Host ""
Write-Host "=== Shelly Logger vtest ==="
Write-Host "Devices: $($Devices.Count) | Interval: ${PollIntervalSeconds}s | Stale threshold: ${MaxDataAgeSeconds}s | Min uptime: ${MinUptimeSeconds}s"
Write-Host "Output: $OutFile"
Write-Host "Polling started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

while ($true) {

    $cycleStart = Get-Date

    try {

        # Read and classify every device.
        $readStates = @()
        $deviceIndex = 0
        foreach ($deviceId in $Devices.Keys) {
            $deviceIndex++
            $deviceName = $Devices[$deviceId]
            $tsLog = Get-Date -Format "HH:mm:ss"

            Write-Host ("[{0}]  ({1}/{2}) Querying {3} ({4})..." -f `
                $tsLog, $deviceIndex, $Devices.Count, $deviceName, $deviceId) -NoNewline

            $state = Get-DeviceReadState -DeviceId $deviceId

            if ($state.status -eq 'OK') {
                Write-Host (" -> {0}, {1:N2} W" -f $state.status, $state.power_w)
            }
            elseif ($state.status -eq 'OFFLINE') {
                if ($state.error) {
                    Write-Host (" -> {0}: {1}" -f $state.status, $state.error)
                }
                else {
                    Write-Host (" -> {0}" -f $state.status)
                }
            }
            else {
                if ($state.error) {
                    Write-Host (" -> {0}: {1}" -f $state.status, $state.error)
                }
                else {
                    Write-Host (" -> {0}" -f $state.status)
                }
            }

            $readStates += [PSCustomObject]@{
                device_id = $deviceId
                name      = $deviceName
                state     = $state
            }

            # Small delay between API requests
            if ($deviceIndex -lt $Devices.Count) {
                Start-Sleep -Milliseconds 1200
            }
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
        $sleepSec = [int]([math]::Ceiling($sleepMilliseconds / 1000))
        Write-Host ("[{0}]  Sleeping {1}s until next cycle..." -f `
            (Get-Date -Format "HH:mm:ss"), $sleepSec)
        Start-Sleep -Milliseconds ([int]$sleepMilliseconds)
    }
}
