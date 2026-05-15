#!/usr/bin/env bash
# Помощник: даёт Full Disk Access для ntfs-3g (нужно демону, чтобы открывать
# /dev/diskX без "Operation not permitted").

set -uo pipefail

C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_OFF='\033[0m'

cat <<'EOF'
─────────────────────────────────────────────────────────────────────
Зачем это нужно
─────────────────────────────────────────────────────────────────────
macOS блокирует прямой доступ к /dev/diskX (raw-устройства)
даже для root-процессов, если им не выдан Full Disk Access (FDA).

Ваш LaunchDaemon (фон) запущен от root, но БЕЗ FDA -- поэтому
монтирование падает: "Operation not permitted".
Когда вы запускаете "sudo ntfs-mount mount ..." из Terminal -- работает,
потому что Terminal.app сам имеет FDA и наследует его в sudo-процесс.

Нужно ОДИН РАЗ выдать FDA двум файлам:
   1) /bin/bash                  (это интерпретатор демон-скрипта)
   2) /usr/local/bin/ntfs-3g     (бинарник, открывающий /dev/diskX)

─────────────────────────────────────────────────────────────────────
Что сделать
─────────────────────────────────────────────────────────────────────
Сейчас откроется страница System Settings.

В правой части страницы:
   - Нажмите кнопку "+" (или иконку добавления)
   - В диалоге выбора файла нажмите Cmd+Shift+G
   - Введите путь:           /usr/local/bin/ntfs-3g
   - Нажмите Open и переключите тумблер в ON
   - Повторите для пути:     /bin/bash
   - macOS попросит ввести пароль / Touch ID -- подтвердите

Когда оба пункта включены, вернитесь в терминал и нажмите Enter.
─────────────────────────────────────────────────────────────────────
EOF

# Открываем нужную страницу System Settings
open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles" 2>/dev/null \
  || open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null \
  || open "/System/Library/PreferencePanes/Security.prefPane"

echo
read -p "Нажмите Enter после того, как добавите оба файла в Full Disk Access... " _

echo
printf "${C_BLUE}==>${C_OFF} Перезапускаю automount-daemon\n"
sudo launchctl kickstart -k system/com.user.ntfs-automount

echo
printf "${C_BLUE}==>${C_OFF} Жду 6 секунд (на цикл демона)\n"
sleep 6

echo
printf "${C_BLUE}==>${C_OFF} Свежий лог демона:\n"
sudo tail -20 /var/log/ntfs-automount.log

echo
printf "${C_BLUE}==>${C_OFF} Состояние NTFS-дисков:\n"
/usr/local/bin/ntfs-mount list

echo
printf "${C_GREEN}OK${C_OFF}  Если в логе нет 'Operation not permitted' и диск показывает [RW] -- готово.\n"
printf "${C_YELLOW}!${C_OFF}   Если ошибка осталась -- проверьте, что в FDA включены ОБА файла и тумблеры в ON.\n"
