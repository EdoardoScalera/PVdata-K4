param(
    [string]$ConfigPath = $(Join-Path $PSScriptRoot "folder-mappings.json")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found: $ConfigPath"
    exit 1
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$RepoDir     = $config.RepoDir
$Branch      = $config.Branch
$LogFile     = $config.LogFile
$CommitName  = $config.CommitName
$CommitEmail = $config.CommitEmail
$FolderMappings = $config.FolderMappings

New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "[$timestamp] $Message"
}

Write-Log "Starting config-driven multi-folder sync"
Write-Log "Using config: $ConfigPath"

if (-not (Test-Path (Join-Path $RepoDir ".git"))) {
    Write-Log "Repo folder is not a git repository: $RepoDir"
    exit 1
}

Set-Location $RepoDir

git config user.name "$CommitName"
git config user.email "$CommitEmail"

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
    Write-Log "robocopy exit code: $rc"
    if ($rc -ge 8) {
        Write-Log "robocopy reported failure for: $SourceDir"
        exit 1
    }
}

git add -A

git diff --cached --quiet
if ($LASTEXITCODE -eq 0) {
    Write-Log "No changes to commit"
    exit 0
}

$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
git commit -m "Auto-sync $stamp"
git -c gc.auto=0 push origin $Branch

Write-Log "Sync complete"

$result = git push origin main 2>&1
if ($LASTEXITCODE -ne 0) {
    Add-Content "C:\\Users\\5CG7471GSJ\\Documents\\DATA\\Scripts\\push_errors.log" "$(Get-Date): $result"
}