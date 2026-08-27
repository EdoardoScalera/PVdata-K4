# PV Data Auto-Combine and GitHub Upload

This package contains a PowerShell script that:
- reads `.txt` files from an input folder,
- ignores the header by extracting only the second line from each file,
- processes only files updated within the last 15 minutes,
- prevents duplicate lines from being appended,
- appends new lines directly to the target file inside your cloned Git repository,
- optionally commits and pushes the updated file to GitHub.

## Files in this package

- `Combine-PVData.ps1` — main automation script
- `README.md` — setup and implementation guide

## Expected workflow

1. Your 1-minute TXT files are created in a source folder.
2. The script checks only the files modified in the last 15 minutes.
3. It reads line 2 from each file.
4. It appends only new lines to the combined file in the cloned repo.
5. It runs `git add`, `git commit`, and `git push`.

## Folder example

```text
C:\PVData\Incoming              -> incoming TXT files
C:\Git\pv-data-repo             -> cloned GitHub repository
C:\Git\pv-data-repo\data       -> target subfolder inside repo
```

## Default parameters

```powershell
SourceFolder     = C:\PVData\Incoming
GitRepoPath      = C:\Git\pv-data-repo
RepoSubFolder    = data
CombinedFileName = pv_1min_combined.txt
LookbackMinutes  = 15
GitBranch        = main
GitUpload        = $true
```

## Example run

```powershell
.\Combine-PVData.ps1 `
  -SourceFolder "C:\PVData\Incoming" `
  -GitRepoPath "C:\Git\pv-data-repo" `
  -RepoSubFolder "data" `
  -CombinedFileName "pv_1min_combined.txt" `
  -LookbackMinutes 15 `
  -GitBranch "main" `
  -GitUpload
```

## Step-by-step implementation

1. Clone your GitHub repository locally.
2. Create the destination folder inside the repo if needed, for example `data`.
3. Copy `Combine-PVData.ps1` to your automation machine.
4. Edit the default paths in the script or pass them as parameters.
5. Open PowerShell and test the script manually.
6. Verify that the combined file is updated inside the cloned repo.
7. Verify that the commit and push succeed.
8. Add the script to your existing automation flow or Windows Task Scheduler.

## Task Scheduler example

- Program/script: `powershell.exe`
- Add arguments:

```text
-ExecutionPolicy Bypass -File "C:\Scripts\Combine-PVData.ps1" -SourceFolder "C:\PVData\Incoming" -GitRepoPath "C:\Git\pv-data-repo" -RepoSubFolder "data" -CombinedFileName "pv_1min_combined.txt" -LookbackMinutes 15 -GitBranch "main" -GitUpload
```

## Notes

- The script uses `LastWriteTime` for the 15-minute filter.
- Duplicate prevention is based on the full text of the second line.
- If a TXT file has fewer than 2 lines, it is skipped.
- If no new files are found, the script exits cleanly.
- If no content changes are detected, no commit is created.

## Recommended checks before production

1. Confirm Git is installed and available in PATH.
2. Confirm the local repo can push without interactive credential issues.
3. Confirm your TXT files always contain the data row on line 2.
4. Confirm line formatting is stable so duplicate detection works reliably.
5. Run the script for a day in test mode before full deployment.

## Optional future improvements

- Archive processed source files.
- Log all actions to a timestamped log file.
- Detect duplicates using a timestamp field instead of the full line.
- Add retry logic for transient Git push failures.
