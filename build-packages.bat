@echo off
rem ---------------------------------------------------------------------------
rem  Every package of Cosmos Calendar ready for a release, in one run:
rem
rem      Build\Windows\CosmosCalendar-<v>-x64.msi     planner, Windows Installer
rem      Build\Windows\CosmosCalendar-<v>-setup.exe   planner, setup.exe
rem      Build\Windows\CalendarServer-<v>-x64.msi     sync server, Windows Installer
rem      Build\Windows\CalendarServer-<v>-setup.exe   sync server, setup.exe
rem      Build\Android\CosmosCalendar-<v>.apk         planner, signed with the release key
rem      Build\Linux\                                 not built yet (Docker, later)
rem      Build\SHA256SUMS.txt                         checksums of all of the above
rem
rem      build-packages.bat            build, waiting for a key press at the end
rem      build-packages.bat -noui      return at once (for scripts)
rem
rem  Each project builds its own packages (Calendar\build-installer.bat,
rem  Calendar\build-apk.bat, CalendarServer\build-installer.bat); this script
rem  only runs them in order and gathers what they made. Build\ is wiped per
rem  platform and is not part of the repository.
rem
rem  The APK is signed with the release key:
rem      COSMOS_KEYSTORE        default %USERPROFILE%\.android\cosmos-release.jks
rem      COSMOS_KEYSTORE_PASS   asked for when not set (typed in hidden); it
rem                             must not contain a double quote
rem  The key and its password never belong to a repository.
rem
rem  build-packages.ps1 builds the same with only the steps on the screen, a
rem  spinner and the outcome, checks the password before building and takes
rem  it from the clipboard; this script shows the whole output.
rem ---------------------------------------------------------------------------

chcp 65001 >nul
setlocal
cd /d "%~dp0"
set "ROOT=%~dp0"

set "NOUI="
for %%A in (%*) do if /i "%%~A"=="-noui" set "NOUI=1"

set "BUILD=%ROOT%Build"

if not exist "%ROOT%Calendar\build-installer.bat" (
    echo [ОШИБКА] Нет сабмодуля Calendar. Выполните: git submodule update --init
    goto :fail
)
if not exist "%ROOT%CalendarServer\build-installer.bat" (
    echo [ОШИБКА] Нет сабмодуля CalendarServer. Выполните: git submodule update --init
    goto :fail
)

rem ---- the release key --------------------------------------------------
if not defined COSMOS_KEYSTORE set "COSMOS_KEYSTORE=%USERPROFILE%\.android\cosmos-release.jks"
if not exist "%COSMOS_KEYSTORE%" (
    echo [ОШИБКА] Не найден ключ выпуска: "%COSMOS_KEYSTORE%"
    echo           Создайте его keytool-ом или задайте COSMOS_KEYSTORE.
    goto :fail
)
if not defined COSMOS_KEYSTORE_PASS call :askpass
if not defined COSMOS_KEYSTORE_PASS (
    echo [ОШИБКА] Пароль ключа выпуска не введён.
    goto :fail
)

call :version "%ROOT%Calendar\CMakeLists.txt" PLANNER_VERSION || goto :fail
call :version "%ROOT%CalendarServer\CMakeLists.txt" SERVER_VERSION || goto :fail

echo.
echo ############################################################
echo #   Пакеты Космос календаря
echo #   Планер %PLANNER_VERSION%, сервер %SERVER_VERSION%
echo #   Ключ APK: %COSMOS_KEYSTORE%
echo #   Начало: %DATE% %TIME:~0,8%
echo ############################################################

for %%P in (Windows Android Linux) do (
    if exist "%BUILD%\%%P" rmdir /s /q "%BUILD%\%%P"
    mkdir "%BUILD%\%%P" || goto :fail
)
del /q "%BUILD%\SHA256SUMS.txt" 2>nul

rem ---- 1. planner, Windows ----------------------------------------------
title Пакеты: планер, Windows
echo.
echo ======================= [1/4] Планер, Windows =======================
call "%ROOT%Calendar\build-installer.bat" -noui -out "%BUILD%\Windows"
if errorlevel 1 (
    set "STEP=установщики планера"
    goto :fail
)

