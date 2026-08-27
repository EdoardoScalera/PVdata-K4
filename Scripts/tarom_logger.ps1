# Tarom MPPT 6000-M logger (PowerShell)
# Reads from COM3 and appends each line to a CSV file.

# --- USER SETTINGS ---
$portName = "COM3"
$baudRate = 4800
$logFile  = "C:\\Users\\5CG7471GSJ\\Documents\\DATA\\PV\\pv_data.txt"
$DashboardFile = "C:\Users\5CG7471GSJ\Documents\DATA\Dashboard\dashboard_values.json"


# Ensure log directory exists
$logDir = Split-Path $logFile
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

# Write header once if file does not exist
if (-not (Test-Path $logFile)) {
    # Your requested header (tab-separated)
    $header = "op`tdate`ttime`tbattery_voltage_V`tpv1_voltage_V`tpv2_voltage_V`text_batt_sense_V`treserved_1`tmppt_charge_current_A`ttotal_batt_current_A`ttotal_batt_discharge_current_A`tpv_power_total_W`tpv_power_1_W`tpv_power_2_W`tbattery_temperature_C`tsoc_percent`toperating_state`terror_flag`twarning_flag`tday_night_flag`toperating_hours_h`tdaily_yield_Wh`ttotal_yield_Wh`treserved_2`tchecksum"
    $header | Out-File -FilePath $logFile -Encoding UTF8
}

# --- OPEN SERIAL PORT ---
$port = New-Object System.IO.Ports.SerialPort $portName, $baudRate, 'None', 8, 1
$port.Handshake   = 'None'
$port.ReadTimeout = 60000   # 60 s timeout (Tarom sends every minute)
$port.Open()

Write-Host "Logging from $portName to $logFile. Press Ctrl+C to stop."

try {
    while ($true) {
        try {
            $line = $port.ReadLine()
            $line = $line.Trim()

            if ($line.Length -gt 0) {
                # Convert Tarom's semicolon-separated line to tab-separated
                $taromTabbed = $line -replace ';', "`t"

                # Append just the Tarom fields (no PC timestamp / logger name)
                Add-Content -Path $logFile -Value $taromTabbed -Encoding UTF8

                Write-Host $line
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