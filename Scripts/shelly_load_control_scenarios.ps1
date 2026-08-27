param(
    [string]$ConfigPath = ".\shelly_load_control_scenarios.json",
    [switch]$RunOnce,
    [ValidateSet('all_on','whole_house','constant_1kw','adaptive')]
    [string]$Scenario = 'constant_1kw',
    [string]$ScenarioRequestPath = '.\\scenario_request.json',
    [switch]$SetScenario,
    [switch]$SetScenarioAllOn,
    [switch]$SetScenarioWholeHouse,
    [switch]$SetScenarioConstant1kW,
    [switch]$SetScenarioAdaptive,
    [switch]$ShowScenario,
    [switch]$ShowStatus,
    [switch]$ClearScenarioRequest,
    [double]$ConstantTargetW = 1200#,
   # [string]$OutFile = "C:\Users\5CG7471GSJ\Documents\DATA\Load\load_consumption.txt"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LastCommandUtc = [datetime]::MinValue
$script:DeviceOnlineState = @{}
$script:LogPath = $null
$script:CurrentSlotKey = $null
$script:CurrentPlan = $null
$script:CurrentWholeTarget = 0.0
$script:ActiveScenario = $null
$script:PendingScenario = $null
$script:ScenarioRequestPath = $ScenarioRequestPath
$script:ConstantTargetW = $ConstantTargetW
$script:StatusPath = '.\\scenario_status.json'

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

        $sectionProperty = $dashboard.PSObject.Properties[$SectionName]

        if ($null -eq $sectionProperty) {
            $section = [PSCustomObject]@{}
            $dashboard | Add-Member -MemberType NoteProperty -Name $SectionName -Value $section -Force
        }
        else {
            $section = $sectionProperty.Value

            if ($null -eq $section) {
                $section = [PSCustomObject]@{}
                $dashboard | Add-Member -MemberType NoteProperty -Name $SectionName -Value $section -Force
            }
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


function Write-ConsoleLoadChange {
    param([string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

function Ensure-ParentDirectory {
    param([string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Ensure-EventLogFile {
    param([string]$Path)
    Ensure-ParentDirectory -Path $Path
    if (-not (Test-Path $Path)) {
        "ts_local`tlevel`tevent`tstrip_name`tdevice_id`tchannel`tmessage" | Out-File -FilePath $Path -Encoding utf8
    }
}

function Write-EventLog {
    param(
        [string]$Level,
        [string]$Event,
        [string]$StripName = '',
        [string]$DeviceId = '',
        [string]$Channel = '',
        [string]$Message = ''
    )

    if (-not $script:LogPath) { return }
    Ensure-EventLogFile -Path $script:LogPath
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = @($ts, $Level, $Event, $StripName, $DeviceId, $Channel, $Message) -join "`t"
    Add-Content -Path $script:LogPath -Value $line -Encoding utf8
}

function Load-Config {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Config file not found: $Path" }
    Get-Content -Path $Path -Raw | ConvertFrom-Json
}

function Normalize-ScenarioName {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    switch ($Value.Trim().ToLowerInvariant()) {
        '1' { 'all_on' }
        'all_on' { 'all_on' }
        'allon' { 'all_on' }
        'all-on' { 'all_on' }
        '2' { 'whole_house' }
        'whole_house' { 'whole_house' }
        'wholehouse' { 'whole_house' }
        'whole-house' { 'whole_house' }
        '3' { 'constant_1kw' }
        'constant_1kw' { 'constant_1kw' }
        'constant1kw' { 'constant_1kw' }
        'constant-1kw' { 'constant_1kw' }
        '4' { 'adaptive' }
        'adaptive' { 'adaptive' }
        default { throw "Unsupported scenario value '$Value'. Use all_on, whole_house, constant_1kw, or adaptive." }
    }
}

function Resolve-RequestedScenario {
    $helperFlags = @(@(
        @{ Enabled = $SetScenarioAllOn; Value = 'all_on' },
        @{ Enabled = $SetScenarioWholeHouse; Value = 'whole_house' },
        @{ Enabled = $SetScenarioConstant1kW; Value = 'constant_1kw' },
        @{ Enabled = $SetScenarioAdaptive; Value = 'adaptive' }
    ) | Where-Object { $_.Enabled })

    if ($helperFlags.Count -gt 1) {
        throw 'Use only one helper scenario switch at a time.'
    }

    if ($helperFlags.Count -eq 1) {
        return $helperFlags[0].Value
    }

    return (Normalize-ScenarioName -Value $Scenario)
}

function Convert-TimeToMinutes {
    param([string]$Value)
    $parts = $Value.Split(':')
    if ($parts.Count -ne 2) { throw "Invalid time format '$Value'. Use HH:mm." }
    ([int]$parts[0] * 60) + [int]$parts[1]
}

function Get-MinutesOfDay {
    param([datetime]$Timestamp)
    ($Timestamp.Hour * 60) + $Timestamp.Minute
}

function Get-ProfileTarget {
    param([array]$Profile,[int]$MinutesOfDay)
    $selected = $Profile[0]
    foreach ($point in ($Profile | Sort-Object { Convert-TimeToMinutes $_.time })) {
        if ((Convert-TimeToMinutes $point.time) -le $MinutesOfDay) { $selected = $point } else { break }
    }
    [double]$selected.target_w
}

function Get-SlotKey {
    param([datetime]$Timestamp,[int]$StepMinutes)
    $slotMinute = [Math]::Floor($Timestamp.Minute / $StepMinutes) * $StepMinutes
    (Get-Date -Year $Timestamp.Year -Month $Timestamp.Month -Day $Timestamp.Day -Hour $Timestamp.Hour -Minute $slotMinute -Second 0).ToString('yyyy-MM-dd HH:mm')
}

function Get-Next15MinuteBoundary {
    param([datetime]$Now)
    $slotMinute = [Math]::Floor($Now.Minute / 15) * 15
    $currentBoundary = Get-Date -Year $Now.Year -Month $Now.Month -Day $Now.Day -Hour $Now.Hour -Minute $slotMinute -Second 0
    if ($currentBoundary -le $Now) {
        return $currentBoundary.AddMinutes(15)
    }
    return $currentBoundary
}

function New-CandidateLoads {
    param([array]$Strips)
    $candidates = @()
    foreach ($strip in $Strips) {
        for ($i = 0; $i -lt $strip.loads_w.Count; $i++) {
            $candidates += [PSCustomObject]@{
                key = "$($strip.name):$i"
                strip_name = $strip.name
                device_id = $strip.device_id
                socket_id = $i
                rated_load_w = [double]$strip.loads_w[$i]
            }
        }
    }
    return $candidates
}

function Get-BestFitPlan {
    param([array]$Strips,[double]$WholeHouseTargetW)

    $candidates = New-CandidateLoads -Strips $Strips
    $n = $candidates.Count
    if ($n -eq 0) { throw 'No candidate loads found.' }

    $bestMask = 0
    $bestSum = 0.0
    $bestOvershoot = [double]::PositiveInfinity
    $bestAbsError = [double]::PositiveInfinity
    $bestCount = [int]::MaxValue

    $totalMasks = [math]::Pow(2, $n)
    for ($mask = 0; $mask -lt $totalMasks; $mask++) {
        $sum = 0.0
        $count = 0
        for ($i = 0; $i -lt $n; $i++) {
            if ($mask -band (1 -shl $i)) {
                $sum += $candidates[$i].rated_load_w
                $count++
            }
        }

        $overshoot = if ($sum -gt $WholeHouseTargetW) { $sum - $WholeHouseTargetW } else { 0.0 }
        $absError = [Math]::Abs($sum - $WholeHouseTargetW)

        $isBetter = $false
        if ($overshoot -lt $bestOvershoot) {
            $isBetter = $true
        }
        elseif ($overshoot -eq $bestOvershoot -and $absError -lt $bestAbsError) {
            $isBetter = $true
        }
        elseif ($overshoot -eq $bestOvershoot -and $absError -eq $bestAbsError -and $count -lt $bestCount) {
            $isBetter = $true
        }
        elseif ($overshoot -eq $bestOvershoot -and $absError -eq $bestAbsError -and $count -eq $bestCount -and $sum -gt $bestSum) {
            $isBetter = $true
        }

        if ($isBetter) {
            $bestMask = $mask
            $bestSum = $sum
            $bestOvershoot = $overshoot
            $bestAbsError = $absError
            $bestCount = $count
        }
    }

    $selected = @()
    for ($i = 0; $i -lt $n; $i++) {
        if ($bestMask -band (1 -shl $i)) {
            $selected += $candidates[$i]
        }
    }

    $planByStrip = @{}
    foreach ($strip in $Strips) {
        $states = New-Object bool[] $strip.loads_w.Count
        foreach ($pick in ($selected | Where-Object { $_.strip_name -eq $strip.name })) {
            $states[$pick.socket_id] = $true
        }

        $stripMatches = @($selected | Where-Object { $_.strip_name -eq $strip.name })
        if ($stripMatches.Count -gt 0) {
            $stripTarget = ($stripMatches | Measure-Object -Property rated_load_w -Sum | Select-Object -ExpandProperty Sum)
        }
        else {
            $stripTarget = 0
        }

        $planByStrip[$strip.name] = [PSCustomObject]@{
            strip = $strip
            states = $states
            target_strip_w = $stripTarget
        }
    }

    [PSCustomObject]@{
        selected = $selected
        applied_total_w = $bestSum
        overshoot_w = $bestOvershoot
        abs_error_w = $bestAbsError
        by_strip = $planByStrip
    }
}

function Get-AllOnPlan {
    param([array]$Strips)

    $planByStrip = @{}
    $selected = @()
    $appliedTotalW = 0.0

    foreach ($strip in $Strips) {
        $states = New-Object bool[] $strip.loads_w.Count
        $stripTarget = 0.0
        for ($i = 0; $i -lt $strip.loads_w.Count; $i++) {
            $states[$i] = $true
            $load = [double]$strip.loads_w[$i]
            $stripTarget += $load
            $appliedTotalW += $load
            $selected += [PSCustomObject]@{
                key = "$($strip.name):$i"
                strip_name = $strip.name
                device_id = $strip.device_id
                socket_id = $i
                rated_load_w = $load
            }
        }

        $planByStrip[$strip.name] = [PSCustomObject]@{
            strip = $strip
            states = $states
            target_strip_w = $stripTarget
        }
    }

    [PSCustomObject]@{
        selected = $selected
        applied_total_w = $appliedTotalW
        overshoot_w = 0.0
        abs_error_w = 0.0
        by_strip = $planByStrip
    }
}

function Get-AllOffPlan {
    param([array]$Strips)

    $planByStrip = @{}
    foreach ($strip in $Strips) {
        $states = New-Object bool[] $strip.loads_w.Count
        $planByStrip[$strip.name] = [PSCustomObject]@{
            strip = $strip
            states = $states
            target_strip_w = 0.0
        }
    }

    [PSCustomObject]@{
        selected = @()
        applied_total_w = 0.0
        overshoot_w = 0.0
        abs_error_w = 0.0
        by_strip = $planByStrip
    }
}

function Get-ScenarioPlan {
    param(
        [object]$Config,
        [datetime]$Now,
        [string]$Scenario,
        [double]$ConstantTargetW
    )

    $minutes = Get-MinutesOfDay -Timestamp $Now

    switch ($Scenario) {
        'all_on' {
            $script:CurrentWholeTarget = (($Config.strips | ForEach-Object { $_.loads_w } | Measure-Object -Sum).Sum)
            return Get-AllOnPlan -Strips $Config.strips
        }
        'whole_house' {
            $wholeTarget = Get-ProfileTarget -Profile $Config.whole_house_profile -MinutesOfDay $minutes
            $script:CurrentWholeTarget = $wholeTarget
            return Get-BestFitPlan -Strips $Config.strips -WholeHouseTargetW $wholeTarget
        }
        'constant_1kw' {
            $script:CurrentWholeTarget = $ConstantTargetW
            return Get-BestFitPlan -Strips $Config.strips -WholeHouseTargetW $ConstantTargetW
        }
        'adaptive' {
            $script:CurrentWholeTarget = 0.0
            Write-EventLog -Level 'INFO' -Event 'adaptive_placeholder' -Message 'Adaptive scenario placeholder active; applying all-off fallback.'
            return Get-AllOffPlan -Strips $Config.strips
        }
        default {
            throw "Unsupported scenario: $Scenario"
        }
    }
}

function Invoke-ShellyCloud {
    param(
        [string]$ServerUri,
        [string]$Path,
        [hashtable]$Body,
        [int]$TimeoutSec = 15,
        [int]$MinGapMs = 1200
    )

    $elapsedMs = ([datetime]::UtcNow - $script:LastCommandUtc).TotalMilliseconds
    if ($elapsedMs -lt $MinGapMs) {
        Start-Sleep -Milliseconds ([int]($MinGapMs - $elapsedMs))
    }

    $delay = 2
    for ($i = 1; $i -le 3; $i++) {
        try {
            $result = Invoke-RestMethod -Method Post -Uri ($ServerUri + $Path) -Body $Body -TimeoutSec $TimeoutSec -ErrorAction Stop
            $script:LastCommandUtc = [datetime]::UtcNow
            return $result
        }
        catch {
            $script:LastCommandUtc = [datetime]::UtcNow
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 429) {
                Write-EventLog -Level 'WARN' -Event 'rate_limit' -Message "429 Too Many Requests for $Path, retrying in $delay s"
                Start-Sleep -Seconds $delay
                $delay *= 2
            }
            else {
                throw
            }
        }
    }

    throw "Request failed repeatedly for path $Path"
}

function Get-CloudDeviceStatusSafe {
    param(
        [string]$ServerUri,
        [string]$AuthKey,
        [string]$DeviceId,
        [int]$MinGapMs = 1200
    )

    try {
        $body = @{ id = $DeviceId; auth_key = $AuthKey }
        $status = Invoke-ShellyCloud -ServerUri $ServerUri -Path '/device/status' -Body $body -MinGapMs $MinGapMs
        return [PSCustomObject]@{ ok = $true; payload = $status; error = $null }
    }
    catch {
        return [PSCustomObject]@{ ok = $false; payload = $null; error = $_.Exception.Message }
    }
}

function Get-ActualOutputStates {
    param([object]$StatusPayload, [int]$ChannelCount)

    $states = New-Object bool[] $ChannelCount
    $ds = $StatusPayload.data.device_status

    for ($i = 0; $i -lt $ChannelCount; $i++) {
        $key = 'switch:' + $i
        $prop = $ds.PSObject.Properties[$key]
        if ($null -ne $prop -and $null -ne $prop.Value) {
            $states[$i] = [bool]$prop.Value.output
        }
        else {
            $states[$i] = $false
        }
    }

    return $states
}

function Set-CloudRelayStateSafe {
    param(
        [string]$ServerUri,
        [string]$AuthKey,
        [string]$DeviceId,
        [int]$Channel,
        [bool]$On,
        [string]$StripName,
        [int]$MinGapMs = 1200
    )

    $turn = if ($On) { 'on' } else { 'off' }
    $body = @{ id = $DeviceId; auth_key = $AuthKey; channel = $Channel; turn = $turn }

    try {
        Invoke-ShellyCloud -ServerUri $ServerUri -Path '/device/relay/control' -Body $body -MinGapMs $MinGapMs | Out-Null
        Write-EventLog -Level 'INFO' -Event 'send' -StripName $StripName -DeviceId $DeviceId -Channel ([string]$Channel) -Message ("turn={0}" -f $turn)
        return $true
    }
    catch {
        Write-EventLog -Level 'WARN' -Event 'send_failed' -StripName $StripName -DeviceId $DeviceId -Channel ([string]$Channel) -Message ("turn={0}; error={1}" -f $turn, $_.Exception.Message)
        return $false
    }
}

function Sync-StripToDesiredState {
    param(
        [string]$ServerUri,
        [string]$AuthKey,
        [object]$Strip,
        [bool[]]$DesiredStates,
        [int]$MinGapMs = 1200
    )

    $statusResult = Get-CloudDeviceStatusSafe -ServerUri $ServerUri -AuthKey $AuthKey -DeviceId $Strip.device_id -MinGapMs $MinGapMs
    $prevOnline = $false
    if ($script:DeviceOnlineState.ContainsKey($Strip.device_id)) {
        $prevOnline = [bool]$script:DeviceOnlineState[$Strip.device_id]
    }

    if (-not $statusResult.ok) {
        $script:DeviceOnlineState[$Strip.device_id] = $false
        Write-EventLog -Level 'WARN' -Event 'offline' -StripName $Strip.name -DeviceId $Strip.device_id -Message $statusResult.error
        return
    }

    $script:DeviceOnlineState[$Strip.device_id] = $true
    if (-not $prevOnline) {
        Write-EventLog -Level 'INFO' -Event 'online' -StripName $Strip.name -DeviceId $Strip.device_id -Message 'device reachable again'
    }

    $actualStates = Get-ActualOutputStates -StatusPayload $statusResult.payload -ChannelCount $DesiredStates.Count

    for ($i = 0; $i -lt $DesiredStates.Count; $i++) {
        if ($actualStates[$i] -ne $DesiredStates[$i]) {
            Write-EventLog -Level 'INFO' -Event 'reconcile' -StripName $Strip.name -DeviceId $Strip.device_id -Channel ([string]$i) -Message ("actual={0}; desired={1}" -f $(if($actualStates[$i]){'on'}else{'off'}), $(if($DesiredStates[$i]){'on'}else{'off'}))
            [void](Set-CloudRelayStateSafe -ServerUri $ServerUri -AuthKey $AuthKey -DeviceId $Strip.device_id -Channel $i -On $DesiredStates[$i] -StripName $Strip.name -MinGapMs $MinGapMs)
        }
    }
}

function Get-NextCycleStart {
    param([datetime]$Now,[int]$IntervalSeconds)
    $epoch = [datetime]'1970-01-01T00:00:00Z'
    $nowUtc = $Now.ToUniversalTime()
    $elapsed = [int][Math]::Floor(($nowUtc - $epoch).TotalSeconds)
    $next = [int]([Math]::Floor($elapsed / $IntervalSeconds) + 1) * $IntervalSeconds
    return $epoch.AddSeconds($next).ToLocalTime()
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Payload
    )

    Ensure-ParentDirectory -Path $Path
    $Payload | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding utf8
}

function Write-ScenarioRequestFile {
    param(
        [string]$Path,
        [string]$ScenarioName,
        [double]$ConstantTargetW
    )

    $payload = [PSCustomObject]@{
        scenario = $ScenarioName
        requested_at_local = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        requested_for_slot = (Get-Next15MinuteBoundary -Now (Get-Date)).ToString('yyyy-MM-dd HH:mm:ss')
        constant_target_w = $ConstantTargetW
    }

    Write-JsonFile -Path $Path -Payload $payload
}

function Get-RequestedScenarioFromFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }

    try {
        $request = Get-Content -Path $Path -Raw | ConvertFrom-Json
        if ($null -eq $request.scenario) { return $null }
        return (Normalize-ScenarioName -Value ([string]$request.scenario))
    }
    catch {
        Write-EventLog -Level 'WARN' -Event 'scenario_request_read_failed' -Message $_.Exception.Message
        return $null
    }
}

function Write-StatusFile {
    param([string]$Path)

    $pendingExists = Test-Path $script:ScenarioRequestPath
    $pendingFile = $null
    if ($pendingExists) {
        try {
            $pendingFile = Get-Content -Path $script:ScenarioRequestPath -Raw | ConvertFrom-Json
        }
        catch {
            $pendingFile = $null
        }
    }

    $payload = [PSCustomObject]@{
        ts_local = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        active_scenario = $script:ActiveScenario
        pending_scenario = $script:PendingScenario
        current_slot = $script:CurrentSlotKey
        current_target_w = $script:CurrentWholeTarget
        constant_target_w = $script:ConstantTargetW
        scenario_request_path = $script:ScenarioRequestPath
        scenario_request_file_present = $pendingExists
        scenario_request_file = $pendingFile
    }

    Write-JsonFile -Path $Path -Payload $payload
}

function Update-PendingScenario {
    param([string]$RequestPath)
    $requested = Get-RequestedScenarioFromFile -Path $RequestPath
    if ($null -eq $requested) { return }

    if ($requested -ne $script:ActiveScenario -and $requested -ne $script:PendingScenario) {
        $script:PendingScenario = $requested
        Write-EventLog -Level 'INFO' -Event 'scenario_requested' -Message "pending_scenario=$requested; effective_next_slot=true"
        Write-ConsoleLoadChange -Message "Scenario request accepted: $requested. It will activate at the next 15-minute boundary."
    }
}

function Update-PlanIfBoundaryChanged {
    param(
        [datetime]$Now,
        [object]$Config,
        [int]$ProfileStepMinutes
    )

    $slotKey = Get-SlotKey -Timestamp $Now -StepMinutes $ProfileStepMinutes
    if ($script:CurrentPlan -ne $null -and $script:CurrentSlotKey -eq $slotKey) {
        return
    }

    if ($script:PendingScenario -and $script:PendingScenario -ne $script:ActiveScenario) {
        $oldScenario = $script:ActiveScenario
        $script:ActiveScenario = $script:PendingScenario
        $script:PendingScenario = $null
        Write-EventLog -Level 'INFO' -Event 'scenario_activated' -Message "old=$oldScenario; new=$($script:ActiveScenario); slot=$slotKey"
    }

    $plan = Get-ScenarioPlan -Config $Config -Now $Now -Scenario $script:ActiveScenario -ConstantTargetW $script:ConstantTargetW

    $script:CurrentSlotKey = $slotKey
    $script:CurrentPlan = $plan

    $statesSummary = @()
    foreach ($strip in $Config.strips) {
        $stripPlan = $plan.by_strip[$strip.name]
        $statesSummary += ("{0}=[{1}]" -f $strip.name, (($stripPlan.states | ForEach-Object { if ($_){1}else{0} }) -join ','))
        Write-EventLog -Level 'INFO' -Event 'strip_plan' -StripName $strip.name -DeviceId $strip.device_id -Message ("slot={0}; scenario={1}; target_strip_w={2}; states=[{3}]" -f $slotKey, $script:ActiveScenario, ([Math]::Round([double]$stripPlan.target_strip_w,2)), (($stripPlan.states | ForEach-Object { if ($_){1}else{0} }) -join ','))
    }

    $message = "SCENARIO=$($script:ActiveScenario) slot=$slotKey target=$([Math]::Round([double]$script:CurrentWholeTarget,2))W nominal=$([Math]::Round([double]$plan.applied_total_w,2))W overshoot=$([Math]::Round([double]$plan.overshoot_w,2))W states: $($statesSummary -join '; ')"
    Write-ConsoleLoadChange -Message $message
    Write-EventLog -Level 'INFO' -Event 'load_change' -Message $message
}

$resolvedScenario = Resolve-RequestedScenario
$scenarioCommandRequested = $SetScenario -or $SetScenarioAllOn -or $SetScenarioWholeHouse -or $SetScenarioConstant1kW -or $SetScenarioAdaptive

if ($ClearScenarioRequest) {
    if (Test-Path $ScenarioRequestPath) {
        Remove-Item -Path $ScenarioRequestPath -Force
        Write-Host 'Pending scenario request cleared.'
    }
    else {
        Write-Host 'No pending scenario request file found.'
    }
    exit 0
}

if ($scenarioCommandRequested) {
    Write-ScenarioRequestFile -Path $ScenarioRequestPath -ScenarioName $resolvedScenario -ConstantTargetW $ConstantTargetW
    $nextBoundary = Get-Next15MinuteBoundary -Now (Get-Date)
    Write-Host ("Scenario request written: {0}. It will be applied at the next 15-minute boundary ({1})." -f $resolvedScenario, $nextBoundary.ToString('yyyy-MM-dd HH:mm:ss'))
    exit 0
}

if ($ShowScenario) {
    if (Test-Path $ScenarioRequestPath) {
        Get-Content -Path $ScenarioRequestPath
    }
    else {
        Write-Host 'No pending scenario request file found.'
    }
    exit 0
}

$config = Load-Config -Path $ConfigPath

if (-not $config.server_uri) { throw 'Config must contain server_uri.' }
if (-not $config.auth_key) { throw 'Config must contain auth_key.' }
if (-not $config.strips -or $config.strips.Count -ne 3) { throw 'The config must contain exactly 3 strips.' }
foreach ($strip in $config.strips) {
    if (-not $strip.device_id) { throw "Strip '$($strip.name)' must contain device_id." }
    if ($strip.loads_w.Count -ne 4) { throw "Strip '$($strip.name)' must define exactly 4 outlet loads in loads_w." }
}

$cycleIntervalSeconds = if ($config.poll_interval_seconds) { [int]$config.poll_interval_seconds } else { 60 }
if ($cycleIntervalSeconds -lt 10) { throw 'poll_interval_seconds must be at least 10.' }
$profileStepMinutes = if ($config.profile_step_minutes) { [int]$config.profile_step_minutes } else { 15 }
if ($profileStepMinutes -ne 15) { throw 'profile_step_minutes must be 15 for this version.' }
$minGapMs = if ($config.min_gap_ms) { [int]$config.min_gap_ms } else { 1200 }
$delayBetweenStripsMs = if ($config.delay_between_strips_ms) { [int]$config.delay_between_strips_ms } else { 1500 }
$script:LogPath = if ($config.event_log_path) { [string]$config.event_log_path } else { '.\\shelly_reconnect_events.tsv' }

if ($config.PSObject.Properties.Name -contains 'scenario_request_path' -and $config.scenario_request_path) {
    $script:ScenarioRequestPath = [string]$config.scenario_request_path
}
if ($config.PSObject.Properties.Name -contains 'scenario_status_path' -and $config.scenario_status_path) {
    $script:StatusPath = [string]$config.scenario_status_path
}
if ($config.PSObject.Properties.Name -contains 'constant_target_w' -and $config.constant_target_w -and -not $PSBoundParameters.ContainsKey('ConstantTargetW')) {
    $script:ConstantTargetW = [double]$config.constant_target_w
}

$script:ActiveScenario = $resolvedScenario
Ensure-EventLogFile -Path $script:LogPath
Write-EventLog -Level 'INFO' -Event 'startup' -Message "Loaded config from $ConfigPath; startup_scenario=$($script:ActiveScenario); scenario_request_path=$($script:ScenarioRequestPath); scenario_status_path=$($script:StatusPath); constant_target_w=$($script:ConstantTargetW)"
Write-ConsoleLoadChange -Message "Starting controller with scenario '$($script:ActiveScenario)'."
Write-StatusFile -Path $script:StatusPath

if ($ShowStatus) {
    Get-Content -Path $script:StatusPath
    exit 0
}

while ($true) {
    $cycleStarted = Get-Date
    $nextCycleStart = Get-NextCycleStart -Now $cycleStarted -IntervalSeconds $cycleIntervalSeconds

    try {
        Update-PendingScenario -RequestPath $script:ScenarioRequestPath
        Update-PlanIfBoundaryChanged -Now $cycleStarted -Config $config -ProfileStepMinutes $profileStepMinutes

        foreach ($strip in $config.strips) {
            $stripPlan = $script:CurrentPlan.by_strip[$strip.name]
            Sync-StripToDesiredState -ServerUri $config.server_uri -AuthKey $config.auth_key -Strip $strip -DesiredStates $stripPlan.states -MinGapMs $minGapMs
            Start-Sleep -Milliseconds $delayBetweenStripsMs
        }

        Write-StatusFile -Path $script:StatusPath
    }
    catch {
        Write-EventLog -Level 'ERROR' -Event 'cycle_error' -Message $_.Exception.Message
        Write-StatusFile -Path $script:StatusPath
    }

    Update-DashboardValues -Path $DashboardFile -SectionName 'scenario' -SectionValues @{
                        source_ts_local = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        active_scenario = $script:ActiveScenario
                        current_target_w = [math]::Round($script:CurrentWholeTarget, 2)
                        ts_local = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }


    if ($RunOnce) { break }

    $sleepSeconds = ($nextCycleStart - (Get-Date)).TotalSeconds
    if ($sleepSeconds -gt 0) {
        Start-Sleep -Milliseconds ([int]([Math]::Round($sleepSeconds * 1000)))
    }
}
