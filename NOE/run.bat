@echo off
rem Rebuild the NOE pass and launch it, without leaving the NOE folder.
rem
rem   run.bat                  rebuild NOEPartialUPass, then run NOEPartialU.py
rem   run.bat <script.py>      same, with another script under NOE\script\
rem   run.bat --no-build       skip the build, just run
rem
rem NOE\exe is a junction to build\windows-vs2022\bin\Release, so the binaries
rem here are the ones that were just built -- nothing is copied.

setlocal
set NOE=%~dp0
set ROOT=%NOE%..
set BUILD=%ROOT%\build\windows-vs2022
set SCRIPT=%NOE%script\NOEPartialU.py
set DOBUILD=1

:parse
if "%~1"=="" goto run
if /i "%~1"=="--no-build" (set DOBUILD=0& shift & goto parse)
set SCRIPT=%NOE%script\%~1
shift
goto parse

:run
if not exist "%SCRIPT%" (
    echo [run] script not found: %SCRIPT%
    exit /b 1
)

if "%DOBUILD%"=="1" (
    echo [run] building NOEPartialUPass ...
    cmake --build "%BUILD%" --config Release --target NOEPartialUPass
    if errorlevel 1 (
        echo [run] build failed
        exit /b 1
    )
)

if not exist "%NOE%exe\Mogwai.exe" (
    echo [run] Mogwai.exe not found under NOE\exe
    echo [run] build it once with:  cmake --build "%BUILD%" --config Release
    exit /b 1
)

echo [run] launching Mogwai with %SCRIPT%
"%NOE%exe\Mogwai.exe" --script="%SCRIPT%"
