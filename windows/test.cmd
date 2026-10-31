@echo off
rem Build and run test_hosts.cpp (the hosts file logic on sample files; the real hosts file is never touched).
setlocal
cd /d "%~dp0" || exit /b 1
set "VS="
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (echo vswhere.exe not found & exit /b 1)
for /f "usebackq delims=" %%i in (`call "%VSWHERE%" -latest -prerelease -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS=%%i"
if not defined VS (echo Visual Studio with the C++ desktop tools not found & exit /b 1)
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
cl /nologo /utf-8 /std:c++17 /EHsc /DUNICODE /D_UNICODE /I "profiles\example" test_hosts.cpp /Fe:test_hosts.exe /link /SUBSYSTEM:CONSOLE shell32.lib ole32.lib user32.lib crypt32.lib ws2_32.lib || exit /b 1
cl /nologo /utf-8 /std:c++17 /EHsc /DUNICODE /D_UNICODE /I "profiles\example" test_updater.cpp /Fe:test_updater.exe /link /SUBSYSTEM:CONSOLE shell32.lib ole32.lib user32.lib crypt32.lib ws2_32.lib || exit /b 1
cl /nologo /utf-8 /std:c++17 /EHsc /DUNICODE /D_UNICODE test_saved_login.cpp /Fe:test_saved_login.exe /link /SUBSYSTEM:CONSOLE advapi32.lib || exit /b 1
del /q test_hosts.obj test_updater.obj test_saved_login.obj 2>nul
"%~dp0test_hosts.exe" || exit /b 1
"%~dp0test_updater.exe"
if errorlevel 1 exit /b 1
"%~dp0test_saved_login.exe"
