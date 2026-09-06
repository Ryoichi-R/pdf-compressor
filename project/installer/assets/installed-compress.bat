@echo off
setlocal DisableDelayedExpansion
set "INSTALL_ROOT=%~dp0"
set "PWSH=%INSTALL_ROOT%runtime\pwsh\pwsh.exe"
if not exist "%PWSH%" (
    echo [ERROR] Bundled PowerShell is missing.
    exit /b 2
)
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_ROOT%_internal\installed-cli.ps1" -- %*
exit /b %ERRORLEVEL%
