$ServerUri = "https://shelly-269-eu.shelly.cloud"

$Devices = @{
    "206ef102c9d8" = "ps1"
    "98a3167b6a8c" = "ps2"
    "98a3166b6128" = "ps3"
}

$AuthKey = "NDNjNTY2dWlk1D1F1B180829FDCE99E643ADD908CB1444A568CF4735F062A4213FE319E3EDAB909C61CC9E7055EE"
$OutFile = "C:\\Users\\5CG7471GSJ\\Documents\\DATA\\Load\\load.txt"
$PollIntervalSeconds = 60
$SocketKeys = @("switch:0", "switch:1", "switch:2", "switch:3")
$Headers = @("ts_utc", "device_name", "socket_id", "power_w", "current_a", "voltage_v", "frequency_hz")

function Ensure-Header {
    param([string]$Path)
    if (-not (Test-Path $Path) -or ((Get-Item $Path).Length -eq 0)) {
        ($Headers -join "`t") | Out-File -FilePath $Path -Encoding utf8
    }
}

function Fetch-Status {
    param([string]$DeviceId)

    $body = @{
        id = $DeviceId
        auth_key = $AuthKey
    }

    $delay = 2
    for ($i = 1; $i -le 5; $i++) {
        try {
            return Invoke-RestMethod -Method Post -Uri "$ServerUri/device/status" -Body $body -ErrorAction Stop
        }
        catch {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 429) {
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

function Normalize-Status {
    param(
        [object]$Payload,
        [string]$DeviceId,
        [string]$DeviceName
    )

    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    $ds = $Payload.data.device_status
    $rows = @()

    foreach ($key in $SocketKeys) {
        $sw = $ds.$key
        if ($null -ne $sw) {
            $row = [PSCustomObject]@{
                ts_utc       = $ts
                device_name  = $DeviceName
                socket_id    = $sw.id
                power_w      = $sw.apower
                current_a    = $sw.current
                voltage_v    = $sw.voltage
                frequency_hz = $sw.freq
            }
            $rows += $row
        }
    }

    return $rows
}

function Append-Rows {
    param(
        [array]$Rows,
        [string]$Path
    )

    Ensure-Header -Path $Path

    foreach ($row in $Rows) {
        $line = @(
            $row.ts_utc,
            $row.device_name,
            $row.socket_id,
            $row.power_w,
            $row.current_a,
            $row.voltage_v,
            $row.frequency_hz
        ) -join "`t"

        Add-Content -Path $Path -Value $line -Encoding utf8
    }
}

function Log-Error {
    param(
        [string]$Message,
        [string]$Path
    )

    Ensure-Header -Path $Path
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $Path -Value "# ERROR`t$ts`t$Message" -Encoding utf8
}

while ($true) {
    try {
        $allRows = @()

        foreach ($deviceId in $Devices.Keys) {
            $deviceName = $Devices[$deviceId]

            $payload = Fetch-Status -DeviceId $deviceId
            if (-not $payload.isok) {
                throw ($payload | ConvertTo-Json -Depth 10 -Compress)
            }

            $allRows += Normalize-Status -Payload $payload -DeviceId $deviceId -DeviceName $deviceName
            Start-Sleep -Milliseconds 1200
        }

        Append-Rows -Rows $allRows -Path $OutFile
        Write-Host "logged $($allRows.Count) rows at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    }
    catch {
        Log-Error -Message $_.Exception.Message -Path $OutFile
        Write-Host "error: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $PollIntervalSeconds
}