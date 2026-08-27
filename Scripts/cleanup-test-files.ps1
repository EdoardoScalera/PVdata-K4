param(
    [Parameter(Mandatory=$true)]
    [string]$RepoDir,

    [Parameter(Mandatory=$true)]
    [string]$RelativePath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path (Join-Path $RepoDir ".git"))) {
    Write-Error "Repo folder is not a git repository: $RepoDir"
    exit 1
}

Set-Location $RepoDir

git rm -r --ignore-unmatch "$RelativePath"
git commit -m "Remove test files from repo and clone"
git push origin main
