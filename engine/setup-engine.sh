#!/bin/bash
# ПРОРЕЧЬ, транскрибация от Kirov Pro: установка движка и моделей.
#
# Всё ложится в одну папку пользователя, систему не трогает: ни Homebrew,
# ни пароля администратора, ни правки профиля оболочки. Python ставит uv
# в ту же папку. Повторный запуск докачивает только недостающее.
# Строки «@шаг ...» и «@готово» читает приложение, человеку они тоже понятны.

set -euo pipefail

DIR="${PRORECH_HOME:-$HOME/Library/Application Support/KirovPro/Prorech}"
REL="https://github.com/k2-fsa/sherpa-onnx/releases/download"
SHERPA_VERSION="1.13.8"
GIGAAM="sherpa-onnx-nemo-transducer-giga-am-v2-russian-2025-04-19"
SEG="sherpa-onnx-pyannote-segmentation-3-0"

shag() { echo "@шаг $1"; }
oshibka() { echo "@ошибка $1"; exit 1; }

mkdir -p "$DIR/models"
cd "$DIR"
export UV_PYTHON_INSTALL_DIR="$DIR/python" UV_CACHE_DIR="$DIR/.cache"

shag "Скачиваю Python"
if [ ! -x bin/uv ]; then
  curl -fsSL https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR="$DIR/bin" UV_NO_MODIFY_PATH=1 sh >/dev/null 2>&1 \
    || oshibka "не удалось скачать установщик Python, проверьте интернет"
fi
if [ ! -x venv/bin/python ]; then
  bin/uv venv -q --python 3.12 venv || oshibka "не удалось поставить Python"
fi

shag "Ставлю библиотеки распознавания"
bin/uv pip install -q --python venv/bin/python "sherpa-onnx==$SHERPA_VERSION" numpy \
  || oshibka "не удалось поставить библиотеки, проверьте интернет"

# Модель скачивается во временный файл и принимается только с верной контрольной суммой.
skachat() {  # имя-файла ссылка sha256
  curl -fL --retry 3 -# -o "models/$1.part" "$2" || oshibka "не удалось скачать $1"
  echo "$3  models/$1.part" | shasum -a 256 -c --status || {
    rm -f "models/$1.part"; oshibka "файл $1 скачался битым, запустите установку ещё раз"; }
  mv "models/$1.part" "models/$1"
}

if [ ! -f "models/$GIGAAM/tokens.txt" ]; then
  shag "Скачиваю модель распознавания речи, 172 МБ"
  skachat gigaam.tar.bz2 "$REL/asr-models/$GIGAAM.tar.bz2" \
    6c4bec4c4a70961fc4ec583bf5506089480a9a649c1816ef96b6e4fb8338cd71
  tar xjf models/gigaam.tar.bz2 -C models && rm models/gigaam.tar.bz2
fi

if [ ! -f "models/$SEG/model.onnx" ]; then
  shag "Скачиваю модель отрезков речи, 7 МБ"
  skachat seg.tar.bz2 "$REL/speaker-segmentation-models/$SEG.tar.bz2" \
    24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488
  tar xjf models/seg.tar.bz2 -C models && rm models/seg.tar.bz2
fi

if [ ! -f models/titanet.onnx ]; then
  shag "Скачиваю модель голосов, 40 МБ"
  skachat titanet.onnx "$REL/speaker-recongition-models/nemo_en_titanet_small.onnx" \
    ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e
fi

if [ ! -f zameny.txt ]; then
  cat > zameny.txt <<'EOF'
# Словарь замен. Строка на замену: как слышится = как писать.
# Замены применяются к готовому тексту, без учёта регистра.
# присейл = пресейл
# джира = Jira
EOF
fi

rm -rf "$DIR/.cache"
echo "@готово"
