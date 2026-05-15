#!/usr/bin/env bash
# Установщик FUSE-T + NTFS-3G на macOS (Apple Silicon, без kernel extensions).
# Не требует Reduced Security, не использует kext.
#
# Запуск:
#   bash ~/ntfs-utility/install.sh
# (пароль sudo будет запрошен на шагах установки cask и `make install`)

set -euo pipefail

C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_BLUE='\033[0;34m'
C_OFF='\033[0m'

log()   { printf "${C_BLUE}==>${C_OFF} %s\n" "$*"; }
ok()    { printf "${C_GREEN}✓${C_OFF}  %s\n" "$*"; }
warn()  { printf "${C_YELLOW}!${C_OFF}  %s\n" "$*"; }
die()   { printf "${C_RED}✗ %s${C_OFF}\n" "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "Этот скрипт только для macOS."

# 1. Homebrew
if ! command -v brew >/dev/null 2>&1; then
  die "Homebrew не установлен. Установите: https://brew.sh"
fi
ok "Homebrew найден: $(brew --prefix)"

# 2. FUSE-T
# Cask `fuse-t` иногда «успешно» завершается, но не запускает installer.
# Поэтому: качаем pkg через cask, затем явно прогоняем installer от sudo.
if [[ -f /usr/local/lib/libfuse-t.dylib ]] && [[ -f /usr/local/include/fuse/fuse.h ]]; then
  ok "FUSE-T уже установлен (dylib и headers на месте)"
else
  log "Скачиваю FUSE-T pkg через brew cask..."
  brew tap macos-fuse-t/homebrew-cask >/dev/null 2>&1 || true
  brew install --cask macos-fuse-t/homebrew-cask/fuse-t || true

  PKG_PATH="$(ls -1 "$(brew --prefix)"/Caskroom/fuse-t/*/fuse-t-macos-installer-*.pkg 2>/dev/null | head -1)"
  if [[ -z "$PKG_PATH" || ! -f "$PKG_PATH" ]]; then
    die "Не нашёл fuse-t pkg в Caskroom. Скачайте вручную: https://github.com/macos-fuse-t/fuse-t/releases"
  fi
  log "Запускаю pkg-инсталлятор FUSE-T: $PKG_PATH"
  log "(потребуется пароль sudo)"
  sudo installer -pkg "$PKG_PATH" -target / -verboseR

  # Проверяем результат
  if [[ ! -f /usr/local/lib/libfuse-t.dylib ]] || [[ ! -f /usr/local/include/fuse/fuse.h ]]; then
    cat <<'EOF'

╔══════════════════════════════════════════════════════════════════╗
║ FUSE-T pkg прошёл, но dylib/headers не появились.                ║
║                                                                  ║
║ macOS Tahoe (26.x) использует FSKit — system extension должна    ║
║ быть активирована вручную:                                       ║
║                                                                  ║
║   System Settings → General → Login Items & Extensions →         ║
║   File System Extensions → включить FUSE-T                       ║
║                                                                  ║
║ Также возможно потребуется:                                      ║
║   System Settings → Privacy & Security → разрешить FUSE-T        ║
║                                                                  ║
║ После этого перезапустите этот скрипт.                           ║
╚══════════════════════════════════════════════════════════════════╝
EOF
    die "FUSE-T не полностью активирован"
  fi
  ok "FUSE-T установлен"
fi

# 3. Build dependencies
log "Устанавливаю инструменты сборки через brew."
brew install --quiet autoconf automake libtool pkg-config gettext libgcrypt gnutls
ok "Build-зависимости установлены"

# 4. Клонируем ntfs-3g (fork для FUSE-T)
SRC_DIR="$HOME/ntfs-utility/ntfs-3g-src"
if [[ -d "$SRC_DIR/.git" ]]; then
  log "Обновляю существующий клон ntfs-3g и сбрасываю в чистое состояние..."
  git -C "$SRC_DIR" fetch --all --quiet
  git -C "$SRC_DIR" reset --hard origin/HEAD --quiet
  git -C "$SRC_DIR" clean -fdx --quiet
else
  log "Клонирую macos-fuse-t/ntfs-3g..."
  rm -rf "$SRC_DIR"
  git clone --depth=1 https://github.com/macos-fuse-t/ntfs-3g.git "$SRC_DIR"
fi
# На всякий случай удалим случайно созданный ltmain.sh в родительском каталоге
rm -f "$HOME/ntfs-utility/ltmain.sh"
ok "Исходники готовы: $SRC_DIR"

# 5. Сборка
log "Конфигурирую и собираю ntfs-3g..."
cd "$SRC_DIR"

# FUSE-T кладёт dylib в /usr/local — даже на Apple Silicon.
export CPPFLAGS="-I/usr/local/include/fuse"
export LDFLAGS="-L/usr/local/lib -lfuse-t -Wl,-rpath,/usr/local/lib"

# Запускаем autogen.sh. Он почти отработает, но automake упадёт на отсутствии
# ./ltmain.sh: новый glibtoolize кладёт его в parent (потому что LT_INIT в
# configure.ac спрятан под m4_ifdef). Не считаем падение фатальным,
# чиним вручную и перезапускаем autoreconf.
./autogen.sh || true
if [[ ! -f ./ltmain.sh && -f ../ltmain.sh ]]; then
  warn "Применяю обход: копирую ltmain.sh из родительского каталога..."
  cp ../ltmain.sh ./ltmain.sh
  autoreconf --install --force
fi
rm -f ../ltmain.sh

[[ -x ./configure ]] || die "configure не сгенерирован — сборка не может продолжиться"

./configure \
  --prefix=/usr/local \
  --exec-prefix=/usr/local \
  --sbindir=/usr/local/sbin \
  --bindir=/usr/local/bin \
  --with-fuse=external \
  --disable-ldconfig

make -j"$(sysctl -n hw.ncpu)"
ok "Сборка завершена"

# 6. Установка (sudo)
log "Устанавливаю ntfs-3g в /usr/local (требуется sudo)..."
sudo make install
ok "ntfs-3g установлен: $(command -v ntfs-3g || echo '/usr/local/bin/ntfs-3g')"

# 7. Установка утилиты ntfs-mount в /usr/local/bin
UTIL_SRC="$HOME/ntfs-utility/ntfs-mount"
if [[ -f "$UTIL_SRC" ]]; then
  log "Устанавливаю утилиту ntfs-mount в /usr/local/bin..."
  sudo install -m 0755 "$UTIL_SRC" /usr/local/bin/ntfs-mount
  ok "Утилита установлена: ntfs-mount"
else
  warn "Файл $UTIL_SRC не найден — пропускаю установку CLI-утилиты."
fi

echo
ok "Готово!"
cat <<'EOF'

Дальнейшие шаги
───────────────
1. Подключите NTFS-диск.
2. Посмотрите список NTFS-разделов:
       ntfs-mount list
3. Перемонтируйте нужный в режиме чтения-записи:
       ntfs-mount mount <disk>     # напр. disk4s1
   или перемонтируйте всё разом:
       ntfs-mount auto
4. Безопасно отключить:
       ntfs-mount unmount <disk>

Подсказка: после первой записи macOS может предложить «проверить диск» —
это нормально, NTFS journal обновился. Игнорируйте или нажмите Skip.
EOF
