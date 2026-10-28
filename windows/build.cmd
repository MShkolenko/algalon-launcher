@echo off
rem Build the launcher for one realm profile with MSVC: build.cmd <profile>   (profiles\<profile>, default: example)
rem GUI subsystem (no console window), statically linked, icon from the profile. /Brepro makes the build deterministic:
rem the same source and profile give a byte-identical exe, so anyone can rebuild a release and compare its SHA256.
setlocal
set "PROFILE=%~1"
if "%PROFILE%"=="" set "PROFILE=example"
cd /d "%~dp0" || exit /b 1
if not exist "profiles\%PROFILE%\profile.h" (echo no profile profiles\%PROFILE% & exit /b 1)
set "VS="
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (echo vswhere.exe not found: install Visual Studio with the C++ desktop tools & exit /b 1)
for /f "usebackq delims=" %%i in (`call "%VSWHERE%" -latest -prerelease -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS=%%i"
if not defined VS (echo Visual Studio with the C++ desktop tools not found & exit /b 1)
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
set "OUT=%PROFILE%-launcher.exe"
rc /nologo /i "profiles\%PROFILE%" /fo launcher.res "profiles\%PROFILE%\launcher.rc" || exit /b 1
cl /nologo /std:c++17 /O2 /MT /EHsc /W4 /Brepro /DUNICODE /D_UNICODE /I "profiles\%PROFILE%" forever-launcher.cpp launcher.res /Fe:"%OUT%" /link /SUBSYSTEM:WINDOWS /Brepro shell32.lib ole32.lib user32.lib crypt32.lib ws2_32.lib advapi32.lib credui.lib
set rc=%errorlevel%
del /q forever-launcher.obj launcher.res 2>nul
if %rc% neq 0 exit /b %rc%
for %%f in ("%OUT%") do echo built %%~nxf, %%~zf bytes
