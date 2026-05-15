#!/usr/bin/env bash
# Полное удаление GUI-части NTFS-утилиты (демон + menu-bar app + sudoers).
# Сам ntfs-3g и FUSE-T этот скрипт НЕ трогает.

set -uo pipefail
log()  { printf "==> %s\n" "$*"; }
ok()   { printf "✓  %s\n" "$*"; }

# 1. LaunchAgent (menu-bar app)
AGENT_PLIST="$HOME/Library/LaunchAgents/com.user.ntfsmounter.plist"
if [[ -f "$AGENT_PLIST" ]]; then
  log "Останавливаю menu-bar агент..."
  launchctl bootout "gui/$(id -u)/com.user.ntfsmounter" 2>/dev/null || true
  rm -f "$AGENT_PLIST"
  ok "Агент удалён"
fi

# 2. App bundle
APP_DIR="$HOME/Applications/NTFSMounter.app"
[[ -d "$APP_DIR" ]] && rm -rf "$APP_DIR" && ok "Удалено: $APP_DIR"

# 3. LaunchDaemon (автомонтирование)
DAEMON_PLIST="/Library/LaunchDaemons/com.user.ntfs-automount.plist"
if [[ -f "$DAEMON_PLIST" ]]; then
  log "Останавливаю automount-daemon..."
  sudo launchctl bootout system "$DAEMON_PLIST" 2>/dev/null || true
  sudo rm -f "$DAEMON_PLIST" /usr/local/libexec/ntfs-automount-daemon.sh
  ok "Демон удалён"
fi

# 4. Sudoers
SUDOERS_FILE="/private/etc/sudoers.d/ntfs-mounter"
[[ -f "$SUDOERS_FILE" ]] && sudo rm -f "$SUDOERS_FILE" && ok "Удалено: $SUDOERS_FILE"

# 5. Логи
sudo rm -f /var/log/ntfs-automount.log
rm -f "$HOME/Library/Logs/NTFSMounter.log"

ok "GUI-часть удалена. ntfs-3g и FUSE-T остались (удалите вручную, если нужно)."
