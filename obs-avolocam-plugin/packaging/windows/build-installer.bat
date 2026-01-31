@echo off
REM build-installer.bat - Build Windows installer for OBS AvoCam Plugin
REM
REM Usage: build-installer.bat [version]
REM
REM Requires:
REM - Visual Studio 2019/2022 with C++ workload
REM - CMake
REM - Inno Setup 6.x (for installer creation)
REM - OBS SDK

setlocal enabledelayedexpansion

set SCRIPT_DIR=%~dp0
set PROJECT_ROOT=%SCRIPT_DIR%..\..
set BUILD_DIR=%PROJECT_ROOT%\build

REM Version from argument or default
set VERSION=%1
if "%VERSION%"=="" set VERSION=1.0.0

echo ==========================================
echo Building OBS AvoCam Plugin v%VERSION%
echo ==========================================

REM Find Visual Studio
where cl >nul 2>&1
if %errorlevel% neq 0 (
    echo Looking for Visual Studio...

    REM Try VS 2022
    if exist "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" (
        call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    ) else if exist "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat" (
        call "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
    ) else if exist "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat" (
        call "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
    REM Try VS 2019
    ) else if exist "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvars64.bat" (
        call "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvars64.bat"
    ) else if exist "C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Auxiliary\Build\vcvars64.bat" (
        call "C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Auxiliary\Build\vcvars64.bat"
    ) else if exist "C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\VC\Auxiliary\Build\vcvars64.bat" (
        call "C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
    ) else (
        echo ERROR: Visual Studio not found
        exit /b 1
    )
)

REM Clean and create build directory
if exist "%BUILD_DIR%" rmdir /s /q "%BUILD_DIR%"
mkdir "%BUILD_DIR%"

REM Configure CMake
echo.
echo Configuring CMake...
cd /d "%BUILD_DIR%"
cmake -G "Visual Studio 17 2022" -A x64 ^
    -DCMAKE_BUILD_TYPE=Release ^
    "%PROJECT_ROOT%"

if %errorlevel% neq 0 (
    echo ERROR: CMake configuration failed
    exit /b 1
)

REM Build
echo.
echo Building...
cmake --build . --config Release --parallel

if %errorlevel% neq 0 (
    echo ERROR: Build failed
    exit /b 1
)

REM Check if DLL was created
if not exist "%BUILD_DIR%\Release\obs-avolocam.dll" (
    echo ERROR: obs-avolocam.dll not found
    exit /b 1
)

echo.
echo Build successful!
echo DLL location: %BUILD_DIR%\Release\obs-avolocam.dll

REM Check for Inno Setup
where iscc >nul 2>&1
if %errorlevel% neq 0 (
    REM Try common installation paths
    if exist "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" (
        set ISCC="C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    ) else if exist "C:\Program Files\Inno Setup 6\ISCC.exe" (
        set ISCC="C:\Program Files\Inno Setup 6\ISCC.exe"
    ) else (
        echo.
        echo WARNING: Inno Setup not found - skipping installer creation
        echo Download from: https://jrsoftware.org/isinfo.php
        echo.
        goto :manual_install
    )
) else (
    set ISCC=iscc
)

REM Build installer
echo.
echo Creating installer...
cd /d "%SCRIPT_DIR%"
%ISCC% /DMyAppVersion=%VERSION% installer.iss

if %errorlevel% neq 0 (
    echo ERROR: Installer creation failed
    goto :manual_install
)

echo.
echo ==========================================
echo Installer created: %BUILD_DIR%\obs-avolocam-%VERSION%-setup.exe
echo ==========================================

:manual_install
REM Create ZIP for manual installation
echo.
echo Creating ZIP archive...
cd /d "%BUILD_DIR%"

mkdir "obs-avolocam\bin\64bit" 2>nul
copy /y "Release\obs-avolocam.dll" "obs-avolocam\bin\64bit\"

REM Copy data files if they exist
if exist "%PROJECT_ROOT%\data" (
    mkdir "obs-avolocam\data" 2>nul
    xcopy /e /y "%PROJECT_ROOT%\data\*" "obs-avolocam\data\"
)

REM Create ZIP (using PowerShell)
powershell -command "Compress-Archive -Force -Path 'obs-avolocam' -DestinationPath 'obs-avolocam-%VERSION%-windows.zip'"

echo ZIP created: %BUILD_DIR%\obs-avolocam-%VERSION%-windows.zip

echo.
echo Installation instructions:
echo   Option 1 (Installer):
echo     Run obs-avolocam-%VERSION%-setup.exe
echo.
echo   Option 2 (Manual):
echo     Extract obs-avolocam-%VERSION%-windows.zip
echo     Copy obs-avolocam folder to %%APPDATA%%\obs-studio\plugins\
echo.
echo Done!
