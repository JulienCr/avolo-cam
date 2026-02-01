@echo off
setlocal

set "OBS_PLUGIN_DIR=C:\Program Files\obs-studio\obs-plugins\64bit"
set "BUILD_DIR=%~dp0build-win"

echo [1/3] Building OBS Avolocam Plugin...
cmake --build "%BUILD_DIR%" --config Release
if errorlevel 1 (
    echo Build FAILED
    exit /b 1
)

echo [2/3] Installing to OBS plugins directory...
echo Destination: %OBS_PLUGIN_DIR%

:: Check if running as admin
net session >NUL 2>&1
if errorlevel 1 (
    echo.
    echo ERROR: Admin rights required to copy to Program Files
    echo Run this script as Administrator or copy manually:
    echo   copy "%BUILD_DIR%\Release\obs-avolocam.dll" "%OBS_PLUGIN_DIR%\"
    exit /b 1
)

copy /Y "%BUILD_DIR%\Release\obs-avolocam.dll" "%OBS_PLUGIN_DIR%\"
if errorlevel 1 (
    echo Install FAILED
    exit /b 1
)

echo [3/3] Done!
echo.
echo Plugin installed. Restart OBS to load the new version.