rem ---- 2. planner, Android ----------------------------------------------
rem build-apk.bat signs with whatever PLANNER_KEYSTORE names; here that is the
rem release key instead of the debug one of everyday builds.
title Пакеты: планер, Android
echo.
echo ======================= [2/4] Планер, Android =======================
set "PLANNER_KEYSTORE=%COSMOS_KEYSTORE%"
set "PLANNER_KEYSTORE_PASS=%COSMOS_KEYSTORE_PASS%"
call "%ROOT%Calendar\build-apk.bat" -noui
if errorlevel 1 (
    set "STEP=APK планера"
    goto :fail
)
copy /y "%ROOT%Calendar\release\CalendarPlanner-signed.apk" ^
    "%BUILD%\Android\CosmosCalendar-%PLANNER_VERSION%.apk" >nul || goto :fail

rem ---- 3. server, Windows -----------------------------------------------
title Пакеты: сервер, Windows
echo.
echo ======================= [3/4] Сервер, Windows =======================
call "%ROOT%CalendarServer\build-installer.bat" -noui -out "%BUILD%\Windows"
if errorlevel 1 (
    set "STEP=установщики сервера"
    goto :fail
)

rem ---- 4. Linux ---------------------------------------------------------
rem A stub: Linux packages (.deb of the planner and the server, AppImage, the
rem Docker image of the server) are to be built in Docker - see
rem packaging\linux in each project. Nothing to do on Windows yet.
title Пакеты: Linux
echo.
echo ======================= [4/4] Linux =======================
echo       Пропущено: сборка пакетов Linux ещё не настроена (будет в Docker).
> "%BUILD%\Linux\README.txt" echo Пакеты Linux пока не собираются: сборка будет настроена в Docker.
>> "%BUILD%\Linux\README.txt" echo Подробнее - Calendar\packaging\linux и CalendarServer\packaging\linux.

rem ---- checksums --------------------------------------------------------
for %%P in (Windows Android) do (
    for %%F in ("%BUILD%\%%P\*") do call :checksum "%%~fF" "%%P/%%~nxF"
)

echo.
echo ############################################################
echo #   ВСЁ ГОТОВО   %TIME:~0,8%
echo ############################################################
for %%P in (Windows Android) do (
    for %%F in ("%BUILD%\%%P\*") do echo     Build\%%P\%%~nxF
)
echo     Build\SHA256SUMS.txt
echo.
title Пакеты собраны
if not defined NOUI pause
exit /b 0

:fail
echo.
echo ############################################################
if defined STEP (
    echo #   ОСТАНОВЛЕНО: не удались %STEP%
) else (
    echo #   ОСТАНОВЛЕНО
)
echo #   Подробности - выше по журналу.
echo ############################################################
title Пакеты не собраны
if not defined NOUI pause
exit /b 1

:version
rem %1 - CMakeLists.txt, %2 - the variable to set: the VERSION line of project().
set "%~2="
for /f "tokens=2" %%V in ('findstr /r /c:"^ *VERSION [0-9]" "%~1"') do (
    if not defined %~2 set "%~2=%%V"
)
if not defined %~2 (
    echo [ОШИБКА] Не нашлась версия в "%~1".
    exit /b 1
)
exit /b 0

:askpass
rem PowerShell reads the password without echoing it; cmd has no way to.
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "$s = Read-Host 'Пароль ключа выпуска APK' -AsSecureString; [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))"`) do set "COSMOS_KEYSTORE_PASS=%%P"
exit /b 0

:checksum
rem %1 - the file, %2 - its name in the list. certutil prints a header line,
rem the hash and a closing line; only the hash has no colon in it.
for /f "delims=" %%H in ('certutil -hashfile "%~1" SHA256 ^| findstr /v ":"') do (
    >> "%BUILD%\SHA256SUMS.txt" echo %%H  %~2
)
exit /b 0
