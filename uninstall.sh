#!/bin/bash
# ПРОРЕЧЬ, транскрибация от Kirov Pro: удаление приложения, Python и моделей.
# Готовые тексты рядом с записями остаются на месте.
#
#   curl -fsSL https://raw.githubusercontent.com/iKapitan/prorech/main/uninstall.sh | bash

set -uo pipefail

osascript -e 'quit app id "pro.kirov.prorech"' 2>/dev/null
rm -rf "/Applications/ПРОРЕЧЬ.app" "$HOME/Applications/ПРОРЕЧЬ.app"
rm -rf "$HOME/Library/Application Support/KirovPro/Prorech"
rmdir "$HOME/Library/Application Support/KirovPro" 2>/dev/null
defaults delete pro.kirov.prorech 2>/dev/null
rm -rf "$HOME/Library/Saved Application State/pro.kirov.prorech.savedState"
echo "ПРОРЕЧЬ удалена."
