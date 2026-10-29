<#
.SYNOPSIS
    Every release package of Cosmos Calendar in one run, with nothing on the
    screen but the steps and how they went.

.DESCRIPTION
    The same packages as build-packages.bat, gathered in Build\:

        Build\Windows\CosmosCalendar-<v>-x64.msi, -setup.exe   planner
        Build\Windows\CalendarServer-<v>-x64.msi, -setup.exe   sync server
        Build\Android\CosmosCalendar-<v>.apk                   signed with the release key
        Build\Linux\CalendarServer-<v>-ubuntu26.04-x64.tar.gz  sync server (build-linux.ps1)
        Build\Linux\CalendarWebServer-<v>-linux-x64.tar.gz     site server with the site
        Build\SHA256SUMS.txt

    Linux is built in Docker Engine of a WSL distribution by build-linux.ps1;
    without Docker the step is skipped with a note in Build\Linux.

    Each step runs the build script of its project with the whole output going
    into Build\logs\<step>.log; the console shows the step, a spinner while it
    runs and the outcome. A failed step stops the run and points at its log.

    The password of the release key is asked for once, at the start, hidden
    (Ctrl+V or Shift+Insert paste it from the clipboard), and checked with
    keytool before anything is built. COSMOS_KEYSTORE_PASS skips the question,
    -SkipApk the APK with its key altogether.

        powershell -ExecutionPolicy Bypass -File build-packages.ps1
        powershell -ExecutionPolicy Bypass -File build-packages.ps1 -SkipApk

.PARAMETER Keystore
    The release key; COSMOS_KEYSTORE or %USERPROFILE%\.android\cosmos-release.jks.

.PARAMETER SkipApk
    Everything but the APK: no release key, no password. Build\Android is left
    as it was, with the APK of an earlier run if there is one.

.PARAMETER SkipLinux
    Without the Linux builds in Docker.
