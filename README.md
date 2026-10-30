# CosmosCalendar

«Космос календарь» — календарь-планер для компьютера и телефона с
необязательной синхронизацией через собственный сервер и сайтом для того же
аккаунта. Этот репозиторий — зонтичный: он собирает все части в одну рабочую
копию и держит документы, которые касаются их вместе.

| Сабмодуль | Репозиторий | Что это |
|---|---|---|
| `Calendar/` | [SayxZero/Calendar](https://github.com/SayxZero/Calendar) | планер: события и задачи в одном окне, привычки, напоминания и будильник, виджеты Android; Qt 6 / C++17 для Windows, Linux и Android |
| `CalendarServer/` | [SayxZero/CalendarServer](https://github.com/SayxZero/CalendarServer) | сервер синхронизации: аккаунты, обмен записями между устройствами, общие календари; служба на Qt 6 для Windows и Linux и админ-панель к ней |
| `CalendarWeb/` | [SayxZero/CalendarWeb](https://github.com/SayxZero/CalendarWeb) | сайт: страница-презентация и планер в браузере для аккаунта сервера — все экраны, повторения, напоминания, общий доступ, ICS, палитры; раскладки для компьютера и телефона |
| `CalendarWebServer/` | [SayxZero/CalendarWebServer](https://github.com/SayxZero/CalendarWebServer) | бэкенд сайта на ASP.NET Core: отдаёт сайт и передаёт его запросы серверу синхронизации |

Планер работает и без сервера — сервер нужен только для аккаунтов,
синхронизации между устройствами, совместного доступа к календарю и сайта.
Сайт — ещё одно устройство аккаунта: записи на нём те же, что в планере.

## Получить

```bash
git clone --recursive https://github.com/SayxZero/CosmosCalendar.git
```

В уже склонированной копии без сабмодулей:

```bash
git submodule update --init
```

Сабмодули следят за веткой `master` своих репозиториев; подтянуть их свежие
версии — `git submodule update --remote`. Каждый можно клонировать и собирать
и отдельно.

## Собрать

У каждой части своя сборка и свой README со всеми средами:

- **планер** — [Calendar/README.md](Calendar/README.md), «Сборка»: батники для
  Windows (`build-release.bat` — exe и APK одной командой), Qt Creator, CMake и
  qmake, пакеты Debian/Ubuntu и Fedora, Android;
- **сервер** — [CalendarServer/README.md](CalendarServer/README.md), «Сборка»:
  `build-server.bat` (сервер и админ-панель), CMake и qmake, Debian/Ubuntu и
  Fedora, служба systemd;
- **сайт** — [CalendarWebServer/README.md](CalendarWebServer/README.md):
  `run-web.bat` собирает бэкенд (.NET 10) и открывает сайт на
  `http://localhost:8780` перед сервером синхронизации; `publish.bat` —
  готовая к переносу папка. Сам сайт сборки не требует
  ([CalendarWeb/README.md](CalendarWeb/README.md)).

Коротко, на системе с Qt 6.4+ и CMake:

```bash
cmake -S Calendar -B build/planner -DCMAKE_BUILD_TYPE=Release
cmake --build build/planner

cmake -S CalendarServer -B build/server -DCMAKE_BUILD_TYPE=Release
cmake --build build/server

dotnet build CalendarWebServer/CalendarWebServer.sln          # бэкенд сайта
node --test "CalendarWeb/tests/*.test.js"                     # тесты сайта
```

## Пакеты для выпуска

```powershell
.\build-packages.ps1
```

Одна команда собирает всё, что выпускается, в `Build/` по платформам, а на
экране показывает только этапы — с анимацией, пока этап идёт, и итогом
(журналы этапов — в `Build/logs`). Пароль ключа выпуска спрашивается в
начале, скрытым вводом, вставляется из буфера обмена (Ctrl+V) и сразу
проверяется; `-SkipApk` собирает всё, кроме APK, и пароль не спрашивает. Тот
же набор без анимации, с полным выводом — `build-packages.bat`.

Что получается: установщики Windows (MSI и setup.exe планера и сервера,
WiX 3), APK, подписанный ключом выпуска
(`%USERPROFILE%\.android\cosmos-release.jks`), архивы сервера и сайта для
Linux (Ubuntu 26.04) и `SHA256SUMS.txt`. Linux собирается в Docker Engine
внутри WSL — `build-linux.ps1`, отдельно или этапом `build-packages.ps1`
(`-SkipLinux` — без него); планера для Linux в пакетах пока нет.
Подробности и установка Docker — в [PACKAGING.md](PACKAGING.md).

## Документы

| Файл | О чём |
|---|---|
| [DESDOC.md](DESDOC.md) | устройство системы: состав, протокол планера и сервера, данные, версии, развёртывание |
| [ISSUES.md](ISSUES.md) | ошибки и грабли, на которые уже наступали, по темам |
| [PACKAGING.md](PACKAGING.md) | установочные пакеты: как собираются, что внутри, что дальше |
| [CLAUDE.md](CLAUDE.md) | заметки для Claude Code: порядок коммитов в сабмодулях, правила проверок, окружение |

Внутреннее устройство частей — в `Calendar/DesDoc.md`,
`CalendarServer/DesDoc.md`, `CalendarWeb/DesDoc.md` и
`CalendarWebServer/DesDoc.md`.
