# PVdata-K4 config-driven multi-folder setup

This package uploads multiple local folders into one GitHub repository while keeping them separated in different subfolders inside the repo.

## Included files

- `Upload-PVData.ps1` - reads settings from `folder-mappings.json` and syncs all configured folders.
- `folder-mappings.json` - simple config file for repo path, log path, identity, and folder mappings.
- `cleanup-test-files.ps1` - removes test files from the repository and from the cloned repo working tree.
- `setup.bat` - runs the sync script once for testing.
- `README.md` - this guide.

## Before you run

### 1. Install Git for Windows

1. Download Git for Windows from [git-scm.com/download/win](https://git-scm.com/download/win).
2. Run the installer.
3. Keep the defaults unless noted otherwise.
4. On the **PATH** screen, choose **Git from the command line and also from 3rd-party software** so `git` works in PowerShell and Command Prompt.
5. On the **extra options** screen, make sure **Enable Git Credential Manager** is checked.
6. Finish the installation and verify it in PowerShell:

```powershell
git --version
```

### 2. Set up SSH access to GitHub

Generate a new SSH key:

```powershell
ssh-keygen -t ed25519 -C "your-email@example.com"
```

When prompted for the file location, press **Enter** to use the default path in `C:\Users\YOUR_USER\.ssh\id_ed25519`.

Then start the SSH agent and add the key:

```powershell
Get-Service -Name ssh-agent | Set-Service -StartupType Manual
Start-Service ssh-agent
ssh-add $env:USERPROFILE\.ssh\id_ed25519
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub | Set-Clipboard
```
The ssh key will be copied to the clipboard. Run the code without "| Set-Clipboard" for it to be displyed

Open <https://github.com/settings/keys>, click **New SSH key**, paste the copied public key, and save it.

Test the connection:

```powershell
ssh -T git@github.com
```

A successful setup returns a message similar to:

```text
Hi USERNAME! You've successfully authenticated, but GitHub does not provide shell access.
```

### 3. Clone the repository with SSH

Choose the local folder where you want the GitHub repository clone to live, then run:

```powershell
git clone git@github.com:EdoardoScalera/PVdata-K4.git "C:\path\to\your\repo\PVdata-K4"
```

Move into the cloned repository and verify the remote:

```powershell
cd "C:\path\to\your\repo\PVdata-K4"
git remote -v
```

If the remote shows `https://` instead of `git@github.com:...`, switch it to SSH:

```powershell
git remote set-url origin git@github.com:EdoardoScalera/PVdata-K4.git
git remote -v
```

## What to edit

Edit only `folder-mappings.json`.

### Global settings

- `RepoDir`: local path of the cloned repository.
- `Branch`: normally `main`.
- `LogFile`: where the log file will be written. Use a normal local folder such as `C:\Scripts\Upload-PVData.log`, not a OneDrive path, to reduce Task Scheduler issues.
- `CommitName`: git commit author name.
- `CommitEmail`: git commit author email.

### Folder mappings

Each object in `FolderMappings` has:

- `Source`: local source folder.
- `Target`: destination subfolder name inside the repository.

Example:

```json
{
  "Source": "D:\\Exports\\WeatherStation",
  "Target": "Weather-Station"
}
```

## How to add a fourth or fifth folder

Add another object to the `FolderMappings` array.

Example fourth folder:

```json
,
{
  "Source": "C:\\Users\\YOUR_USER\\Data\\PVdata-K4-D",
  "Target": "Dataset-D"
}
```

Example fifth folder:

```json
,
{
  "Source": "D:\\Exports\\WeatherStation",
  "Target": "Weather-Station"
}
```

Rules:

- Every `Target` must be unique.
- Every `Source` must point to an existing local folder.
- Keep valid JSON syntax, including commas between objects.

## First test

1. Extract this package to a folder on the target machine.
2. Edit `folder-mappings.json` with the correct paths for that machine.
3. Run the helper:

```powershell
.\setup.bat
```

Or run the script directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Upload-PVData.ps1"
```

Then inspect the log file path defined in `folder-mappings.json`.

## Scheduled task

### Important recommendation

Store `Upload-PVData.ps1` in a normal local folder such as `C:\Scripts\Upload-PVData.ps1` instead of OneDrive when using Task Scheduler. A wrong task action or a OneDrive-only file can trigger an “open with” popup instead of running PowerShell.

### Create a Task Scheduler folder

Run in **Admin PowerShell**:

```powershell
$schedule = New-Object -ComObject "Schedule.Service"
$schedule.Connect()
$root = $schedule.GetFolder("\\")
try {
    $root.CreateFolder("PVdata") | Out-Null
} catch {
    Write-Host "Folder may already exist: \\PVdata"
}
```

### Register the scheduled task in `\PVdata\`

Update the script path below so it points to your real local script path.

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"C:\Scripts\Upload-PVData.ps1`""
$tempTrigger = New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 1)
$trigger = New-ScheduledTaskTrigger -Daily -At "00:00"
$trigger.Repetition = $tempTrigger.Repetition
Register-ScheduledTask -TaskName "Upload PVdata to GitHub" -TaskPath "\PVdata\" -Action $action -Trigger $trigger -Description "Sync local PV data folders to GitHub every 15 minutes"
```

### Verify the task

```powershell
Get-ScheduledTask -TaskPath "\PVdata\" | Format-Table TaskName,TaskPath,State
```

### Delete the task later if needed

```powershell
Unregister-ScheduledTask -TaskName "Upload PVdata to GitHub" -TaskPath "\PVdata\" -Confirm:$false
```

If you also want to remove the `\PVdata\` Task Scheduler folder:

```powershell
$schedule = New-Object -ComObject "Schedule.Service"
$schedule.Connect()
$root = $schedule.GetFolder("\\")
$root.DeleteFolder("PVdata", $null)
```

## Clean test files from GitHub and the cloned repo

If you used a secondary machine for testing and pushed test files into the final repository, you can remove them from GitHub **and** from the cloned repo working tree using `cleanup-test-files.ps1`.

Example:

```powershell
powershell -ExecutionPolicy Bypass -File ".\cleanup-test-files.ps1" -RepoDir "C:\path\to\your\repo\PVdata-K4" -RelativePath "test-files"
```

This runs the equivalent of:

```powershell
cd "C:\path\to\your\repo\PVdata-K4"
git rm -r "test-files"
git commit -m "Remove test files from repo and clone"
git push origin main
```

Important note:

- This removes the files from GitHub and from the cloned repo working tree.
- If the same files still exist inside a mapped source folder, the next sync will add them back.
- To prevent that, either remove those files from the source folder or keep them outside the mapped source folders.

## Control strategy

This workflow is designed so the script fully controls the configured repository subfolders.
Do not manually edit managed folders inside the clone.
Edit the source folders and rerun the sync instead.

## Notes

- The script uses `robocopy /MIR`, so deletions in a source folder are also applied to that folder's target inside the repository.
- Each mapping is mirrored separately, so one source folder does not overwrite another target folder.
- On a new machine, the main thing to update is `folder-mappings.json`.


## TROUBLESHOOTING GITHUB FAIL COMMIT
- move to cloned repo: cd "C:\Users\5CG7471GSJ\Documents\PVdata-K4"
- check repo status: git status
- clean the cache: git gc
- add changes to staged area: git add -A
- commit new changes is any: git commit -m "Auto-sync"
- manual push commit: git push origin main