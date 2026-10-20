@echo off
setlocal
REM === pdf-compressor dependency installer ===
REM NOTE: Japanese text must NOT appear in .bat files (cmd.exe UTF-8 bug).
REM Installs Ghostscript, qpdf, and Poppler via winget, with manual fallback URLs.

for %%I in ("%~dp0..\..") do set "TOOLDIR=%%~fI\"
where pwsh >nul 2>&1
if errorlevel 1 (
    echo [ERROR] PowerShell 7+ ^(pwsh.exe^) is required for setup.
    echo Manual install: https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows
    exit /b 2
)

pwsh -NoProfile -ExecutionPolicy Bypass -File "%TOOLDIR%_internal\setup-dependencies.ps1"
set "RC=%ERRORLEVEL%"

if "%RC%"=="0" (
    echo.
    echo [OK] Dependencies ready.
) else (
    echo.
    echo [ERROR] Setup failed with code %RC%.
)

echo.
echo Press any key to close...
pause >nul
exit /b %RC%