#>
[CmdletBinding()]
param(
    [string]$Keystore = $(if ($env:COSMOS_KEYSTORE) { $env:COSMOS_KEYSTORE }
                          else { Join-Path $env:USERPROFILE '.android\cosmos-release.jks' }),
    [switch]$SkipApk,
    [switch]$SkipLinux
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
$Build = Join-Path $Root 'Build'
$Logs = Join-Path $Build 'logs'

# A spinner needs a console to draw in; redirected output (a log, CI) gets one
# line per step instead.
$Animate = -not [Console]::IsOutputRedirected

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

$script:TitleWidth = 34

function Write-StepLine {
    param(
        [ValidateSet('run', 'ok', 'fail', 'skip')] [string]$State,
        [string]$Title,
        [TimeSpan]$Elapsed = [TimeSpan]::Zero,
        [string]$Detail = '',
        [string]$Frame = '|'
    )
    $mark, $color = switch ($State) {
        'run'  { " $Frame  ", 'Cyan' }
        'ok'   { ' OK ', 'Green' }
        'fail' { ' !! ', 'Red' }
        'skip' { ' -- ', 'Yellow' }
    }
    $time = if ($Elapsed.TotalSeconds -ge 1) { '{0}:{1:00}' -f [int][Math]::Floor($Elapsed.TotalMinutes), $Elapsed.Seconds } else { '' }
    $word = switch ($State) {
        'run'  { 'выполняется' }
        'ok'   { 'готово' }
        'fail' { 'ошибка' }
        'skip' { 'пропущено' }
    }
    $text = '{0}  {1,5}  {2}' -f $Title.PadRight($script:TitleWidth), $time, $word
    if ($Detail) { $text += " · $Detail" }

    if ($Animate) { Write-Host -NoNewline "`r" }
    Write-Host -NoNewline '  ['
    Write-Host -NoNewline $mark.Substring(0, 4) -ForegroundColor $color
    Write-Host -NoNewline '] '
    if ($Animate) {
        # Pad to the width of the window so that a shorter line wipes the
        # longer one it replaces.
        $room = [Math]::Max(10, [Console]::WindowWidth - 9)
        if ($text.Length -gt $room) { $text = $text.Substring(0, $room) }
        $text = $text.PadRight($room)
    }
    if ($State -eq 'run') { Write-Host -NoNewline $text }
    else { Write-Host $text -ForegroundColor $(if ($State -eq 'ok') { 'Gray' } else { $color }) }
}

# Wipes the spinner line a step left behind when nothing replaces it.
function Clear-StepLine {
    if ($Animate) { Write-Host -NoNewline ("`r" + (' ' * ([Console]::WindowWidth - 1)) + "`r") }
}

function Write-Problem {
    param([string[]]$Lines)
    foreach ($line in $Lines) { Write-Host "         $line" -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------------------
# Running one step
# ---------------------------------------------------------------------------

# Runs a command line through cmd with its whole output in $Log, drawing the
# spinner meanwhile. $Environment goes to the child alone - the password of
# the key never lands in this process's own environment.
function Invoke-Step {
    param(
        [string]$Title,
        [string]$Command,
        [string]$Log,
        [string]$WorkingDirectory = $Root,
        [hashtable]$Environment = @{}
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    # /s: cmd drops the outer quotes and runs the rest exactly as written.
    $psi.Arguments = '/d /s /c "' + $Command + ' > "' + $Log + '" 2>&1 < nul"'
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $WorkingDirectory
    foreach ($name in $Environment.Keys) { $psi.EnvironmentVariables[$name] = [string]$Environment[$name] }

    $clock = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($psi)
    $frames = '|', '/', '-', '\'
    $i = 0
    try {
        if ($Animate) { try { [Console]::CursorVisible = $false } catch { } }
        while (-not $process.WaitForExit(125)) {
            if ($Animate) {
                Write-StepLine -State run -Title $Title -Elapsed $clock.Elapsed -Frame $frames[$i % 4]
                $i++
            }
        }
        $process.WaitForExit()
    } finally {
        if ($Animate) { try { [Console]::CursorVisible = $true } catch { } }
    }
    [pscustomobject]@{ Ok = ($process.ExitCode -eq 0); Code = $process.ExitCode; Elapsed = $clock.Elapsed }
}

function Read-Log {
    param([string]$Log)
    if (Test-Path $Log) { [IO.File]::ReadAllLines($Log, [Text.Encoding]::UTF8) } else { @() }
}

# What of a failed log is worth showing: the lines the scripts and the tools
# mark as errors, the last few of them.
function Get-LogProblems {
    param([string]$Log)
    $marked = @(Read-Log $Log | Where-Object { $_ -match '\[ОШИБКА\]|FAIL!|error[ :]|ERROR|FAILED|не удал' })
    if ($marked.Count -gt 5) { $marked = $marked[($marked.Count - 5)..($marked.Count - 1)] }
    $marked | ForEach-Object { $_.Trim() }
}

function Get-TestTotals {
    # A step may run several test programs (the server: tst_server and
    # tst_admin) and leave several reports; their totals add up. QtTest ends
    # with "Totals: 49 passed, 0 failed, 1 skipped"; dotnet test with
    # "Passed!  - Failed: 0, Passed: 24, ..." or, at the normal verbosity,
    # with lines of their own: "Total tests: 24", "Passed: 23", "Skipped: 1".
    param([string[]]$Log)
    $found = $false
    $passed = 0
    $skipped = 0
    foreach ($line in @($Log | ForEach-Object { Read-Log $_ })) {
        if ($line -match 'Totals: (\d+) passed, (\d+) failed, (\d+) skipped') {
            $passed += [int]$Matches[1]
            $skipped += [int]$Matches[3]
            $found = $true
        } elseif ($line -match 'Failed:\s*(\d+), Passed:\s*(\d+), Skipped:\s*(\d+), Total:') {
            $passed += [int]$Matches[2]
            $skipped += [int]$Matches[3]
            $found = $true
        } elseif ($line -match '^\s*Passed:\s*(\d+)\s*$') {
            $passed += [int]$Matches[1]
            $found = $true
        } elseif ($line -match '^\s*Skipped:\s*(\d+)\s*$') {
            $skipped += [int]$Matches[1]
        }
    }
    if (-not $found) { return '' }
    $text = "тесты: пройдено $passed"
    if ($skipped -gt 0) { $text += ", пропущено $skipped" }
    $text
}

# ---------------------------------------------------------------------------
# The password
# ---------------------------------------------------------------------------

function Get-ClipboardText {
    try { $text = Get-Clipboard -Raw } catch { $text = $null }
    if ($null -eq $text) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $text = [Windows.Forms.Clipboard]::GetText()
        } catch { $text = $null }
    }
    [string]$text
}

# Reads a line without echoing it: a star per character. Ctrl+V and
# Shift+Insert take the clipboard - its first line, so a password copied
# together with its line break does not carry the break along. A paste that
# the console itself performs (right click, Ctrl+V in the console's own
# settings, Windows Terminal) arrives as ordinary keys and works the same.
# Escape gives up and returns $null. The key source and the clipboard are
# parameters only so that the function can be tried without a keyboard.
function Read-Secret {
    param(
        [string]$Prompt,
        [scriptblock]$ReadKey = { [Console]::ReadKey($true) },
        [scriptblock]$GetClipboard = { Get-ClipboardText }
    )
    Write-Host -NoNewline $Prompt
    $chars = New-Object System.Collections.Generic.List[char]
    while ($true) {
        $key = & $ReadKey
        $ctrl = ($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0
        $shift = ($key.Modifiers -band [ConsoleModifiers]::Shift) -ne 0
        if ($key.Key -eq [ConsoleKey]::Enter) { break }
        if ($key.Key -eq [ConsoleKey]::Escape) { Write-Host ''; return $null }
        if ($key.Key -eq [ConsoleKey]::Backspace) {
            if ($chars.Count -gt 0) {
                $chars.RemoveAt($chars.Count - 1)
                Write-Host -NoNewline "`b `b"
            }
            continue
        }
        if (($ctrl -and $key.Key -eq [ConsoleKey]::V) -or ($shift -and $key.Key -eq [ConsoleKey]::Insert)) {
            $text = & $GetClipboard
            if ($text) {
                $text = ($text -split "`r`n|`n|`r")[0]
                foreach ($c in $text.ToCharArray()) { $chars.Add($c) }
                Write-Host -NoNewline ('*' * $text.Length)
            }
            continue
        }
        if ($key.KeyChar -ne [char]0 -and -not [char]::IsControl($key.KeyChar)) {
            $chars.Add($key.KeyChar)
            Write-Host -NoNewline '*'
        }
    }
    Write-Host ''
    -join $chars
}

# keytool opens the store with the password from the environment of its own
# process; a wrong one makes it fail before the long builds even start.
function Test-KeystorePassword {
    param([string]$Keytool, [string]$Path, [string]$Password)
    $log = Join-Path $Logs '00-keystore.log'
    $run = Invoke-Step -Title 'Ключ выпуска: проверка пароля' -Log $log `
        -Command ('"' + $Keytool + '" -list -keystore "' + $Path + '" -storepass:env COSMOS_CHECK_PASS') `
        -Environment @{ COSMOS_CHECK_PASS = $Password }
    Clear-StepLine
    $run.Ok
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Get-ProjectVersion {
    param([string]$CMakeLists)
    $line = Get-Content $CMakeLists -Encoding UTF8 | Where-Object { $_ -match '^\s*VERSION\s+(\d+(\.\d+)*)\s*$' } | Select-Object -First 1
    if (-not $line) { throw "Не нашлась версия в $CMakeLists" }
    $null = $line -match '^\s*VERSION\s+(\d+(\.\d+)*)'
    $Matches[1]
}

function Clear-BuildFolders {
    # Empties the folders of Build\ that this run fills again, and returns why
    # it could not - empty when it could. A package still open elsewhere (an
    # installer started from Build\Windows) holds its file, and what was
    # deleted before it stays deleted.
    param([string]$Build, [string[]]$Folders)
    foreach ($folder in $Folders) {
        $dir = Join-Path $Build $folder
        try {
            if (Test-Path $dir) { Remove-Item -Recurse -Force $dir -ErrorAction Stop }
            $null = New-Item -ItemType Directory -Force $dir
        } catch {
            return $_.Exception.Message
        }
    }
    return ''
}

function Invoke-Main {
    $started = [Diagnostics.Stopwatch]::StartNew()
    $planner = Join-Path $Root 'Calendar'
    $server = Join-Path $Root 'CalendarServer'

    Write-Host ''
    Write-Host '  Космос календарь: пакеты выпуска' -ForegroundColor White
    Write-Host ''

    # ---- environment ----------------------------------------------------
    $problems = @()
    foreach ($file in "$planner\build-installer.bat", "$server\build-installer.bat") {
        if (-not (Test-Path $file)) { $problems += "нет $file - git submodule update --init" }
    }
    $wix = if ($env:WIX) { Join-Path $env:WIX 'bin' } else { 'C:\Program Files (x86)\WiX Toolset v3.7\bin' }
    if (-not (Test-Path (Join-Path $wix 'candle.exe'))) { $problems += "не найден WiX 3: $wix" }
    $jdk = if ($env:PLANNER_JDK) { $env:PLANNER_JDK } else { 'C:\Program Files\Java\jdk-17' }
    $keytool = Join-Path $jdk 'bin\keytool.exe'
    # Without the APK neither the key nor keytool, which checks its password, is needed.
    if (-not $SkipApk) {
        if (-not (Test-Path $keytool)) { $problems += "не найден keytool: $keytool (PLANNER_JDK)" }
        if (-not (Test-Path $Keystore)) { $problems += "не найден ключ выпуска: $Keystore (COSMOS_KEYSTORE)" }
    }
    if ($problems.Count -eq 0) {
        $plannerVersion = Get-ProjectVersion "$planner\CMakeLists.txt"
        $serverVersion = Get-ProjectVersion "$server\CMakeLists.txt"
        $versions = "планер $plannerVersion, сервер $serverVersion"
        if ($SkipApk) { $versions += ', без APK' }
        Write-StepLine -State ok -Title 'Проверка окружения' -Detail $versions
    } else {
        Write-StepLine -State fail -Title 'Проверка окружения'
        Write-Problem $problems
        return 1
    }

    # The APK of an earlier run stays when this one does not build a new one:
    # it cost a password.
    $wiped = if ($SkipApk) { 'Windows', 'Linux', 'logs' } else { 'Windows', 'Android', 'Linux', 'logs' }
    $null = New-Item -ItemType Directory -Force (Join-Path $Build 'Android')
    $busy = Clear-BuildFolders $Build $wiped
    if ($busy) {
        Write-StepLine -State fail -Title 'Очистка Build'
        Write-Problem @($busy,
            'Файл держит другая программа - обычно установщик: Windows Installer',
            'отпускает MSI через несколько минут после установки. Закройте её и запустите снова.')
        return 1
    }
    Remove-Item -Force (Join-Path $Build 'SHA256SUMS.txt') -ErrorAction SilentlyContinue

    # ---- the release key ----------------------------------------------
    $password = $env:COSMOS_KEYSTORE_PASS
    $keyName = Split-Path $Keystore -Leaf
    if ($SkipApk) {
        $password = $null
        Write-StepLine -State skip -Title 'Ключ выпуска' -Detail 'не нужен без APK (-SkipApk)'
    } elseif ($password) {
        if (-not (Test-KeystorePassword $keytool $Keystore $password)) {
            Write-StepLine -State fail -Title 'Ключ выпуска' -Detail 'пароль из COSMOS_KEYSTORE_PASS не подходит'
            return 1
        }
    } elseif ([Console]::IsInputRedirected) {
        Write-StepLine -State fail -Title 'Ключ выпуска' -Detail 'нет консоли для пароля: задайте COSMOS_KEYSTORE_PASS'
        return 1
    } else {
        $accepted = $false
        for ($attempt = 1; $attempt -le 3 -and -not $accepted; $attempt++) {
            $password = Read-Secret "  Пароль $keyName (Ctrl+V - вставить, Esc - отмена): "
            if ($null -eq $password) {
                Write-StepLine -State fail -Title 'Ключ выпуска' -Detail 'отменено'
                return 1
            }
            $accepted = Test-KeystorePassword $keytool $Keystore $password
            if (-not $accepted) { Write-Host '         пароль не подходит' -ForegroundColor DarkYellow }
        }
        if (-not $accepted) {
            Write-StepLine -State fail -Title 'Ключ выпуска' -Detail 'три неверных пароля'
            return 1
        }
    }
    if (-not $SkipApk) { Write-StepLine -State ok -Title 'Ключ выпуска' -Detail $keyName }

    # ---- the builds -----------------------------------------------------
    $serverEnv = @{ SERVER_BUILD = 'build-release' }
    $apkEnv = @{ PLANNER_KEYSTORE = $Keystore; PLANNER_KEYSTORE_PASS = $password }
    $windows = Join-Path $Build 'Windows'
    $steps = @(
        @{ Title = 'Планер: сборка и тесты'; Key = 'planner-build'; Dir = $planner; Tests = $true
           Command = '"' + "$planner\build-exe.bat" + '" -noui' },
        @{ Title = 'Планер: MSI и setup.exe'; Key = 'planner-installers'; Dir = $planner
           Command = '"' + "$planner\build-installer.bat" + '" -noui -skipbuild -out "' + $windows + '"' },
        @{ Title = 'Планер: APK для Android'; Key = 'planner-apk'; Dir = $planner; Env = $apkEnv; Apk = $true
           Skip = [bool]$SkipApk; Command = '"' + "$planner\build-apk.bat" + '" -noui' },
        @{ Title = 'Сервер: сборка и тесты'; Key = 'server-build'; Dir = $server; Env = $serverEnv; Tests = $true
           Command = '"' + "$server\build-server.bat" + '" -noui' },
        @{ Title = 'Сервер: MSI и setup.exe'; Key = 'server-installers'; Dir = $server; Env = $serverEnv
           Command = '"' + "$server\build-installer.bat" + '" -noui -skipbuild -out "' + $windows + '"' }
    )

    $n = 0
    foreach ($step in $steps) {
        # The number is counted for a skipped step too: the logs of the others
        # keep their names whichever steps run.
        $n++
        if ($step.ContainsKey('Skip') -and $step.Skip) {
            $kept = @(Get-ChildItem (Join-Path $Build 'Android') -Filter '*.apk' -File | Sort-Object Name)
            $note = if ($kept.Count -gt 0) { "-SkipApk; в Build\Android прежний $($kept[-1].Name)" }
                    else { '-SkipApk; Build\Android пуст' }
            Write-StepLine -State skip -Title $step.Title -Detail $note
            continue
        }
        $log = Join-Path $Logs ('{0:00}-{1}.log' -f $n, $step.Key)
        $environment = if ($step.ContainsKey('Env')) { $step.Env } else { @{} }
        $run = Invoke-Step -Title $step.Title -Command $step.Command -Log $log `
            -WorkingDirectory $step.Dir -Environment $environment

        $detail = ''
        if ($run.Ok -and $step.ContainsKey('Apk')) {
            $apk = Join-Path $planner 'release\CalendarPlanner-signed.apk'
            if (Test-Path $apk) {
                Copy-Item $apk (Join-Path $Build "Android\CosmosCalendar-$plannerVersion.apk")
                $signer = Read-Log $log | Where-Object { $_ -match 'certificate DN: (.*)$' } | Select-Object -First 1
                if ($signer -and $signer -match 'CN=([^,]+)') { $detail = "подпись: $($Matches[1])" }
            } else {
                $run.Ok = $false
            }
        }
        if ($step.ContainsKey('Tests')) { $detail = Get-TestTotals $log }

        if (-not $run.Ok) {
            Write-StepLine -State fail -Title $step.Title -Elapsed $run.Elapsed -Detail $detail
            Write-Problem (@(Get-LogProblems $log) + "журнал: $log")
            return 1
        }
        Write-StepLine -State ok -Title $step.Title -Elapsed $run.Elapsed -Detail $detail
    }
    $password = $null
    $apkEnv = $null

    # ---- Linux: the servers in Docker -------------------------------------
    # build-linux.ps1 shows its own steps in its log; here the step is one.
    # Without Docker in WSL (code 3) the step is skipped, not failed: the
    # packages of Windows do not need it. The planner for Linux is not built yet.
    $linux = Join-Path $Build 'Linux'
    $linuxTitle = 'Linux: серверы в Docker'
    $linuxNote = @('Пакеты Linux в этот раз не собирались: {0}.',
        'Сборка - build-linux.ps1 (Docker в WSL), подробнее - PACKAGING.md.')
    if ($SkipLinux) {
        Set-Content -Path (Join-Path $linux 'README.txt') -Encoding UTF8 -Value ($linuxNote -f '-SkipLinux')
        Write-StepLine -State skip -Title $linuxTitle -Detail '-SkipLinux'
    } else {
        $log = Join-Path $Logs ('{0:00}-linux.log' -f ($n + 1))
        $run = Invoke-Step -Title $linuxTitle -Log $log `
            -Command ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + "$Root\build-linux.ps1" + '"')
        if ($run.Code -eq 3) {
            Set-Content -Path (Join-Path $linux 'README.txt') -Encoding UTF8 -Value ($linuxNote -f 'нет Docker в WSL')
            Write-StepLine -State skip -Title $linuxTitle -Detail 'нет Docker в WSL (PACKAGING.md)'
        } elseif (-not $run.Ok) {
            Write-StepLine -State fail -Title $linuxTitle -Elapsed $run.Elapsed
            Write-Problem (@(Get-LogProblems $log) + "журнал: $log")
            return 1
        } else {
            $reports = @(Get-ChildItem (Join-Path $linux 'tests') -Filter '*.txt' -File | ForEach-Object { $_.FullName })
            Write-StepLine -State ok -Title $linuxTitle -Elapsed $run.Elapsed -Detail (Get-TestTotals $reports)
        }
    }

    # ---- checksums --------------------------------------------------------
    $sums = foreach ($platform in 'Windows', 'Android', 'Linux') {
        Get-ChildItem (Join-Path $Build $platform) -File | Where-Object Name -ne 'README.txt' | Sort-Object Name | ForEach-Object {
            '{0}  {1}/{2}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $platform, $_.Name
        }
    }
    [IO.File]::WriteAllLines((Join-Path $Build 'SHA256SUMS.txt'), [string[]]$sums)
    Write-StepLine -State ok -Title 'Контрольные суммы' -Detail 'SHA256SUMS.txt'

    # ---- summary ------------------------------------------------------------
    $total = $started.Elapsed
    Write-Host ''
    Write-Host ('  Готово за {0}:{1:00}. Пакеты в {2}:' -f [int][Math]::Floor($total.TotalMinutes), $total.Seconds, $Build) -ForegroundColor Green
    foreach ($platform in 'Windows', 'Android', 'Linux') {
        Get-ChildItem (Join-Path $Build $platform) -File | Where-Object Name -ne 'README.txt' | Sort-Object Name | ForEach-Object {
            Write-Host ('    {0,-9} {1,-44} {2,6:N1} МБ' -f $platform, $_.Name, ($_.Length / 1MB))
        }
    }
    Write-Host ''
    return 0
}

# Dot-sourcing (". .\build-packages.ps1") only defines the functions.
# The build scripts retitle the console and switch it to UTF-8 (title, chcp
# 65001); both are put back afterwards.
if ($MyInvocation.InvocationName -ne '.') {
    $code = 1
    $title = $Host.UI.RawUI.WindowTitle
    $inputEncoding = [Console]::InputEncoding
    $outputEncoding = [Console]::OutputEncoding
    try { $code = Invoke-Main | Select-Object -Last 1 }
    catch {
        Write-Host ''
        Write-Host "  Сбой скрипта: $($_.Exception.Message)" -ForegroundColor Red
        $code = 1
    } finally {
        try {
            $Host.UI.RawUI.WindowTitle = $title
            [Console]::InputEncoding = $inputEncoding
            [Console]::OutputEncoding = $outputEncoding
        } catch { }
    }
    exit $code
}
