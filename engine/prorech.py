#!/usr/bin/env python3
# ПРОРЕЧЬ, транскрибация от Kirov Pro: локальное распознавание русской речи с разметкой
# говорящих. Интернет не нужен. Распознавание GigaAM v3 со знаками препинания
# (Сбер) кусками между паузами (Silero VAD), разделение по голосам pyannote
# segmentation 3.0 плюс TitaNet, всё через sherpa-onnx.
#
# Запуск: python prorech.py [-n ГОВОРЯЩИХ] [-t ПОРОГ] файл [файл ...]
# Результат ложится рядом с аудио: встреча.m4a даёт встреча.txt.
# Флаг --progress печатает служебные строки для приложения:
#   @длина 754.2     длина записи в секундах
#   @голоса 0.42     доля пройденного разделения по голосам
#   @текст 0.80      доля распознанных реплик
#   @готово ПУТЬ     готовый текст
#   @ошибка ТЕКСТ    что пошло не так

import argparse
import bisect
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
# v3 со знаками сменила v2 в версии 1.1: вдвое быстрее, находит больше речи,
# пишет латиницу, цифры и знаки препинания. Имя папки то же в setup-engine.sh
# и в приложении (Paths.gigaam).
GIGAAM = "sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16"

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
    mdir = find_one(GIGAAM)
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


# Текст распознаётся по паузам, а не по разметке говорящих (с версии 1.2): так
# фраза одного человека не рвётся между двумя, а места, где голоса накладываются,
# не распознаются дважды. Говорящий меняется только на границе предложения или
# в паузе: фраза отдаётся тому, кто произнёс большую её часть.
PAUSE = 1.0       # пауза между словами, после которой фраза считается новой
CHAR_SEC = 0.07   # примерная длительность буквы: время есть только у начала слова
LINE_SEC = 60.0   # длиннее строки монолог переносится на следующую
CHUNK_MAX = 25.0  # модель берёт не больше 25-30 с, длинный кусок делится поровну
END = re.compile(r"[.?!…]$")
HEAD = re.compile(r"^(\[[0-9:]+\] Говорящий [A-Z]: )(.*)$")
LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"


def speech_chunks(samples):
    """Куски речи между паузами: [(начало в секундах, звук)]."""
    cfg = sherpa_onnx.VadModelConfig()
    cfg.silero_vad.model = find_one("silero_vad.onnx")
    # Порог ниже обычного 0.5: тихую речь с диктофона на столе поиск пауз
    # иначе принимает за тишину.
    cfg.silero_vad.threshold = 0.15
    cfg.silero_vad.min_silence_duration = 0.3
    cfg.silero_vad.min_speech_duration = 0.25
    cfg.silero_vad.max_speech_duration = 20
    cfg.sample_rate = 16000
    vad = sherpa_onnx.VoiceActivityDetector(cfg, buffer_size_in_seconds=60)
    win = cfg.silero_vad.window_size
    out = []

    def drain():
        while not vad.empty():
            start = vad.front.start / 16000
            audio = np.array(vad.front.samples, dtype=np.float32)
            vad.pop()
            parts = int(np.ceil(len(audio) / 16000 / CHUNK_MAX))
            step = int(np.ceil(len(audio) / parts))
            for k in range(parts):
                out.append((start + k * step / 16000, audio[k * step:(k + 1) * step]))

    for i in range(0, len(samples), win):
        vad.accept_waveform(samples[i:i + win])
        drain()
    vad.flush()
    drain()
    return out


def recognize(samples, rec):
    """Слова записи: [(время начала, слово)] по порядку."""
    chunks = speech_chunks(samples)
    words = []
    for i, (start, chunk) in enumerate(chunks):
        st = rec.create_stream()
        st.accept_waveform(16000, chunk)
        rec.decode_stream(st)
        first = True
        for tok, ts in zip(st.result.tokens, st.result.timestamps):
            if first or tok.startswith(" "):
                words.append([start + ts, tok.strip()])
                first = False
            else:
                words[-1][1] += tok
        emit("текст", f"{(i + 1) / max(len(chunks), 1):.3f}")
    return [(t, w) for t, w in words if w]


