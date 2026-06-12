# NTFS Mounter для macOS

[English](README.md) | **Русский**

[![CI](https://github.com/ArrivaRUS/ntfs-mounter-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/ArrivaRUS/ntfs-mounter-macos/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/ArrivaRUS/ntfs-mounter-macos)](https://github.com/ArrivaRUS/ntfs-mounter-macos/releases)

Чтение **и запись** NTFS на macOS с Apple Silicon — **без kernel extensions и без режима Reduced Security**. Связка user-space [FUSE-T](https://github.com/macos-fuse-t/fuse-t) и форка [macos-fuse-t/ntfs-3g](https://github.com/macos-fuse-t/ntfs-3g), обёрнутая в:

- CLI-утилиту (`ntfs-mount list / mount / unmount / eject / auto`),
- **LaunchDaemon**, который автоматически монтирует каждый NTFS-диск в режиме чтения-записи через несколько секунд после подключения,
- **приложение в строке меню** с кнопкой Eject для каждого диска,
- автоматическую защиту от встроенного FSKit-драйвера NTFS (на macOS Tahoe он молча монтирует тот же диск read-only параллельно и блокирует запись).

Проверено на **macOS 26 Tahoe / Apple Silicon**.

## Зачем

macOS читает NTFS, но не умеет на него писать. Стандартные решения либо платные (Paragon, Tuxera), либо требуют понижать защиту системы и ставить kernel extension (классический macFUSE). FUSE-T работает целиком в user space (общается с ядром через миниатюрный NFS-шим), поэтому:

- не нужно ставить kext,
- не нужно отключать System Integrity Protection,
- не нужно перезагружаться в Recovery.

## Архитектура

```
┌─────────────────────────────────────────────────────────────┐
│   Приложение в строке меню (Swift)                          │
│   - меню строится при открытии из `ntfs-mount list          │
│     --porcelain`                                            │
│   - индикатор "● RW" / "○ RO" у каждого диска               │
│   - Eject по-дисково / Eject All / Открыть в Finder         │
│   - привилегии: sudo -n, фолбэк на системный диалог пароля  │
└──────────────────────┬──────────────────────────────────────┘
                       │ вызывает `ntfs-mount eject / mount`
┌──────────────────────┴──────────────────────────────────────┐
│   ntfs-mount (bash CLI)                                     │
│   - парсит `diskutil list` + `mount`                        │
│   - вычищает зомби-маунты от старых device id               │
│   - отстреливает параллельные FSKit-маунты Apple            │
│   - eject в границах метки диска: unmount FUSE-T mount +    │
│     SIGTERM ntfs-3g, затем `diskutil eject`                 │
└──────────────────────┬──────────────────────────────────────┘
                       │ использует
┌──────────────────────┴──────────────────────────────────────┐
│   ntfs-3g (бинарник, собран из macos-fuse-t/ntfs-3g)        │
│   ← связан с FUSE-T через libfuse-t                         │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│   automount-daemon (LaunchDaemon, root)                     │
│   - опрос каждые 3с через `ntfs-mount list --porcelain`     │
│   - новый NTFS-диск → монтирует в RW                        │
│   - вернулся паразитный FSKit-mount → размонтирует его      │
│   - владельца определяет по /dev/console (GUI-пользователь) │
│   - уважает eject-маркеры в /var/run/ntfs-mount             │
└─────────────────────────────────────────────────────────────┘
```

## Установка

```bash
git clone https://github.com/ArrivaRUS/ntfs-mounter-macos.git
cd ntfs-mounter-macos

# 1. Драйвер (FUSE-T + ntfs-3g) + CLI
bash install.sh

# 2. GUI (приложение в строке меню) + демон автомонтирования
bash install-gui.sh

# 3. Full Disk Access для демона (обязательно начиная с macOS Sequoia)
bash grant-permissions.sh
```

Третий шаг — единственный неочевидный. Даже от root LaunchDaemon не может открыть raw-устройство `/dev/diskX`, пока вы явно не выдали Full Disk Access **обоим**:

- `/usr/local/bin/ntfs-3g` (бинарник, который читает/пишет диск),
- `/bin/bash` (интерпретатор скрипта демона).

`grant-permissions.sh` сам откроет нужную страницу System Settings и подскажет, что сделать.

> **Важно:** разрешение FDA привязано к хэшу бинарника. Если пересобрали/переустановили `ntfs-3g` — добавьте его в System Settings → Privacy & Security → Full Disk Access заново.

## Использование

После установки просто **подключите NTFS-диск**. Через ~5–10 секунд он появится смонтированным в `/Volumes/<метка>` с правом записи, а в строке меню у него будет значок `● RW`.

Ручное управление:

```bash
ntfs-mount list                 # все NTFS-тома и их статус RO/RW
ntfs-mount list --porcelain     # машинный формат: device|label|fs|mountpoint|state
ntfs-mount mount disk4s1        # перемонтировать в RW (по id или метке)
ntfs-mount mount all
ntfs-mount unmount disk4s1
ntfs-mount eject disk4s1        # unmount + мягко остановить ntfs-3g + diskutil eject
ntfs-mount auto                 # перемонтировать все NTFS в RW

NTFS_MOUNT_DEBUG=1 ntfs-mount mount disk4s1   # пошаговый trace для диагностики
```

Переформатировать диск, NTFS которого повреждена безнадёжно (стирает всё, спрашивает подтверждение):

```bash
LABEL="MyDrive" bash format-ntfs.sh
```

## Грабли, которые этот проект обходит

Реальные проблемы, на которые мы наступили при разработке — обходы зашиты в скрипты:

| Проблема | Что делают скрипты |
|---|---|
| Homebrew cask `fuse-t` иногда числится установленным, но `.pkg`-инсталлятор так и не запускался | `install.sh` запускает `installer` напрямую, если нет `/usr/local/lib/libfuse-t.dylib` |
| `autoreconf` на `macos-fuse-t/ntfs-3g` кладёт `ltmain.sh` в `..` вместо `.` (LT_INIT спрятан за `m4_ifdef`) | `install.sh` копирует его обратно и перезапускает `autoreconf` |
| Системный bash в macOS — **3.2**: нет associative arrays, нет `printf '%(...)T'`, юникодное многоточие ломает парсинг `$VAR…` | Все скрипты совместимы с bash 3.2 (без `declare -A`, только ASCII рядом с переменными) |
| LaunchDaemon получает `Operation not permitted` на `/dev/diskX` даже от root | `grant-permissions.sh` открывает страницу Full Disk Access в System Settings |
| FSKit на macOS Tahoe молча монтирует каждый NTFS read-only параллельно, блокируя запись | Демон находит паразитные `fskit`/`read-only` маунты и размонтирует их каждый цикл |
| Зомби-процессы `ntfs-3g` переживают отключение USB и держат `/Volumes/<метка>` с устаревшими данными | `mount_one` смотрит `ps -o args=` и убивает ntfs-3g, чей `/dev/diskX` не совпадает с текущим устройством |
| Когда демон работает от root, `$(id -un)` возвращает `root`, и том монтируется с `uid=0` (писать может только root) | `resolve_owner` читает env `NTFS_OWNER_USER`, затем `stat -f '%Su' /dev/console`, затем первый uid≥501 из `dscl` — и отказывается монтировать, если всё равно получился `0` |
| `diskutil info` не показывает mount point для NFS-маунтов FUSE-T | Парсер падает обратно на `/sbin/mount`: по `/dev/diskX`, по `fuse-t:/<метка>`, по догадке `/Volumes/<метка>` |
| `diskutil eject` всегда отвечает «Volume failed to eject», пока жив FUSE-T mount — DiskArbitration просто не видит NFS-маунты | `eject` явно размонтирует FUSE-T mount (в границах метки *этого* диска — второй NTFS-диск не пострадает), шлёт SIGTERM ntfs-3g и затем зовёт `diskutil eject` |
| `set -e` + командная подстановка инструментов, возвращающих non-zero при успехе (`ntfsfix` после replay журнала, `diskutil unmount` несмонтированного пути), молча убивали скрипт посреди функции | Скрипты работают только с `set -uo pipefail`; критичные exit-коды проверяются явно |
| Spotlight и `fseventsd` держат файлы NTFS-тома открытыми — Finder не может удалить в корзину («объект используется») | После каждого монтирования утилита выполняет `mdutil -i off` для тома и создаёт `.fseventsd/no_log` |
| NTFS-тома на macOS незаметно копят повреждения журнала/MFT (родного chkdsk нет) и начинают отказывать в `rmdir` | `ntfs-3g` монтирует с опцией `recover` (replay журнала); при реальном повреждении MFT — `chkdsk /f` на Windows, или `format-ntfs.sh`, если данные не нужны |

## Состав

| Файл | Что это |
|---|---|
| `install.sh` | Ставит FUSE-T pkg, собирает ntfs-3g из исходников, ставит CLI |
| `install-gui.sh` | Компилирует `NTFSMounter.swift` в `~/Applications/NTFSMounter.app`, настраивает LaunchDaemon + LaunchAgent |
| `grant-permissions.sh` | Помогает выдать Full Disk Access для `ntfs-3g` и `/bin/bash` |
| `uninstall-gui.sh` | Удаляет GUI-слой (драйвер/CLI остаются) |
| `format-ntfs.sh` | Безопасное переформатирование диска в свежий NTFS (спрашивает подтверждение `YES`) |
| `ntfs-mount` | bash CLI — mount/unmount/eject/list, отстрел FSKit, чистка зомби, определение владельца |
| `automount-daemon.sh` | Цикл опроса (совместим с bash 3.2) — вызывает `ntfs-mount` при изменении состояния |
| `NTFSMounter.swift` | Приложение в строке меню: `NSStatusBar` + SF Symbol `externaldrive.fill` |
| `com.user.ntfs-automount.plist` | Plist LaunchDaemon (root, KeepAlive) |
| `com.user.ntfsmounter.plist` | Plist LaunchAgent (user, KeepAlive, лог в `~/Library/Logs/NTFSMounter.log`) |

## Производительность

FUSE-T гоняет ввод-вывод через user-space NFS-сервер, поэтому скорость заметно ниже kernel-mode драйверов (macFUSE, Paragon). Ориентир — **20–60 МБ/с** последовательного чтения/записи на USB 3 SSD: достаточно для документов, медиа и файлов среднего размера. Для переливки 100+ ГБ диск-в-диск коммерческие драйверы будут быстрее.

## Ограничения и предостережения

- **Не выдёргивайте кабель.** Всегда извлекайте через меню (или `ntfs-mount eject`). FUSE-T кэширует запись; физическое отключение без синхронизации может повредить журнал NTFS.
- После первой записи на диск, который последний раз трогала Windows со включённым **Fast Startup**, macOS может предложить «проверить диск» — это переключился флаг журнала NTFS. Жмите *Skip* / *Ignore*.
- FSKit-драйвер Apple на macOS Tahoe **будет** постоянно пытаться смонтировать диск параллельно. Демон его отстреливает. Если остановить демон (`sudo launchctl bootout system/com.user.ntfs-automount`), через несколько секунд диск снова станет read-only.
- **На macOS нет полноценного средства починки NTFS.** Идущий в комплекте `ntfsfix` умеет только replay журнала — повреждения уровня MFT он не лечит. Если появились фантомные папки, которые не удаляются с ошибкой `Directory not empty`, — подключите диск к **Windows** и запустите `chkdsk D: /f /r`, либо, если данные не нужны, переформатируйте через `format-ntfs.sh`.
- **Никогда не делайте `kill -9` процессу ntfs-3g вручную.** Жёсткое убийство рвёт NFS-канал FUSE-T на лету, и macOS *физически отключает всё USB-устройство*. Команда `eject` сперва размонтирует и останавливает ntfs-3g мягким SIGTERM — и эскалирует, только если процесс его игнорирует.

## Удаление

```bash
bash uninstall-gui.sh                                # GUI + демон
sudo rm -f /usr/local/bin/ntfs-mount \
           /usr/local/bin/ntfs-3g \
           /usr/local/bin/ntfsfix \
           /usr/local/sbin/mount.ntfs-3g
brew uninstall --cask macos-fuse-t/homebrew-cask/fuse-t
```

## Лицензия

MIT. Сборка ntfs-3g делается из [macos-fuse-t/ntfs-3g](https://github.com/macos-fuse-t/ntfs-3g) (GPL-2.0 + LGPL-2.0). У FUSE-T своя лицензия — см. [его репозиторий](https://github.com/macos-fuse-t/fuse-t).
