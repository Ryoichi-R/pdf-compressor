@echo off
setlocal DisableDelayedExpansion
set "PACKAGE_ROOT=%~dp0"
set "INSTALLER=%PACKAGE_ROOT%project\installer\Install-PdfCompressor.ps1"
set "MANIFEST=%PACKAGE_ROOT%project\installer\payload\payload-manifest.json"

if not "%~2"=="" (
    echo [ERROR] Only one optional install parent path is accepted.
    pause
    exit /b 2
)
if not exist "%INSTALLER%" (
    echo [ERROR] Installer is missing.
    pause
    exit /b 3
)
if not exist "%MANIFEST%" (
    echo [ERROR] Payload is not built yet.
    pause
    exit /b 3
)

set "NATIVE_ARCH=%PROCESSOR_ARCHITECTURE%"
if defined PROCESSOR_ARCHITEW6432 set "NATIVE_ARCH=%PROCESSOR_ARCHITEW6432%"
if /i "%NATIVE_ARCH%"=="AMD64" (
    set "PDF_COMPRESSOR_RUNTIME=win-x64"
) else if /i "%NATIVE_ARCH%"=="ARM64" (
    rem No native win-arm64 payload exists in this profile. Windows on ARM
    rem installs the verified win-x64 payload under x64 emulation.
    set "PDF_COMPRESSOR_RUNTIME=win-x64"
    echo [INFO] ARM64 host detected. Installing the win-x64 payload to run under x64 emulation.
) else (
    echo [ERROR] Unsupported Windows architecture: %NATIVE_ARCH%
    pause
    exit /b 1
)

set "PDF_COMPRESSOR_INSTALL_PARENT=%~1"
rem Windows PowerShell 5.1 keeps an inherited PSModulePath as-is. A PowerShell 7
rem parent process would hide Get-FileHash and break payload verification, so the
rem child rebuilds the default module path from the registry.
set "PSModulePath="
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -Runtime "%PDF_COMPRESSOR_RUNTIME%"
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" (
    echo [OK] PDF Compressor was installed or updated.
) else if "%RC%"=="4" (
    echo [INFO] Installation was cancelled.
) else if "%RC%"=="12" (
    echo [INFO] The installed runtime differs from the selected runtime.
    choice /C YN /N /M "Switch runtime in this install root? [Y/N] "
    if errorlevel 2 (
        echo [INFO] Runtime switch cancelled. The existing installation was retained.
        set "RC=4"
    ) else (
        powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -Runtime "%PDF_COMPRESSOR_RUNTIME%" -AllowRuntimeSwitch
        call set "RC=%%ERRORLEVEL%%"
    )
) else (
    echo [ERROR] Installation failed with exit code %RC%.
)
if not "%RC%"=="0" pause
exit /b %RC%
