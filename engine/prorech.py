#!/usr/bin/env python3
# ПРОРЕЧЬ, транскрибация от Kirov Pro: локальное распознавание русской речи с разметкой
# говорящих. Интернет не нужен. Распознавание GigaAM v2 (Сбер), разделение
# по голосам pyannote segmentation 3.0 плюс TitaNet, всё через sherpa-onnx.
#
# Запуск: python prorech.py [-n ГОВОРЯЩИХ] [-t ПОРОГ] файл [файл ...]
# Результат ложится рядом с аудио: встреча.m4a даёт встреча.txt.
# Флаг --progress печатает служебные строки для приложения:
#   @голоса 0.42     доля пройденного разделения по голосам
#   @текст 0.80      доля распознанных реплик
#   @готово ПУТЬ     готовый текст
#   @ошибка ТЕКСТ    что пошло не так

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import wave

import numpy as np
import sherpa_onnx

HOME = os.environ.get("PRORECH_HOME") or os.path.expanduser(
    "~/Library/Application Support/KirovPro/Prorech")
HERE = os.path.dirname(os.path.abspath(__file__))
# Модели ищутся в папке установки, а рядом со скриптом на случай ручного запуска.
MODEL_DIRS = [os.path.join(HOME, "models"), os.path.join(HERE, "models")]

PROGRESS = False


def emit(tag, value):
    if PROGRESS:
        print(f"@{tag} {value}", flush=True)


def say(text):
    if not PROGRESS:
        print(text, flush=True)


def find_one(pattern):
    for d in MODEL_DIRS:
        hits = sorted(glob.glob(os.path.join(d, pattern)))
        if hits:
            return hits[0]
    raise FileNotFoundError(f"не найдена модель {pattern}, переустановите программу")


def find_ffmpeg():
    for p in (shutil.which("ffmpeg"), "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"):
        if p and os.path.exists(p):
            return p
    return None


def to_samples(path):
    """Любая запись в 16 кГц моно. Сначала встроенный в macOS afconvert
    (mp3, m4a, wav, aiff, caf), если не справился, то ffmpeg, если он есть."""
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "in.wav")
        done = False
        if shutil.which("afconvert"):
            r = subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                                path, wav], capture_output=True)
            done = r.returncode == 0 and os.path.exists(wav) and os.path.getsize(wav) > 44
        if not done:
            ff = find_ffmpeg()
            if not ff:
                raise ValueError("этот формат macOS не читает сам: сохраните запись в m4a, mp3 или wav")
            r = subprocess.run([ff, "-nostdin", "-v", "error", "-i", path, "-ar", "16000",
                                "-ac", "1", "-c:a", "pcm_s16le", wav, "-y"], capture_output=True)
            if r.returncode != 0:
                raise ValueError("не удалось прочитать звук из файла")
        with wave.open(wav, "rb") as w:
            data = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    return data.astype(np.float32) / 32768.0


def fmt(sec):
    s = int(sec)
    if s >= 3600:
        return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}"
    return f"{s // 60:02d}:{s % 60:02d}"


def load_zameny():
    """Пары «как слышится = как писать» из zameny.txt в папке установки."""
    pairs = []
    for path in (os.path.join(HOME, "zameny.txt"), os.path.join(HERE, "zameny.txt")):
        if not os.path.exists(path):
            continue
        for ln in open(path, encoding="utf-8"):
            ln = ln.strip()
            if ln and not ln.startswith("#") and "=" in ln:
                a, b = (x.strip() for x in ln.split("=", 1))
                if a and b:
                    pairs.append((a, b))
        break
    return pairs


def load_recognizer():
    mdir = find_one("sherpa-onnx-nemo-transducer-giga-am*")
    return sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=glob.glob(f"{mdir}/encoder*.onnx")[0],
        decoder=glob.glob(f"{mdir}/decoder*.onnx")[0],
        joiner=glob.glob(f"{mdir}/joiner*.onnx")[0],
        tokens=f"{mdir}/tokens.txt",
        model_type="nemo_transducer", num_threads=os.cpu_count() or 4)


def load_diarizer(n_speakers, threshold):
    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                model=find_one("sherpa-onnx-pyannote-segmentation-3-0/model.onnx"))),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=find_one("titanet.onnx")),
        clustering=sherpa_onnx.FastClusteringConfig(num_clusters=n_speakers,
                                                    threshold=threshold),
        min_duration_on=0.3, min_duration_off=0.5)
    return sherpa_onnx.OfflineSpeakerDiarization(config)


def transcribe(path, rec, sd, pairs):
    t0 = time.time()
    samples = to_samples(path)
    minutes = len(samples) / 16000 / 60

    def on_chunk(done, total):
        emit("голоса", f"{done / max(total, 1):.3f}")
        return 0

    segs = sd.process(samples, callback=on_chunk).sort_by_start_time()

    # Буквы по порядку появления: кто заговорил первым, тот A.
    letters = "ABCDEFGHIJKL"
    order = {}
    for seg in segs:
        order.setdefault(seg.speaker, letters[len(order) % len(letters)])

    lines = []
    for i, seg in enumerate(segs):
        # Модель берёт до 25 секунд за раз, длинная реплика режется на куски.
        texts = []
        pos = seg.start
        while pos < seg.end:
            end = min(pos + 25.0, seg.end)
            chunk = samples[int(pos * 16000):int(end * 16000)]
            if len(chunk) > 1600:
                st = rec.create_stream()
                st.accept_waveform(16000, chunk)
                rec.decode_stream(st)
                if st.result.text.strip():
                    texts.append(st.result.text.strip())
            pos = end
        if texts:
            lines.append(f"[{fmt(seg.start)}] Говорящий {order[seg.speaker]}: "
                         + " ".join(texts))
        emit("текст", f"{(i + 1) / max(len(segs), 1):.3f}")

    for a, b in pairs:
        lines = [re.sub(re.escape(a), b, ln, flags=re.I) for ln in lines]

    out = os.path.splitext(path)[0] + ".txt"
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    emit("готово", out)
    say(f"готово: {out} (запись {minutes:.1f} мин, говорящих {len(order)}, "
        f"за {time.time() - t0:.0f} с)")


def main():
    global PROGRESS
    p = argparse.ArgumentParser(description="ПРОРЕЧЬ, транскрибация от Kirov Pro: локально, с говорящими")
    p.add_argument("files", nargs="+", help="аудиофайлы: m4a, mp3, wav, aiff")
    p.add_argument("-n", type=int, default=-1,
                   help="сколько человек говорит, если известно")
    p.add_argument("-t", type=float, default=1.2,
                   help="порог разделения голосов, по умолчанию 1.2")
    p.add_argument("--progress", action="store_true", help="служебные строки для приложения")
    args = p.parse_args()
    PROGRESS = args.progress

    say("загружаю модели...")
    try:
        rec = load_recognizer()
        sd = load_diarizer(args.n, args.t)
    except FileNotFoundError as e:
        emit("ошибка", e)
        say(str(e))
        sys.exit(2)
    pairs = load_zameny()

    failed = 0
    for path in args.files:
        if not os.path.isfile(path):
            emit("ошибка", f"нет файла {path}")
            say(f"нет файла: {path}")
            failed += 1
            continue
        say(f"расшифровываю {os.path.basename(path)}")
        try:
            transcribe(path, rec, sd, pairs)
        except (ValueError, OSError) as e:
            emit("ошибка", e)
            say(f"{os.path.basename(path)}: {e}")
            failed += 1
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
