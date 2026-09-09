param(
    [string]$OutFile = "C:\Users\5CG7471GSJ\Documents\DATA\Load\load_consumption.txt"
)

$ServerUri = "https://shelly-269-eu.shelly.cloud"

$Devices = @{
    "206ef102c9d8" = "ps1"
    "98a3167b6a8c" = "ps2"
    "98a3166b6128" = "ps3"
}

$AuthKey = "NDNjNTY2dWlk1D1F1B180829FDCE99E643ADD908CB1444A568CF4735F062A4213FE319E3EDAB909C61CC9E7055EE"

$DashboardFile = "C:\Users\5CG7471GSJ\Documents\DATA\Dashboard\dashboard_values.json"

$PollIntervalSeconds = 60

$Headers = @(
    "ts",
    "total_power_w"
)

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

function Get-DeviceTotalPower {
    param(
        [object]$Payload
    )

    $deviceStatus = $Payload.data.device_status
    $totalPower = 0.0

    foreach ($property in $deviceStatus.PSObject.Properties) {

        if ($property.Name -like "switch:*") {

            $socket = $property.Value

            if ($null -ne $socket -and $null -ne $socket.apower) {
                $totalPower += [double]$socket.apower
            }
        }
    }

    return $totalPower
}

function Append-TotalPower {
    param(
        [double]$TotalPower,
        [string]$Path
    )

    Ensure-Header -Path $Path

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $line = @(
        $ts
        $TotalPower
    ) -join "`t"

    Add-Content `
        -Path $Path `
        -Value $line `
        -Encoding utf8
}

function Log-Error {
    param(
        [string]$Message,
        [string]$Path
    )

    Ensure-Header -Path $Path

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    Add-Content `
        -Path $Path `
        -Value "# ERROR`t$ts`t$Message" `
        -Encoding utf8
}

while ($true) {

    try {

        # Total power across ALL sockets of ALL three strips
        $grandTotalPower = 0.0

        foreach ($deviceId in $Devices.Keys) {

            $payload = Fetch-Status -DeviceId $deviceId

            if (-not $payload.isok) {
                throw ($payload | ConvertTo-Json -Depth 10 -Compress)
            }

            $grandTotalPower += Get-DeviceTotalPower -Payload $payload

            # Small delay between API requests
            Start-Sleep -Milliseconds 1200
        }

        Append-TotalPower `
            -TotalPower $grandTotalPower `
            -Path $OutFile

        Write-Host (
    	    "[{0}]  logged total consumption: {1:N2} W" -f `
            (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), `
            $grandTotalPower
        )

        Update-DashboardValues -Path $DashboardFile -SectionName 'load' -SectionValues @{
                        ts_local = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        load_active_total_w = $grandTotalPower
        }
    }
    catch {

        Log-Error `
            -Message $_.Exception.Message `
            -Path $OutFile

        Write-Host "error: $($_.Exception.Message)"

        # The load is not reachable via the API (e.g. disconnected). Do NOT keep
        # reporting the last recorded consumption - report the total load as 0
        # so the logs/dashboard reflect that no load is being measured.
        Update-DashboardValues -Path $DashboardFile -SectionName 'load' -SectionValues @{
                        ts_local = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        load_active_total_w = 0.0
        }
    }

    Start-Sleep -Seconds $PollIntervalSeconds
}
