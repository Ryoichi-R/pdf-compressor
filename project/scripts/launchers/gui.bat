@echo off
setlocal DisableDelayedExpansion
REM NOTE: Japanese text must NOT appear in .bat files (cmd.exe UTF-8 bug).
REM DisableDelayedExpansion: input paths containing '!' (legal in NTFS) would
REM otherwise be silently truncated; mirrors compress.bat:2 policy.
for %%I in ("%~dp0..\..") do set "TOOLDIR=%%~fI\"
where pwsh >nul 2>&1
if errorlevel 1 (
    echo [ERROR] PowerShell 7+ ^(pwsh.exe^) is required.
    echo Install: winget install --id Microsoft.PowerShell
    pause
    exit /b 2
)
start "" /min pwsh -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%TOOLDIR%_internal\gui.ps1"
endlocal
exit /b 0
