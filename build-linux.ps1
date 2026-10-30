<#
.SYNOPSIS
    The Linux builds of the servers, in Docker on Ubuntu 26.04, with their
    tests and a check that the images run.

.DESCRIPTION
    Docker Engine lives in a WSL distribution (Ubuntu-26.04; how it is set up
    - PACKAGING.md, "Linux: Docker в WSL"), and this script drives it through
    wsl.exe. Into Build\Linux:

        CalendarServer-<v>-ubuntu26.04-x64.tar.gz   server, benchmark, admin panel
        CalendarWebServer-<v>-linux-x64.tar.gz      site server with the site
        CalendarWebMCP-<v>-linux-x64.tar.gz         cloud MCP service
        tests\                                      reports of the tests

    1. CalendarServer: its packaging/linux/Dockerfile builds and tests it all,
       exports the archive and makes the image of the server;
    2. CalendarWebServer: the same, with CalendarWeb/site beside it;
    3. CalendarWebMCP: the same, with the logic of the site beside it;
    4. the check: the server image runs on a Docker network of its own and
       answers /api/ping, from Windows too (127.0.0.1:<PingPort>); the tests
       of the site server run once more against it, the one with a real
       server among them; the image of the site server in front of it answers
       /api/ping on 127.0.0.1:<PingPort + 1> and, with the MCP image behind
       it, keeps the door /mcp shut without a token.

    The images stay in Docker: cosmos-calendar-server:<v>,
    cosmos-calendar-web:<v> and cosmos-calendar-web-build:<v> (the SDK with
    the built tests). Logs - Build\logs\linux-*.log.

        powershell -ExecutionPolicy Bypass -File build-linux.ps1
        powershell -ExecutionPolicy Bypass -File build-linux.ps1 -NoCache

    Exit code 3: there is no Docker in WSL; build-packages.ps1 skips Linux then.

.PARAMETER Distro
    The WSL distribution with Docker; COSMOS_WSL_DISTRO or Ubuntu-26.04.

.PARAMETER PingPort
    The port on 127.0.0.1 of Windows for the server under check, the next one
    for the site server. Not 8765: the live server is there.

.PARAMETER NoCache
    Every layer anew, the packages of Ubuntu too; the tests run even when
    nothing has changed.
#>
[CmdletBinding()]
param(
    [string]$Distro = $(if ($env:COSMOS_WSL_DISTRO) { $env:COSMOS_WSL_DISTRO } else { 'Ubuntu-26.04' }),
    [int]$PingPort = 8767,
    [switch]$NoCache
)

# The steps, the spinner, the logs and the test totals are those of
# build-packages.ps1: dot-sourcing it only defines its functions and paths.
. (Join-Path $PSScriptRoot 'build-packages.ps1')

$LinuxDir = Join-Path $Build 'Linux'

# A path of Windows as the distribution sees it (DrvFs under /mnt).
function ConvertTo-WslPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    '/mnt/' + $full.Substring(0, 1).ToLower() + $full.Substring(2).Replace('\', '/')
}

# docker in the distribution, its output as lines and in $Log as well.
# PowerShell 5.1 turns the stderr of a program into errors, and with 'Stop'
# the first one would end the script.
function Invoke-Docker {
    param([string[]]$Arguments, [string]$Log)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& wsl.exe -d $Distro --exec docker @Arguments 2>&1 | ForEach-Object { "$_" })
        $ok = $LASTEXITCODE -eq 0
    } finally {
        $ErrorActionPreference = $saved
    }
    if ($Log) {
        [IO.File]::AppendAllLines($Log, [string[]](@("> docker $($Arguments -join ' ')") + $lines),
            (New-Object Text.UTF8Encoding $false))
    }
    [pscustomobject]@{ Ok = $ok; Lines = $lines }
}

# The same command for Invoke-Step, which runs it through cmd.
function Get-DockerCommand {
    param([string[]]$Arguments)
    'wsl.exe -d ' + $Distro + ' --exec docker ' + (($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' ')
}

# The version of the Docker daemon, or nothing. A distribution that is just
# starting may not have it up yet - systemd starts it on the first call to its
# socket - so a few tries; a distribution that is not there gets none.
function Get-DockerVersion {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & wsl.exe -d $Distro --exec true 2>&1
        if ($LASTEXITCODE -ne 0) { return '' }
    } finally {
        $ErrorActionPreference = $saved
    }
    for ($i = 0; $i -lt 10; $i++) {
        $run = Invoke-Docker @('version', '--format', '{{.Server.Version}}')
        if ($run.Ok -and $run.Lines.Count -gt 0) { return $run.Lines[0].Trim() }
        Start-Sleep -Seconds 2
    }
    ''
}

