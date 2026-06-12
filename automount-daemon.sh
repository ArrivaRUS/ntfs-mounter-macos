#!/usr/bin/env bash
# NTFS automount daemon.
# Запускается через LaunchDaemon как root, периодически опрашивает
# список NTFS-разделов и автоматически перемонтирует RO -> RW через ntfs-3g.
#
# Совместим с bash 3.2 (системный bash macOS).
# stdout/stderr -> /var/log/ntfs-automount.log (через LaunchDaemon plist).

set -uo pipefail

NTFS_MOUNT_BIN="${NTFS_MOUNT_BIN:-/usr/local/bin/ntfs-mount}"
OWNER_USER="${NTFS_OWNER_USER:-}"
DEBOUNCE_SEC=2
POLL_SEC=3

# Маркеры «идёт eject» -- root-owned каталог, согласован с ntfs-mount.
MARKER_DIR="/var/run/ntfs-mount"
MARKER_TTL=60

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

if [[ ! -x "$NTFS_MOUNT_BIN" ]]; then
  log "FATAL: $NTFS_MOUNT_BIN не найден"
  exit 1
fi

mkdir -p "$MARKER_DIR" 2>/dev/null || true

log "ntfs-automount-daemon запущен. owner=$OWNER_USER bin=$NTFS_MOUNT_BIN bash=$BASH_VERSION"

# Состояние: одна строка с device-id'ами через пробел, обёрнутая пробелами,
# чтобы проверка вхождения была безопасной (избегаем bash 4 associative arrays).
HANDLED=" "

is_handled()    { [[ "$HANDLED" == *" $1 "* ]]; }
mark_handled()  { is_handled "$1" || HANDLED="$HANDLED$1 "; }
purge_handled() {
  # $1 = строка current ids через пробел, окружённая пробелами
  local current="$1"
  local rebuilt=" "
  local id
  for id in $HANDLED; do
    [[ -z "$id" ]] && continue
    if [[ "$current" == *" $id "* ]]; then
      rebuilt="$rebuilt$id "
    else
      log "Диск $id отключён -- забываю состояние"
    fi
  done
  HANDLED="$rebuilt"
}

# Удаляем eject-маркеры дисков, которых больше нет в системе: пользователь
# извлёк диск -- если он воткнёт его обратно (обычно тот же device id),
# автомонтаж должен сработать сразу, не дожидаясь 60-секундного TTL.
purge_markers() {
  local current="$1"
  local f id
  for f in "$MARKER_DIR"/ejecting.*; do
    [[ -e "$f" ]] || continue
    id="${f##*.}"
    if [[ "$current" != *" $id "* ]]; then
      rm -f "$f" 2>/dev/null
      log "Маркер eject для $id очищен (диск отключён)"
    fi
  done
}

while :; do
  # Машинный вывод: device|label|fs|mountpoint|state (state: RW/RO/пусто).
  # Устойчив к пробелам в метках томов в отличие от человекочитаемой таблицы.
  rows="$("$NTFS_MOUNT_BIN" list --porcelain 2>/dev/null || true)"

  # Собираем список текущих NTFS device-id'ов
  current_ids=" "
  while IFS='|' read -r id _ _ _ _; do
    [[ -n "$id" ]] && current_ids="$current_ids$id "
  done <<< "$rows"

  purge_handled "$current_ids"
  purge_markers "$current_ids"

  # Обрабатываем по строкам (используются только id и state; средние
  # поля label/fs/mountpoint читаем в заглушки для корректного сплита)
  while IFS='|' read -r id _label _fs _mp state; do
    [[ -z "$id" ]] && continue

    # Уважаем свежий marker от eject: пользователь явно попросил извлечь
    marker="$MARKER_DIR/ejecting.$id"
    if [[ -f "$marker" ]]; then
      mtime="$(stat -f '%m' "$marker" 2>/dev/null || echo 0)"
      now="$(date +%s)"
      if [[ $((now - mtime)) -lt "$MARKER_TTL" ]]; then
        continue
      fi
      rm -f "$marker" 2>/dev/null
    fi

    if is_handled "$id"; then
      continue
    fi

    # Кейсы:
    #   RW    -> уже наш ntfs-3g. Но Apple FSKit может в любой момент
    #            подмонтировать свой read-only паразитный mount поверх --
    #            его нужно периодически отстреливать.
    #   RO    -> Apple FSKit смонтировал в read-only, перемонтируем.
    #   пусто -> диск не смонтирован вовсе. Монтируем сами через ntfs-3g.
    if [[ "$state" == "RW" ]]; then
      # Проактивная чистка: нет ли паразитных fskit-маунтов на том же /dev/$id
      if /sbin/mount 2>/dev/null | awk -v dev="/dev/$id" '$1 == dev' | grep -q "fskit\|read-only"; then
        log "[$id] обнаружен паразитный FSKit-mount поверх RW -- зачищаю"
        NTFS_OWNER_USER="$OWNER_USER" NTFS_MOUNT_DEBUG=1 "$NTFS_MOUNT_BIN" mount "$id" 2>&1 | sed "s/^/[$id] /"
      fi
      mark_handled "$id"
      continue
    fi

    reason="не смонтирован"
    [[ "$state" == "RO" ]] && reason="смонтирован RO"

    log "NTFS $id ($reason) -- жду ${DEBOUNCE_SEC}s и монтирую через ntfs-3g"
    sleep "$DEBOUNCE_SEC"

    # Логируем ВЕСЬ вывод (stdout+stderr) ntfs-mount во временный файл,
    # затем кладём в лог построчно с префиксом [id]. Сохраняем exit-code
    # самого ntfs-mount.
    mount_out="$(mktemp /tmp/ntfs-mount-out.XXXXXX)"
    NTFS_OWNER_USER="$OWNER_USER" NTFS_MOUNT_DEBUG=1 "$NTFS_MOUNT_BIN" mount "$id" >"$mount_out" 2>&1
    mount_rc=$?
    sed "s/^/[$id] /" "$mount_out"
    rm -f "$mount_out"

    if [ "$mount_rc" -eq 0 ]; then
      log "OK: $id смонтирован в RW"
      mark_handled "$id"
    else
      log "FAIL($mount_rc): не удалось смонтировать $id -- повторю в следующем цикле"
    fi
  done <<< "$rows"

  sleep "$POLL_SEC"
done
