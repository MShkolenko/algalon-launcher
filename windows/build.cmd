@echo off
rem Build algalon-launcher.exe with MSVC: GUI subsystem (no console window), statically linked, icon embedded.
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
cd /d %~dp0
rc /nologo /fo algalon.res algalon.rc || exit /b 1
cl /nologo /std:c++17 /O2 /MT /EHsc /W4 /DUNICODE /D_UNICODE algalon-launcher.cpp algalon.res /Fe:algalon-launcher.exe /link /SUBSYSTEM:WINDOWS shell32.lib ole32.lib user32.lib crypt32.lib ws2_32.lib
set rc=%errorlevel%
del /q algalon-launcher.obj algalon.res 2>nul
if %rc% neq 0 exit /b %rc%
for %%f in (algalon-launcher.exe) do echo built %%f, %%~zf bytes