function Get-WebVersion {
    param([string]$Csproj)
    $text = [IO.File]::ReadAllText($Csproj)
    if ($text -notmatch '<Version>([^<]+)</Version>') { throw "Не нашлась версия в $Csproj" }
    $Matches[1]
}

# A page from 127.0.0.1 of Windows. WSL hands a port published in the
# distribution over to Windows a moment after it opens.
function Get-Page {
    param([string]$Url, [int]$Seconds = 20)
    for ($i = 0; $i -lt $Seconds; $i++) {
        try { return (Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 $Url).Content }
        catch { Start-Sleep -Seconds 1 }
    }
    $null
}

# Step 3. Returns what went wrong, or nothing; $Result.Detail gets what went
# right. The containers and the network go away whatever happened.
function Invoke-ImageCheck {
    param([string]$ServerImage, [string]$WebImage, [string]$WebBuildImage, [string]$McpImage, [string]$Log, [hashtable]$Result)
    $net = 'cosmos-linux-check'
    $serverName = 'cosmos-check-server'
    $webName = 'cosmos-check-web'
    $mcpName = 'cosmos-check-mcp'
    $webPort = $PingPort + 1
    # -v: the volumes /data of the images go with the containers.
    $clean = {
        $null = Invoke-Docker @('rm', '-f', '-v', $serverName, $webName, $mcpName) $Log
        $null = Invoke-Docker @('network', 'rm', $net) $Log
    }
    # Leftovers of a run that was cut short.
    & $clean
    try {
        if (-not (Invoke-Docker @('network', 'create', $net) $Log).Ok) { return 'не создалась сеть Docker' }
        $run = Invoke-Docker @('run', '-d', '--name', $serverName, '--network', $net,
            '-p', "127.0.0.1:${PingPort}:8765", $ServerImage) $Log
        if (-not $run.Ok) { return 'контейнер сервера не запустился' }

        # The check of the image itself asks /api/ping from inside, once a
        # second while the server starts.
        $health = ''
        for ($i = 0; $i -lt 60 -and $health -ne 'healthy'; $i++) {
            Start-Sleep -Seconds 1
            $health = ((Invoke-Docker @('inspect', '-f', '{{.State.Status}} {{.State.Health.Status}}', $serverName)).Lines -join ' ').Trim()
            if ($health -notmatch '^running') { break }
            $health = ($health -split ' ')[-1]
        }
        if ($health -ne 'healthy') {
            $null = Invoke-Docker @('logs', '--tail', '30', $serverName) $Log
            return "сервер в контейнере не ответил на /api/ping ($health)"
        }
        $ping = Get-Page "http://127.0.0.1:$PingPort/api/ping"
        if (-not $ping) { return "сервер в контейнере не отвечает из Windows на 127.0.0.1:$PingPort" }
        [IO.File]::AppendAllLines($Log, [string[]]@("ping 127.0.0.1:${PingPort}: $ping"))

        # The whole set of the site server once more, now with the test against
        # a real server; its report replaces the one of the build.
        $run = Invoke-Docker @('run', '--rm', '--network', $net, '-e', "WEB_TEST_SERVER=${serverName}:8765",
            $WebBuildImage, 'dotnet', 'test', 'CalendarWebServer.sln', '-c', 'Release', '--no-build',
            '--logger', 'console;verbosity=normal') $Log
        [IO.File]::WriteAllLines((Join-Path $LinuxDir 'tests\dotnet-test.txt'), [string[]]$run.Lines,
            (New-Object Text.UTF8Encoding $false))
        if (-not $run.Ok) { return 'тесты сайта с сервером не прошли' }
        if (@($run.Lines | Where-Object { $_ -match 'Skipped:\s*[1-9]' }).Count -gt 0) {
            return 'тест сайта с настоящим сервером пропущен'
        }

        $run = Invoke-Docker @('run', '-d', '--name', $mcpName, '--network', $net, $McpImage,
            '--upstream', "${serverName}:8765", '--allowed-host', $mcpName) $Log
        if (-not $run.Ok) { return 'контейнер службы MCP не запустился' }

        # A secret for these few seconds: the tokens of this run die with the container.
        $secret = [Convert]::ToBase64String((1..36 | ForEach-Object { Get-Random -Maximum 256 }))
        $run = Invoke-Docker @('run', '-d', '--name', $webName, '--network', $net, '-e', "Web__McpSecret=$secret",
            '-p', "127.0.0.1:${webPort}:8780", $WebImage, '--upstream', "${serverName}:8765",
            '--public-url', "http://127.0.0.1:$webPort", '--mcp-upstream', "${mcpName}:8790") $Log
        if (-not $run.Ok) { return 'контейнер сайта не запустился' }
        $proxied = Get-Page "http://127.0.0.1:$webPort/api/ping"
        $page = Get-Page "http://127.0.0.1:$webPort/"
        [IO.File]::AppendAllLines($Log, [string[]]@("ping 127.0.0.1:${webPort}: $proxied"))
        if (-not $proxied -or -not $page -or $page -notmatch '<html') {
            $null = Invoke-Docker @('logs', '--tail', '30', $webName) $Log
            return "сайт в контейнере не отвечает на 127.0.0.1:$webPort"
        }

        $metadata = Get-Page "http://127.0.0.1:$webPort/.well-known/oauth-authorization-server"
        if (-not $metadata -or $metadata -notmatch 'authorization_endpoint') {
            return 'сайт в контейнере не отдаёт описание OAuth режима MCP'
        }
        $door = 0
        try {
            $null = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method Post -Body '{}' -ContentType 'application/json' "http://127.0.0.1:$webPort/mcp"
        } catch {
            if ($_.Exception.Response) { $door = [int]$_.Exception.Response.StatusCode }
        }
        [IO.File]::AppendAllLines($Log, [string[]]@("/mcp without a token: $door"))
        if ($door -ne 401) { return "дверь /mcp без токена ответила $door, а не 401" }
        $mcpHealth = (Invoke-Docker @('run', '--rm', '--network', $net, '--entrypoint', 'node', $McpImage, '-e',
            "fetch('http://${mcpName}:8790/health').then(r=>r.text()).then(t=>{console.log(t);process.exit(t.includes('web-mcp')?0:1)}).catch(()=>process.exit(1))") $Log)
        if (-not $mcpHealth.Ok) {
            $null = Invoke-Docker @('logs', '--tail', '30', $mcpName) $Log
            return 'служба MCP в контейнере не отвечает'
        }

        $Result.Detail = "/api/ping: сервер на :$PingPort, сайт на :$webPort, /mcp закрыт без токена; " +
            (Get-TestTotals (Join-Path $LinuxDir 'tests\dotnet-test.txt')).Replace('тесты:', 'тесты сайта с сервером:')
        return ''
    } finally {
        & $clean
    }
}

