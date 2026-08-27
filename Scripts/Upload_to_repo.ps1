param(
    [string]$ConfigPath = $(Join-Path $PSScriptRoot "folder-mappings.json"),
    [int]$IntervalMinutes = 15
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

        if ($rc -ge 8) {
            Write-Log "robocopy reported failure for: $SourceDir"
            return
        }
    }

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