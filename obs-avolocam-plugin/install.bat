@echo off
:: Run this script as Administrator to install the plugin

set "OBS_PLUGIN_DIR=C:\Program Files\obs-studio\obs-plugins\64bit"
set "BUILD_DIR=%~dp0build-win"
set "DLL_PATH=%BUILD_DIR%\Release\obs-avolocam.dll"

if not exist "%DLL_PATH%" (
    echo ERROR: Plugin not built. Run build.bat first.
    exit /b 1
)

copy /Y "%DLL_PATH%" "%OBS_PLUGIN_DIR%\"
if errorlevel 1 (
    echo.
    echo FAILED - Run as Administrator
    pause
    exit /b 1
)

echo Plugin installed to %OBS_PLUGIN_DIR%
echo Restart OBS to load changes.
