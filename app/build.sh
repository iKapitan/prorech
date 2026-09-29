#!/bin/bash
# Сборка «ПРОРЕЧЬ.app» для маков на Apple Silicon и Intel.
# Нужен Xcode. Результат: dist/ПРОРЕЧЬ.app и dist/Prorech.zip для релиза.

set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/ПРОРЕЧЬ.app"
rm -rf dist build && mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos13.0" \
    -o "build/Prorech-$arch" app/Sources/main.swift
done
lipo -create build/Prorech-arm64 build/Prorech-x86_64 \
  -output "$APP/Contents/MacOS/Prorech"

cp app/Info.plist "$APP/Contents/"
cp icon/AppIcon.icns engine/prorech.py engine/setup-engine.sh "$APP/Contents/Resources/"

# Подпись без сертификата разработчика: macOS на Apple Silicon не запускает
# неподписанный код вовсе. Приложение, скачанное установщиком через curl,
# Gatekeeper не останавливает.
codesign --force --deep --sign - "$APP"

ditto -c -k --keepParent "$APP" dist/Prorech.zip
rm -rf build
echo "собрано: $APP и dist/Prorech.zip"
