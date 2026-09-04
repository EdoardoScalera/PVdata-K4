param(
    [string]$ConfigPath = $(Join-Path $PSScriptRoot "folder-mappings.json"),
    [int]$IntervalMinutes = 15,
    [switch]$ManifestOnly
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found: $ConfigPath"
    exit 1
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$RepoDir        = $config.RepoDir
$Branch         = $config.Branch
$LogFile        = $config.LogFile
$CommitName     = $config.CommitName
$CommitEmail    = $config.CommitEmail
$FolderMappings = $config.FolderMappings

$LogDir = Split-Path $LogFile -Parent
if (-not [string]::IsNullOrWhiteSpace($LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$LockFile = Join-Path $PSScriptRoot "Upload-PVData.lock"
$PushErrorLog = Join-Path $LogDir "push_errors.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "[$timestamp] $Message"
}

function Remove-LockFile {
    if (Test-Path $LockFile) {
        try {
            Remove-Item $LockFile -Force -ErrorAction Stop
        }
        catch {
        }
    }
}

function Test-AndCreateLock {
    if (Test-Path $LockFile) {
        try {
            $existingPidText = Get-Content $LockFile -Raw -ErrorAction Stop
            $existingPid = 0
            [void][int]::TryParse($existingPidText.Trim(), [ref]$existingPid)

            if ($existingPid -gt 0) {
                $existingProcess = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
                if ($existingProcess) {
                    Write-Log "Another instance is already running with PID $existingPid. Exiting."
                    exit 0
                }
                else {
                    Write-Log "Stale lock file found for PID $existingPid. Replacing lock."
                    Remove-LockFile
                }
            }
            else {
                Write-Log "Lock file exists but PID is invalid. Replacing lock."
                Remove-LockFile
            }
        }
        catch {
            Write-Log "Could not read existing lock file. Replacing lock."
            Remove-LockFile
        }
    }

    Set-Content -Path $LockFile -Value $PID -Encoding ascii
    Write-Log "Lock acquired with PID $PID"
}

function Invoke-Git {
    param(
        [string]$Arguments,
        [switch]$IgnoreExitCode
    )

    $output = & git $Arguments.Split(' ') 2>&1
    $exitCode = $LASTEXITCODE

    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        throw "git $Arguments failed with exit code $exitCode. Output: $output"
    }

    return @{
        Output   = $output
        ExitCode = $exitCode
    }
}

function New-DataFileManifest {
    $manifestPaths = @((Join-Path $RepoDir "Dashboard\data-file-manifest.json"))
    $dashboardMapping = $FolderMappings | Where-Object { $_.Target -eq 'Dashboard' } | Select-Object -First 1
    if ($dashboardMapping -and (Test-Path $dashboardMapping.Source)) {
        $manifestPaths += Join-Path $dashboardMapping.Source "data-file-manifest.json"
    }
    $entries = @()
    $metadataPattern = '^.+_tilt(?<tilt>\d+)_distance(?<distance>\d+)_(?<scenario>.+)\.(?<extension>txt|csv|tsv)$'

    foreach ($map in $FolderMappings) {
        $targetRoot = Join-Path $RepoDir $map.Target
        if (-not (Test-Path $targetRoot)) { continue }

        $files = Get-ChildItem -Path $targetRoot -File -Recurse | Where-Object {
            $_.Extension -in @('.txt', '.csv', '.tsv') -and $_.FullName -notlike "$(Join-Path $RepoDir 'Dashboard')\*"
        }

        foreach ($file in $files) {
            $relativePath = $file.FullName.Substring($RepoDir.Length).TrimStart('\', '/')
            $relativePath = $relativePath.Replace('\', '/')
            $manifestPathValue = "../$relativePath"
            $key = $relativePath
            $type = $map.Target.ToLowerInvariant()
            $tilt = $null
            $distance = $null
            $scenario = $null
            $constantTarget = $null
            $match = [regex]::Match($file.Name, $metadataPattern)
            if ($match.Success) {
                $tilt = [int]$match.Groups['tilt'].Value
                $distance = [int]$match.Groups['distance'].Value
                $scenario = $match.Groups['scenario'].Value
                if ($scenario -match '^constant_(?<target>\d+)W$') {
                    $constantTarget = [int]$Matches['target']
                    $scenario = 'constant'
                }
                elseif ($scenario -eq 'constant_1kw') {
                    $scenario = 'constant'
                }
            }

            $entries += [PSCustomObject]@{
                key = $key
                path = $manifestPathValue
                name = $file.Name
                label = $file.Name
                type = $type
                tilt = $tilt
                distance = $distance
                scenario = $scenario
                constant_target_w = $constantTarget
            }
        }
    }

    $manifest = [PSCustomObject]@{
        generated_at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        files = @($entries | Sort-Object key)
    }
    $manifestJson = $manifest | ConvertTo-Json -Depth 6
    foreach ($manifestPath in $manifestPaths | Select-Object -Unique) {
        $manifestJson | Set-Content -Path $manifestPath -Encoding utf8
        Write-Log "Generated data file manifest with $($entries.Count) files: $manifestPath"
    }
}

# Records the timestamp of the push that is about to commit the dashboard, so
# index.html can show "date of the last push commit". Written into the repo
# copy of dashboard_values.json before git add / commit, so it is carried by
# and consistent with the very push that publishes it.
function Set-DashboardLastPush {
    $dashboardPath = Join-Path $RepoDir "Dashboard/dashboard_values.json"
    if (-not (Test-Path -LiteralPath $dashboardPath)) {
        Write-Log "Dashboard values file not found, skipping last-push stamp: $dashboardPath"
        return
    }

    # Read existing sections so they are preserved when rewritten. In this
    # repo the file is primed with the current structure already.
    $existing = @{}
    try {
        $raw = Get-Content -LiteralPath $dashboardPath -Raw -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $parsed) {
                foreach ($prop in $parsed.PSObject.Properties) {
                    $existing[$prop.Name] = $prop.Value
                }
            }
        }
    }
    catch {
        Write-Log "Could not parse existing dashboard_values.json: $($_.Exception.Message)"
    }

    $existing['last_push_ts'] = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

    $json = [PSCustomObject]$existing | ConvertTo-Json -Depth 20
    try {
        [System.IO.File]::WriteAllText($dashboardPath, $json, [System.Text.UTF8Encoding]::new($false))
        Write-Log "Stamped last_push_ts into dashboard_values.json"
    }
    catch {
        Write-Log "Failed to stamp last_push_ts: $($_.Exception.Message)"
    }
}

function Invoke-SyncCycle {
    Write-Log "Starting sync cycle"

    if (-not (Test-Path (Join-Path $RepoDir ".git"))) {
        Write-Log "Repo folder is not a git repository: $RepoDir"
        return
    }

    Set-Location $RepoDir

    & git config user.name "$CommitName"
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Failed to set git user.name"
        return
    }

    & git config user.email "$CommitEmail"
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Failed to set git user.email"
        return
    }

    foreach ($Map in $FolderMappings) {
        $SourceDir = $Map.Source
        $TargetDir = Join-Path $RepoDir $Map.Target

        if (-not (Test-Path $SourceDir)) {
            Write-Log "Source folder not found, skipping: $SourceDir"
            continue
        }

        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
        Write-Log "Syncing $SourceDir -> $TargetDir"

        robocopy "$SourceDir" "$TargetDir" /MIR /R:2 /W:2 /XD ".git" | Out-Null
        $rc = $LASTEXITCODE
        Write-Log "robocopy exit code for $SourceDir : $rc"

        # robocopy exit codes >= 8 indicate copy failures (e.g. a data file is
        # held open/locked by an active logger while the load is disconnected).
        # Do NOT abort the whole sync cycle - log it as a warning and keep
        # going, so the GitHub commit/push still runs every cycle regardless of
        # a single folder failing to copy.
        if ($rc -ge 8) {
            Write-Log "robocopy reported failure for: $SourceDir (continuing so the push still runs)"
        }
    }

    Set-DashboardLastPush

    New-DataFileManifest

    & git add -A
    if ($LASTEXITCODE -ne 0) {
        Write-Log "git add failed"
        return
    }

    & git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Log "No changes to commit"
        return
    }

    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $commitMessage = "Auto-sync $stamp"

    & git commit -m "$commitMessage" 2>&1 | ForEach-Object { Write-Log $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "git commit failed"
        return
    }

    Write-Log "Running first push: git -c gc.auto=0 push origin $Branch"
    $firstPush = & git -c gc.auto=0 push origin $Branch 2>&1
    $firstPushExit = $LASTEXITCODE
    if ($firstPush) {
        $firstPush | ForEach-Object { Write-Log $_ }
    }

    if ($firstPushExit -ne 0) {
        Write-Log "First push failed with exit code $firstPushExit"
    }
    else {
        Write-Log "First push completed successfully"
    }

    Write-Log "Running second push: git push origin main"
    $secondPush = & git push origin main 2>&1
    $secondPushExit = $LASTEXITCODE
    if ($secondPush) {
        $secondPush | ForEach-Object { Write-Log $_ }
    }

    if ($secondPushExit -ne 0) {
        Add-Content -Path $PushErrorLog -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') SECOND PUSH FAILED: $secondPush"
        Write-Log "Second push failed with exit code $secondPushExit"
        return
    }

    Write-Log "Sync complete"
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] UPLOAD TO GITHUB SUCCESSFUL!" -ForegroundColor Green
}

if ($ManifestOnly) {
    New-DataFileManifest
    exit 0
}

Test-AndCreateLock

try {
    Write-Log "Starting config-driven multi-folder sync loop"
    Write-Log "Using config: $ConfigPath"
    Write-Log "RepoDir: $RepoDir"
    Write-Log "Branch: $Branch"
    Write-Log "Loop interval: $IntervalMinutes minutes"

    while ($true) {
        try {
            Invoke-SyncCycle
        }
        catch {
            Write-Log "Unhandled cycle error: $($_.Exception.Message)"
        }

        Write-Log "Sleeping for $IntervalMinutes minutes"
        Start-Sleep -Seconds ($IntervalMinutes * 60)
    }
}
finally {
    Write-Log "Script stopping, removing lock"
    Remove-LockFile
}