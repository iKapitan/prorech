#!/bin/bash
# ПРОРЕЧЬ, транскрибация от Kirov Pro: установка одной командой.
#
#   curl -fsSL https://raw.githubusercontent.com/iKapitan/prorech/main/install.sh | bash
#
# Ставит приложение в «Программы», а Python и модели в папку пользователя
# ~/Library/Application Support/KirovPro/Prorech. Homebrew, пароль
# администратора и правка системных файлов не нужны.

set -euo pipefail

# Всё тело в функции: bash дочитывает скрипт из curl целиком до первой команды.
main() {
  local repo="iKapitan/prorech"
  echo
  echo "ПРОРЕЧЬ, транскрибация от Kirov Pro"
  echo

  if [ "$(uname -s)" != "Darwin" ]; then
    echo "Нужен мак."; exit 1
  fi
  local ver major
  ver="$(sw_vers -productVersion)"
  major="${ver%%.*}"
  if [ "$major" -lt 13 ]; then
    echo "Нужна macOS 13 или новее, у вас $ver."; exit 1
  fi

  # Глобальная, а не local: ловушка EXIT срабатывает уже после выхода из main.
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR:-}"' EXIT
  local tmp="$TMP_DIR"

  echo "1/2 Скачиваю приложение"
  curl -fsSL -o "$tmp/app.zip" "https://github.com/$repo/releases/latest/download/Prorech.zip" </dev/null
  ditto -x -k "$tmp/app.zip" "$tmp"

  local dest="/Applications"
  [ -w "$dest" ] || dest="$HOME/Applications"
  mkdir -p "$dest"
  rm -rf "$dest/ПРОРЕЧЬ.app"
  mv "$tmp/ПРОРЕЧЬ.app" "$dest/"
  xattr -dr com.apple.quarantine "$dest/ПРОРЕЧЬ.app" 2>/dev/null || true

  echo "2/2 Ставлю движок и модели, около 400 МБ"
  bash "$dest/ПРОРЕЧЬ.app/Contents/Resources/setup-engine.sh" </dev/null \
    | while IFS= read -r line; do
        case "$line" in
          "@шаг "*) echo "    ${line#@шаг }" ;;
          "@ошибка "*) echo "Ошибка: ${line#@ошибка }" ;;
        esac
      done

  echo
  echo "Готово. ПРОРЕЧЬ лежит в папке $dest, открываю."
  open "$dest/ПРОРЕЧЬ.app"
}

main "$@"