function Invoke-LinuxMain {
    $started = [Diagnostics.Stopwatch]::StartNew()
    $server = Join-Path $Root 'CalendarServer'
    $web = Join-Path $Root 'CalendarWebServer'
    $site = Join-Path $Root 'CalendarWeb\site'
    $mcp = Join-Path $Root 'CalendarWebMCP'

    Write-Host ''
    Write-Host '  Космос календарь: серверы для Linux' -ForegroundColor White
    Write-Host ''

    # ---- environment ----------------------------------------------------
    $problems = @()
    foreach ($file in "$server\packaging\linux\Dockerfile", "$web\packaging\linux\Dockerfile", "$mcp\packaging\linux\Dockerfile", "$site\index.html") {
        if (-not (Test-Path $file)) { $problems += "нет $file - git submodule update --init" }
    }
    if ($problems.Count -gt 0) {
        Write-StepLine -State fail -Title 'Проверка окружения'
        Write-Problem $problems
        return 1
    }
    $serverVersion = Get-ProjectVersion "$server\CMakeLists.txt"
    $webVersion = Get-WebVersion "$web\src\CalendarWebServer\CalendarWebServer.csproj"
    $mcpVersion = (ConvertFrom-Json ([IO.File]::ReadAllText("$mcp\package.json"))).version
    $docker = Get-DockerVersion
    if (-not $docker) {
        Write-StepLine -State fail -Title 'Проверка окружения' -Detail "нет Docker в WSL $Distro"
        Write-Problem @('Как его поставить - PACKAGING.md, раздел «Linux: Docker в WSL».',
            'Другой дистрибутив - параметр -Distro или COSMOS_WSL_DISTRO.')
        return 3
    }
    Write-StepLine -State ok -Title 'Проверка окружения' `
        -Detail "Docker $docker в WSL $Distro; сервер $serverVersion, сайт $webVersion"

    $busy = Clear-BuildFolders $Build @('Linux')
    if ($busy) {
        Write-StepLine -State fail -Title 'Очистка Build\Linux'
        Write-Problem @($busy)
        return 1
    }
    $null = New-Item -ItemType Directory -Force $Logs
    Remove-Item (Join-Path $Logs 'linux-*.log') -ErrorAction SilentlyContinue

    # ---- the builds -----------------------------------------------------
    # Only the first build of a project goes without the cache: the next
    # ones take the stages it has just made.
    $out = ConvertTo-WslPath $LinuxDir
    $buildx = @('buildx', 'build', '--progress=plain')
    $fresh = if ($NoCache) { @('--no-cache') } else { @() }
    $serverContext = ConvertTo-WslPath $server
    $serverFile = "$serverContext/packaging/linux/Dockerfile"
    $serverImage = "cosmos-calendar-server:$serverVersion"
    $webContext = ConvertTo-WslPath $web
    $webArgs = @('-f', "$webContext/packaging/linux/Dockerfile", '--build-context', ('site=' + (ConvertTo-WslPath $site)))
    $webImage = "cosmos-calendar-web:$webVersion"
    $webBuildImage = "cosmos-calendar-web-build:$webVersion"
    $mcpContext = ConvertTo-WslPath $mcp
    $mcpArgs = @('-f', "$mcpContext/packaging/linux/Dockerfile", '--build-context', ('site=' + (ConvertTo-WslPath $site)))
    $mcpImage = "cosmos-calendar-web-mcp:$mcpVersion"

    $steps = @(
        @{ Title = 'Сервер: сборка и тесты'; Key = 'linux-1-server'; Reports = 'tst_*.txt'
           Commands = @(
               ($buildx + $fresh + @('-f', $serverFile, '--target', 'dist', '--output', "type=local,dest=$out", $serverContext)),
               ($buildx + @('-f', $serverFile, '--target', 'runtime', '-t', $serverImage, $serverContext))) },
        @{ Title = 'Сайт: сборка и тесты'; Key = 'linux-2-web'; Reports = 'dotnet-test.txt'
           Commands = @(
               ($buildx + $fresh + $webArgs + @('--target', 'dist', '--output', "type=local,dest=$out", $webContext)),
               ($buildx + $webArgs + @('--target', 'build', '-t', $webBuildImage, $webContext)),
               ($buildx + $webArgs + @('--target', 'runtime', '-t', $webImage, $webContext))) },
        @{ Title = 'MCP: сборка и тесты'; Key = 'linux-3-mcp'; Reports = 'node-test.txt'
           Commands = @(
               ($buildx + $fresh + $mcpArgs + @('--target', 'dist', '--output', "type=local,dest=$out", $mcpContext)),
               ($buildx + $mcpArgs + @('--target', 'runtime', '-t', $mcpImage, $mcpContext))) }
    )
    foreach ($step in $steps) {
        $log = Join-Path $Logs "$($step.Key).log"
        # In parentheses: the redirection Invoke-Step adds would take the last one alone.
        $command = '(' + (($step.Commands | ForEach-Object { Get-DockerCommand $_ }) -join ' && ') + ')'
        $run = Invoke-Step -Title $step.Title -Command $command -Log $log
        $reports = @(Get-ChildItem (Join-Path $LinuxDir 'tests') -Filter $step.Reports -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
        $detail = if ($reports.Count -gt 0) { Get-TestTotals $reports } else { '' }
        if (-not $run.Ok) {
            Write-StepLine -State fail -Title $step.Title -Elapsed $run.Elapsed -Detail $detail
            Write-Problem (@(Get-LogProblems $log) + "журнал: $log")
            return 1
        }
        Write-StepLine -State ok -Title $step.Title -Elapsed $run.Elapsed -Detail $detail
    }

    # ---- the check of the images ---------------------------------------
    $title = 'Проверка: образы в работе'
    $log = Join-Path $Logs 'linux-4-check.log'
    if ($Animate) { Write-StepLine -State run -Title $title }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $result = @{ Detail = '' }
    $problem = Invoke-ImageCheck $serverImage $webImage $webBuildImage $mcpImage $log $result
    if ($problem) {
        Write-StepLine -State fail -Title $title -Elapsed $clock.Elapsed -Detail $problem
        Write-Problem @("журнал: $log")
        return 1
    }
    Write-StepLine -State ok -Title $title -Elapsed $clock.Elapsed -Detail $result.Detail

    # ---- summary ------------------------------------------------------------
    $total = $started.Elapsed
    Write-Host ''
    Write-Host ('  Готово за {0}:{1:00}. В {2}:' -f [int][Math]::Floor($total.TotalMinutes), $total.Seconds, $LinuxDir) -ForegroundColor Green
    Get-ChildItem $LinuxDir -File | Sort-Object Name | ForEach-Object {
        Write-Host ('    {0,-46} {1,6:N1} МБ' -f $_.Name, ($_.Length / 1MB))
    }
    Write-Host "  Образы Docker: $serverImage, $webImage, $mcpImage"
    Write-Host ''
    return 0
}

# Dot-sourcing (". .\build-linux.ps1") only defines the functions. docker
# writes UTF-8, and the console is switched to it for the time of the run.
if ($MyInvocation.InvocationName -ne '.') {
    $code = 1
    $outputEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
        $code = Invoke-LinuxMain | Select-Object -Last 1
    } catch {
        Write-Host ''
        Write-Host "  Сбой скрипта: $($_.Exception.Message)" -ForegroundColor Red
        $code = 1
    } finally {
        try { [Console]::OutputEncoding = $outputEncoding } catch { }
    }
    exit $code
}
