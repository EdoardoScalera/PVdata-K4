# Tarom MPPT 6000-M logger (PowerShell)
# Reads from COM3 and appends each line to a CSV file.
param(
    [string]$OutFile = "C:\Users\5CG7471GSJ\Documents\DATA\PV\pv_mppt.txt"
)

# --- USER SETTINGS ---
$portName = "COM3"
$baudRate = 4800
$DashboardFile = "C:\Users\5CG7471GSJ\Documents\DATA\Dashboard\dashboard_values.json"

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


# Ensure log directory exists
$logDir = Split-Path $OutFile
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

# Write header once if file does not exist
if (-not (Test-Path $OutFile)) {
    $header = "device_status" + `
          "`tdate" + `
          "`ttime" + `
          "`tbattery_voltage_V" + `
          "`tpv1_voltage_V" + `
          "`tpv2_voltage_V" + `
          "`tSOC" + ` # # for voltage control
          "`tcapacity_Ah" + ` # # if not computed
          "`ttotal_charge_discharge_battery_A" + `
          "`tpv1_current_A" + `
          "`tpv2_current_A" + `
          "`tmodule_current_A" + ` # # info not present 
          "`ttotal_batt_current_A" + `
          "`tload_current_A" + ` # # info not present
          "`ttotal_batt_discharge_current_A" + `
          "`ttemperature_C" + `
          "`terror" + ` # Error state: 0-No errors, 1-Information, 2-Warning, 3-Error
          "`tcharging_mode" + `
          "`tAUX1" + `
          "`tAUX2" + `
          "`tAUX3" + `
          "`tenergy_input_24h_Ah" + `
          "`tenergy_input_tot_Ah" + `
          "`tenergy_output_24h_Ah" + `
          "`tenergy_output_tot_Ah" + `
          "`tderating_Ah" + `
          "`tchecksum" + `
          "`tpv1_power_W" + `
          "`tpv2_power_W" + `
          "`tpv_power_total_W"
    $header | Out-File -FilePath $OutFile -Encoding UTF8
}

# --- OPEN SERIAL PORT ---
$port = New-Object System.IO.Ports.SerialPort $portName, $baudRate, 'None', 8, 1
$port.Handshake   = 'None'
$port.ReadTimeout = 60000   # 60 s timeout (Tarom sends every minute)
$port.Open()

Write-Host "Logging from $portName to $OutFile. Press Ctrl+C to stop."

try {
    while ($true) {
        try {
            $line = $port.ReadLine()
            $line = $line.Trim()

            if ($line.Length -gt 0) {
                $fields = $line -split ';'

                $pv1Voltage = [double]($fields[4] -replace ',', '.')
                $pv2Voltage = [double]($fields[5] -replace ',', '.')
                $pv1Current = [double]($fields[9] -replace ',', '.')
                $pv2Current = [double]($fields[10] -replace ',', '.')

                $pv1Power = [math]::Round($pv1Voltage * $pv1Current, 2)
                $pv2Power = [math]::Round($pv2Voltage * $pv2Current, 2)
                $pvTotalPower = [math]::Round($pv1Power + $pv2Power, 2)

                # Convert the original Tarom fields to tab-separated output
		$outputFields = $fields | ForEach-Object { $_ }

		# Append calculated PV powers
		$outputFields += $pv1Power.ToString([System.Globalization.CultureInfo]::InvariantCulture)
		$outputFields += $pv2Power.ToString([System.Globalization.CultureInfo]::InvariantCulture)
		$outputFields += $pvTotalPower.ToString([System.Globalization.CultureInfo]::InvariantCulture)

		# Write complete original record + calculated values
		Add-Content -Path $OutFile -Value ($outputFields -join "`t") -Encoding UTF8

                Write-Host $line
            }

        Update-DashboardValues -Path $DashboardFile -SectionName 'pv' -SectionValues @{
                        source_ts_local = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        pv1_power_w = $pv1Power
                        pv2_power_w = $pv2Power
                        pv_power_total_w = $pvTotalPower
                    }

        }
        catch [System.TimeoutException] {
            continue
        }
    }
}
finally {
    if ($port.IsOpen) {
        $port.Close()
    }
    Write-Host "Serial port closed."
}