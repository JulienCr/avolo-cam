@echo off
REM ============================================================================
REM Build script for OBS AvoCam Plugin on Windows
REM ============================================================================
REM
REM Prerequisites:
REM   - Visual Studio 2019 or 2022 with C++ workload
REM   - CMake 3.16+ (cmake.org or via VS installer)
REM   - OBS Studio installed (obsproject.com)
REM   - Bonjour SDK for mDNS discovery (optional, from Apple Developer)
REM
REM Usage:
REM   build-windows.bat [Release|Debug] [OBS_DIR] [BONJOUR_SDK_DIR]
REM
REM Examples:
REM   build-windows.bat
REM   build-windows.bat Release
REM   build-windows.bat Release "D:\OBS Studio"
REM   build-windows.bat Debug "C:\Program Files\obs-studio" "C:\Program Files\Bonjour SDK"
REM
REM ============================================================================

setlocal enabledelayedexpansion

REM Parse arguments
set BUILD_TYPE=%1
if "%BUILD_TYPE%"=="" set BUILD_TYPE=Release

set OBS_DIR_ARG=%~2
set BONJOUR_DIR_ARG=%~3

REM Default paths
if "%OBS_DIR_ARG%"=="" (
    if exist "C:\Program Files\obs-studio" (
        set OBS_DIR_ARG=C:\Program Files\obs-studio
    ) else (
        echo WARNING: OBS Studio not found at default location.
        echo Please specify OBS_DIR as second argument or install OBS Studio.
    )
)

if "%BONJOUR_DIR_ARG%"=="" (
    if exist "C:\Program Files\Bonjour SDK" (
        set BONJOUR_DIR_ARG=C:\Program Files\Bonjour SDK
    ) else (
        echo NOTE: Bonjour SDK not found. mDNS discovery will be disabled.
        echo Install from Apple Developer to enable automatic camera discovery.
    )
)

set BUILD_DIR=build-win

echo.
echo ============================================================================
echo OBS AvoCam Plugin - Windows Build
echo ============================================================================
echo Build Type:   %BUILD_TYPE%
echo OBS Dir:      %OBS_DIR_ARG%
echo Bonjour Dir:  %BONJOUR_DIR_ARG%
echo Build Dir:    %BUILD_DIR%
echo ============================================================================
echo.

REM Check for Visual Studio
where cl >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo ERROR: Visual Studio C++ compiler not found.
    echo Please run this script from "Developer Command Prompt for VS" or
    echo "x64 Native Tools Command Prompt for VS".
    echo.
    echo Alternatively, ensure Visual Studio is installed with C++ workload.
    exit /b 1
)

REM Check for CMake
where cmake >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo ERROR: CMake not found. Please install CMake 3.16 or later.
    echo Download from: https://cmake.org/download/
    exit /b 1
)

REM Create build directory
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"

REM Determine Visual Studio generator
REM Try VS 2022 first, then 2019
set VS_GENERATOR=
for /f "tokens=*" %%i in ('cmake --help 2^>nul ^| findstr /C:"Visual Studio 17 2022"') do set VS_GENERATOR=Visual Studio 17 2022
if "%VS_GENERATOR%"=="" (
    for /f "tokens=*" %%i in ('cmake --help 2^>nul ^| findstr /C:"Visual Studio 16 2019"') do set VS_GENERATOR=Visual Studio 16 2019
)
if "%VS_GENERATOR%"=="" (
    echo ERROR: No supported Visual Studio generator found.
    echo Please install Visual Studio 2019 or 2022.
    exit /b 1
)

echo Using generator: %VS_GENERATOR%
echo.

REM Configure
echo Configuring with CMake...
cd "%BUILD_DIR%"

set CMAKE_ARGS=-G "%VS_GENERATOR%" -A x64

if not "%OBS_DIR_ARG%"=="" (
    set CMAKE_ARGS=!CMAKE_ARGS! -DOBS_DIR="%OBS_DIR_ARG%"
)

if not "%BONJOUR_DIR_ARG%"=="" (
    set CMAKE_ARGS=!CMAKE_ARGS! -DBONJOUR_SDK_DIR="%BONJOUR_DIR_ARG%"
)

cmake .. %CMAKE_ARGS%
if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: CMake configuration failed.
    cd ..
    exit /b 1
)

REM Build
echo.
echo Building %BUILD_TYPE% configuration...
cmake --build . --config %BUILD_TYPE% --parallel
if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: Build failed.
    cd ..
    exit /b 1
)

cd ..

REM Report results
echo.
echo ============================================================================
echo BUILD SUCCESSFUL
echo ============================================================================
echo.
echo Output: %BUILD_DIR%\%BUILD_TYPE%\obs-avolocam.dll
echo.
echo To install the plugin, copy the DLL to:
echo   %%APPDATA%%\obs-studio\plugins\obs-avolocam\bin\64bit\
echo.
echo Or run: build-windows.bat install
echo ============================================================================

REM Handle install target
if "%1"=="install" (
    echo.
    echo Installing plugin...
    set INSTALL_DIR=%APPDATA%\obs-studio\plugins\obs-avolocam\bin\64bit
    if not exist "!INSTALL_DIR!" mkdir "!INSTALL_DIR!"
    copy /Y "%BUILD_DIR%\Release\obs-avolocam.dll" "!INSTALL_DIR!\"
    echo Installed to: !INSTALL_DIR!
)

endlocal
