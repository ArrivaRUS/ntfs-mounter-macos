#!/usr/bin/env bash
# Полностью переформатирует внешний NTFS-диск через mkntfs (быстрый формат).
# СТИРАЕТ ВСЁ СОДЕРЖИМОЕ -- спрашивает подтверждение "YES".
#
# Использование:
#   bash format-ntfs.sh                  # метка по умолчанию NTFS_DISK
#   LABEL="MyDrive" bash format-ntfs.sh  # своя метка тома
#
# Зачем: на macOS нет полноценного chkdsk; если NTFS-том накопил
# повреждения MFT (см. README), а данные не нужны -- быстрый формат
# возвращает диск в гарантированно чистое состояние за ~10-30 секунд.

set -uo pipefail

LABEL="${LABEL:-NTFS_DISK}"
MARKER_DIR="/var/run/ntfs-mount"

C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_BLUE='\033[0;34m'
C_YELLOW='\033[1;33m'
C_OFF='\033[0m'
log()  { printf "${C_BLUE}==>${C_OFF} %s\n" "$*"; }
ok()   { printf "${C_GREEN}OK${C_OFF}  %s\n" "$*"; }
warn() { printf "${C_YELLOW}!${C_OFF}   %s\n" "$*"; }
die()  { printf "${C_RED}FAIL %s${C_OFF}\n" "$*" >&2; exit 1; }

# === Найти раздел NTFS (или Microsoft Basic Data) ===
DEV="$(diskutil list external 2>/dev/null | awk '/Microsoft Basic Data/ {for(i=NF; i>=1; i--) if ($i ~ /^disk[0-9]+s[0-9]+$/) {print $i; exit}}')"
if [ -z "$DEV" ]; then
  log "Через 'Microsoft Basic Data' не нашёл, пробую через 'Windows_NTFS'"
  DEV="$(diskutil list external 2>/dev/null | awk '/Windows_NTFS/ {for(i=NF; i>=1; i--) if ($i ~ /^disk[0-9]+s[0-9]+$/) {print $i; exit}}')"
fi
if [ -z "$DEV" ]; then
  echo "diskutil list external:"
  diskutil list external
  die "Не нашёл NTFS-раздел. Подключите USB-диск и повторите."
fi
PARENT="${DEV%s*}"
log "Раздел:  /dev/$DEV"
log "Parent:  /dev/$PARENT"
log "Метка:   $LABEL"

# === Подтверждение ===
echo
warn "ВНИМАНИЕ: всё содержимое раздела $DEV будет стёрто без возможности восстановления."
read -r -p "Введите YES чтобы подтвердить: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
  echo "Отменено."
  exit 0
fi

# === 1. marker для демона автомонтирования ===
log "Ставлю marker, чтобы демон не вмешивался"
sudo mkdir -p "$MARKER_DIR" 2>/dev/null || true
sudo touch "$MARKER_DIR/ejecting.$DEV"

# === 2. unmount всего диска ===
log "Размонтирую /dev/$PARENT"
sudo diskutil unmountDisk force "/dev/$PARENT" 2>&1 || true
sleep 1

# === 3. mkntfs ===
MKNTFS="$(command -v mkntfs 2>/dev/null)"
[ -z "$MKNTFS" ] && MKNTFS="$(ls /usr/local/sbin/mkntfs /usr/local/bin/mkntfs 2>/dev/null | head -1)"
[ -x "$MKNTFS" ] || die "mkntfs не найден. Запустите install.sh"
log "mkntfs: $MKNTFS"

log "Быстрый формат (без проверки bad sectors, ~10-30 секунд)"
sudo "$MKNTFS" --fast --label "$LABEL" "/dev/$DEV"
MKNTFS_RC=$?
log "mkntfs exit=$MKNTFS_RC"

if [ "$MKNTFS_RC" -ne 0 ]; then
  warn "mkntfs упал. Снимаю marker, демон попробует смонтировать как обычно."
  sudo rm -f "$MARKER_DIR/ejecting.$DEV"
  exit "$MKNTFS_RC"
fi

# === 4. Снять marker и кикнуть демон ===
log "Снимаю marker, перезапускаю демон"
sudo rm -f "$MARKER_DIR/ejecting.$DEV"
sudo launchctl kickstart -k system/com.user.ntfs-automount 2>/dev/null || true

# === 5. Ждём смонтирования ===
log "Жду 8 секунд, чтобы демон смонтировал свежий том"
sleep 8

echo
log "mount:"
/sbin/mount | grep -F "$LABEL" || warn "Том пока не смонтирован -- проверьте: sudo tail /var/log/ntfs-automount.log"

echo
log "тест записи:"
TEST="/Volumes/$LABEL/.write_test_$$"
if touch "$TEST" 2>/dev/null; then
  rm -f "$TEST"
  ok "ЗАПИСЬ РАБОТАЕТ. Диск чист и готов к использованию."
else
  warn "Запись пока не прошла. Дайте демону ещё несколько секунд и проверьте: ntfs-mount list"
fi
