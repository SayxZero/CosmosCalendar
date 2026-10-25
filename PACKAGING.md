# Установочные пакеты — план на будущее

Статус: **не начато**. Это план, а не описание сделанного; когда работа
начнётся, отсюда она переезжает в README и `CLAUDE.md` проектов.

## Что есть сейчас

- **Планер, Windows** — папка `release/` после `windeployqt`
  (`Calendar/build-exe.bat`): программа с библиотеками Qt, запускается без
  установленного Qt, но без установщика, ярлыков и удаления.
- **Планер, Android** — APK, подписанный **отладочным** ключом
  (`Calendar/build-apk.bat`). Годится для установки на свой телефон, не для
  публикации.
- **Сервер** — сборка из исходников; на Linux `cmake --install` ставит
  `/usr/local/bin/CalendarServer`, рядом лежит служба
  `CalendarServer/deploy/calendar-server.service`.

В обоих `CMakeLists.txt` уже есть `install(TARGETS …)`, но нет ярлыка
`.desktop`, иконок hicolor, метаданных AppStream и CPack.

## Нужен ли Linux-установщик

Да, но не «установщик» в смысле мастера, а пакеты и бандлы: на Linux их ждут
через менеджер пакетов или Flatpak/AppImage. WiX — только Windows (и
собирается только там), поэтому он закрывает лишь Windows-часть.

## Схема

Один источник правды — CMake `install()` плюс **CPack** (кроссплатформенный,
уже часть CMake):

- **Windows, планер**: CPack-генератор **WIX** (даёт `.msi`) либо NSIS или
  Inno Setup. Библиотеки Qt — через `windeployqt` в шаге установки (как сейчас
  в `build-exe.bat`), плюс ярлык в меню «Пуск». Для MSI нужны постоянный
  `UpgradeGuid` и подпись кода, иначе SmartScreen будет предупреждать.
- **Linux, планер**:
  - `.deb` и `.rpm` через CPack DEB/RPM — зависимости от системного Qt 6,
    самый лёгкий путь;
  - **AppImage** (linuxdeploy с плагином Qt) — один файл, не зависит от
    дистрибутива; или **Flatpak** (манифест, рантайм KDE/Qt) — для Flathub.
    Начать с `.deb` и AppImage;
  - не хватает в репозитории: `calendarplanner.desktop`, иконки PNG/SVG (есть
    `logo.svg` и генератор `tools/icons`), `*.metainfo.xml` и их установки в
    `Calendar/CMakeLists.txt`.
- **Linux, сервер**: `.deb` с unit-файлом в `/lib/systemd/system`,
  пользователем `calendar` и примером `server.ini` в `/etc`; либо
  Docker-образ — самый простой способ развернуть сервер.
- **Windows, сервер**: zip с `windeployqt`-сборкой и `run-server.bat`, позже —
  установка службой Windows.
- **Android**: остаётся APK; для выпуска нужен собственный ключ (сейчас
  отладочный) и, при желании, AAB для магазинов или сборка для F-Droid.
- **Сборка**: GitHub Actions с матрицей windows/ubuntu в каждом из
  репозиториев — Linux-пакеты на Windows не собрать (разве что в WSL или
  Docker). `.deb` планера собирается на самом старом поддерживаемом
  дистрибутиве: Qt 6.4+ есть в Ubuntu 24.04 и Debian 12; серверу хватает
  Qt 6.2 (Ubuntu 22.04).

## Порядок работ

1. В `Calendar/CMakeLists.txt` и `CalendarServer/CMakeLists.txt` — установка
   `.desktop`, иконок, unit-файла и блок `CPACK_*`.
2. Windows: `cpack -G WIX` после `windeployqt`; проверка на чистой машине без
   Qt в `PATH`.
3. Linux: `cpack -G DEB`, затем скрипт AppImage в `Calendar/tools/`.
4. CI-workflow в репозиториях Calendar и CalendarServer, подпись,
   документация в README и `CLAUDE.md`.

## Проверка

Установка пакета на чистую машину (Windows 10, Ubuntu 24.04), запуск без Qt в
`PATH`, обновление поверх старой версии (база должна дотянуться до новой
схемы сама), удаление — данные пользователя при этом остаются.

## Открытые вопросы

- Какие дистрибутивы Linux важны.
- Нужна ли подпись кода для Windows (и чей сертификат).
- Ключ выпуска для Android: где хранить, кто подписывает. В репозиторий он
  попадать не должен — `.gitignore` планера уже отсекает `*.keystore` и `*.jks`.
