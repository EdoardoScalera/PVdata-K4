param(
    [string]$SourceFolder      = "C:\PVData\Incoming",
    [string]$GitRepoPath       = "C:\Git\pv-data-repo",
    [string]$RepoSubFolder     = "data",
    [string]$CombinedFileName  = "pv_1min_combined.txt",
    [int]$LookbackMinutes      = 15,
    [string]$GitBranch         = "main",
    [switch]$GitUpload = $true
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $SourceFolder)) {
    throw "Source folder not found: $SourceFolder"
}

if (-not (Test-Path $GitRepoPath)) {
    throw "Git repository path not found: $GitRepoPath"
}

Push-Location $GitRepoPath
try {
    git checkout $GitBranch | Out-Null
    git pull origin $GitBranch --rebase

    $repoOutputFolder = Join-Path $GitRepoPath $RepoSubFolder
    if (-not (Test-Path $repoOutputFolder)) {
        New-Item -Path $repoOutputFolder -ItemType Directory -Force | Out-Null
    }

    $repoCombinedFile = Join-Path $repoOutputFolder $CombinedFileName
    if (-not (Test-Path $repoCombinedFile)) {
        New-Item -Path $repoCombinedFile -ItemType File -Force | Out-Null
    }

    $cutoffTime = (Get-Date).AddMinutes(-$LookbackMinutes)

    $recentFiles = Get-ChildItem -Path $SourceFolder -Filter "*.txt" -File |
        Where-Object { $_.LastWriteTime -ge $cutoffTime } |
        Sort-Object LastWriteTime, Name

    if (-not $recentFiles) {
        Write-Host "No recent TXT files found in the last $LookbackMinutes minutes."
        exit 0
    }

    $existingLines = @{}
    Get-Content -Path $repoCombinedFile | ForEach-Object {
        $line = $_.Trim()
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $existingLines[$line] = $true
        }
    }

    $newLines = New-Object System.Collections.Generic.List[string]

    foreach ($file in $recentFiles) {
        $lines = Get-Content -Path $file.FullName

        if ($lines.Count -ge 2) {
            $secondLine = $lines[1].Trim()

            if (-not [string]::IsNullOrWhiteSpace($secondLine)) {
                if (-not $existingLines.ContainsKey($secondLine)) {
                    $newLines.Add($secondLine)
                    $existingLines[$secondLine] = $true
                }
            }
        }
    }

    if ($newLines.Count -gt 0) {
        Add-Content -Path $repoCombinedFile -Value $newLines
        Write-Host "Appended $($newLines.Count) new line(s) directly to repo file: $repoCombinedFile"
    }
    else {
        Write-Host "No new lines to append."
    }

    if ($GitUpload) {
        git add -- $repoCombinedFile

        $hasChanges = git status --porcelain
        if ($hasChanges) {
            $commitMessage = "Auto-update PV 1-min combined data $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            git commit -m $commitMessage
            git push origin $GitBranch
            Write-Host "Changes pushed to GitHub."
        }
        else {
            Write-Host "No git changes detected."
        }
    }
}
finally {
    Pop-Location
}