def speaker_at(segs, starts, max_len, t):
    """Говорящий в момент слова; при наложении перебивающий; вне отрезков
    ближайший в пределах секунды."""
    lo = bisect.bisect_left(starts, t - max_len - 1.0)
    hi = bisect.bisect_right(starts, t + 1.0)
    best, gap = None, 1.0
    for a, b, s in segs[lo:hi]:
        if a <= t <= b:
            if best is None or gap > 0 or a > best[0]:
                best, gap = (a, s), 0
        else:
            d = a - t if t < a else t - b
            if d < gap:
                best, gap = (a, s), d
    return best[1] if best else None


def phrases(words):
    """Фразы: по точке, вопросу, восклицанию, паузе; без знаков не длиннее минуты."""
    out, cur = [], []
    for k, (t, w) in enumerate(words):
        prev_t, prev_w = words[k - 1] if k else (t, "")
        if cur and (t - prev_t - CHAR_SEC * len(prev_w) > PAUSE
                    or t - words[cur[0]][0] > LINE_SEC):
            out.append(cur)
            cur = []
        cur.append(k)
        if END.search(w):
            out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    return out


def apply_zameny(lines, pairs):
    """Замены только в тексте реплики, с начала слова (окончание любое: пара
    «присейл = пресейл» чинит и «присейла»), длинные первыми; правая часть
    подставляется как есть."""
    rules = [(re.compile(r"(?<!\w)" + re.escape(a), re.I), b)
             for a, b in sorted(pairs, key=lambda p: -len(p[0]))]
    out = []
    for ln in lines:
        m = HEAD.match(ln)
        head, text = (m.group(1), m.group(2)) if m else ("", ln)
        for rx, b in rules:
            text = rx.sub(lambda _: b, text)
        out.append(head + text)
    return out


def transcribe(path, rec, sd, pairs):
    t0 = time.time()
    samples = to_samples(path)
    minutes = len(samples) / 16000 / 60
    emit("длина", f"{len(samples) / 16000:.1f}")

    def on_chunk(done, total):
        emit("голоса", f"{done / max(total, 1):.3f}")
        return 0

    segs = [(x.start, x.end, x.speaker)
            for x in sd.process(samples, callback=on_chunk).sort_by_start_time()]
    words = recognize(samples, rec)
    if segs and not words:
        raise ValueError("не удалось распознать речь в записи")

    starts = [a for a, _, _ in segs]
    max_len = max((b - a for a, b, _ in segs), default=0.0)
    who = [speaker_at(segs, starts, max_len, t) for t, _ in words]
    groups = phrases(words)
    spk_of = []
    for ph in groups:
        votes = {}
        for k in ph:
            if who[k] is not None:
                votes[who[k]] = votes.get(who[k], 0) + 1
        spk_of.append(max(votes, key=votes.get) if votes else None)
    # фраза без голоса достаётся соседу: предыдущему, в начале записи следующему
    known = [x for x in spk_of if x is not None]
    fill = known[0] if known else 0
    for i, x in enumerate(spk_of):
        if x is None:
            spk_of[i] = fill
        else:
            fill = x

    # Буквы по порядку появления: кто заговорил первым, тот A.
    order, lines, cur, line_t = {}, [], None, 0.0
    for ph, spk in zip(groups, spk_of):
        t = words[ph[0]][0]
        text = " ".join(words[k][1] for k in ph)
        if spk != cur or not lines or t - line_t > LINE_SEC:
            order.setdefault(spk, LETTERS[len(order) % len(LETTERS)])
            lines.append(f"[{fmt(t)}] Говорящий {order[spk]}: {text}")
            cur, line_t = spk, t
        else:
            lines[-1] += " " + text

    lines = apply_zameny(lines, pairs)

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
        find_one("silero_vad.onnx")
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
        except Exception as e:  # сбой библиотеки: окно должно показать причину
            emit("ошибка", f"сбой движка: {e}")
            say(f"{os.path.basename(path)}: сбой движка: {e}")
            failed += 1
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
