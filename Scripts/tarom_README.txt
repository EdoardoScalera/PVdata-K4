
Tarom MPPT 6000-M Logger
========================

This package contains:

- tarom_logger.ps1  : PowerShell script to log data from the Tarom MPPT 6000-M controller.

Requirements
------------
- Windows with PowerShell.
- FTDI VCP driver installed and the Tarom cable visible as COM3.
- Tarom UART/RS-232 interface enabled in the device menu.

Installation
------------
1. Unzip this folder.
2. Move `tarom_logger.ps1` to your desired scripts folder, e.g.:
   C:\Users\5CG7471GSJ\DATA\Scripts

Usage
-----
1. Make sure your log directory exists or let the script create it:
   C:\Users\5CG7471GSJ\DATA\PV

2. Open PowerShell and (once) allow local scripts if needed:

   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

3. Run the logger:

   cd C:\Users\5CG7471GSJ\DATA\Scripts
   .\tarom_logger.ps1

4. The script will:
   - Open serial port COM3 at 4800 baud, 8-N-1.
   - Read one line from the Tarom every minute.
   - Append each line to:
     C:\Users\5CG7471GSJ\DATA\PV\tarom_log.csv
     in the format:
     pc_timestamp;tarom_line

5. Stop logging with Ctrl+C in the PowerShell window.

Git Integration
---------------
- The script opens the log file only briefly for each appended line.
- This allows Git or other tools to read and commit the file between writes.

