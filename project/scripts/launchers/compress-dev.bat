@echo off
setlocal DisableDelayedExpansion
REM === pdf-compressor entrypoint ===
REM NOTE: Japanese text must NOT appear in .bat files (cmd.exe UTF-8 bug).
REM
REM Flow: compress.bat -> _internal/compress.ps1 -> analyze -> select -> invoke gs/qpdf
REM PDF path is passed via temp file to avoid command injection.
REM See _internal\ARCHITECTURE.md for design details.

for %%I in ("%~dp0..\..") do set "TOOLDIR=%%~fI\"
where pwsh >nul 2>&1
if errorlevel 1 (
    echo [ERROR] PowerShell 7+ ^(pwsh.exe^) is required before running this tool.
    echo Install: winget install --id Microsoft.PowerShell
    exit /b 2
)
set "PSEXE=pwsh"

REM --- Detect dependencies ---
where gswin64c >nul 2>&1
set "GS_MISSING=%ERRORLEVEL%"
where qpdf >nul 2>&1
set "QPDF_MISSING=%ERRORLEVEL%"
where pdfinfo >nul 2>&1
set "PDFINFO_MISSING=%ERRORLEVEL%"
where pdfimages >nul 2>&1
set "PDFIMAGES_MISSING=%ERRORLEVEL%"

if not "%GS_MISSING%"=="0" goto :dep_check_fallback
if not "%QPDF_MISSING%"=="0" goto :dep_check_fallback
if not "%PDFINFO_MISSING%"=="0" goto :dep_check_fallback
if not "%PDFIMAGES_MISSING%"=="0" goto :dep_check_fallback
goto :have_deps

:dep_check_fallback
REM Tools not on PATH; let compress.ps1 try tool-paths.json before failing.
goto :have_deps

:have_deps

REM --- Main loop ---
:compress_loop

if not "%~1"=="" (
    set "PDF_PATH=%~1"
    goto :do_compress
)

set "PDF_PATH="
set /p PDF_PATH=PDF or folder path (drag-drop OK):
if "%PDF_PATH%"=="" (
    echo No path entered.
    goto :compress_loop
)
set "PDF_PATH=%PDF_PATH:"=%"

:do_compress
echo.
echo Compressing input path from temp file.
echo.

if not exist "%TOOLDIR%_work" mkdir "%TOOLDIR%_work" >nul 2>&1
set "ARGFILE=%TOOLDIR%_work\bat-%RANDOM%-%RANDOM%.input.txt"
set "PDFCOMP_INPUT_PATH=%PDF_PATH%"
set "PDFCOMP_ARG_FILE=%ARGFILE%"
%PSEXE% -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Set-Content -LiteralPath $env:PDFCOMP_ARG_FILE -Value $env:PDFCOMP_INPUT_PATH -Encoding UTF8"
if errorlevel 1 (
    echo [ERROR] Failed to write input path file.
    exit /b 1
)

%PSEXE% -NoProfile -ExecutionPolicy Bypass -File "%TOOLDIR%_internal\compress.ps1" -InputPathFile "%ARGFILE%"
set "RC=%ERRORLEVEL%"
del /q "%ARGFILE%" >nul 2>&1

if "%RC%"=="0" (
    echo.
    echo [SUCCESS] Compression completed.
) else if "%RC%"=="2" (
    echo.
    echo [INFO] Missing dependencies. Run scripts\setup\install-dependencies.bat first.
) else if "%RC%"=="3" (
    echo.
    echo [INFO] Invalid input path.
) else if "%RC%"=="4" (
    echo.
    echo [INFO] Output already exists. Re-run with --Force to overwrite.
) else if "%RC%"=="5" (
    echo.
    echo [ERROR] Workspace policy violation. Internal output target is outside this tool directory.
) else if "%RC%"=="6" (
    echo.
    echo [INFO] Operator action required. Check stop_reason in the JSONL log for safety or target details.
) else (
    echo.
    echo [WARN] Compression exited with code %RC%.
)
echo.

if not "%~1"=="" (
    exit /b %RC%
)

set "CONTINUE="
set /p CONTINUE=Compress another? (y/n):
if /i "%CONTINUE%"=="y" (
    echo.
    goto :compress_loop
)

echo.
echo Press any key to close...
pause >nul
exit /b %RC%
