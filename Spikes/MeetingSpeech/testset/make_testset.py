#!/usr/bin/env python3
"""Throw-away test-set generator for the meeting speech spike.

Python standard library only (plus `say` and `ffmpeg` subprocesses), per
.rafu/plans/meeting-speech-spike.md. A fixed random seed (1234) makes every
set repeatable. Writes, under this package's `work/` directory:

  work/<set>/them.wav   16 kHz mono 16-bit mix
  work/<set>/ref.rttm   speaker time segments (NIST RTTM)
  work/<set>/ref.stm    per-utterance speaker/time/text ground truth
  work/<set>/ref.txt    the whole-meeting reference transcript

Meeting-English scripts (speaker, voice, text, gap-before-seconds; a
negative gap means overlap with the previous utterance) are written first
to testset/scripts/<set>.tsv, then read back to synthesize audio, so the
scripts are inspectable on their own.

Usage:
  uv run --python 3.12 make_testset.py --set all
  uv run --python 3.12 make_testset.py --set S3
  uv run --python 3.12 make_testset.py --set S3-call   (post-processes S3)
"""
from __future__ import annotations

import argparse
import array
import hashlib
import random
import re
import subprocess
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # Spikes/MeetingSpeech
WORK = ROOT / "work"
SCRIPTS_DIR = ROOT / "testset" / "scripts"
CLIP_CACHE = WORK / "clip_cache"
SAY_RATE = 180
SEED = 1234
SAMPLE_RATE = 16000

TOPICS = [
    "the search fix", "the API migration", "the Q3 roadmap", "the staging deploy",
    "the onboarding flow", "the dashboard redesign", "the billing service",
    "the mobile release", "the sprint review", "the backlog grooming",
    "the latency regression", "the QA checklist", "the customer ticket",
    "the auth module", "the data pipeline",
]
NAMES = ["Priya", "Sam", "Jordan", "Alex", "Maria", "Omar", "Chen", "Nina"]
NUMBERS = [3, 5, 7, 8, 12, 15, 20, 25, 30, 42]

STATEMENT_TEMPLATES = [
    "I think we should ship {topic} before the review on Thursday.",
    "Can we push {topic} to next sprint instead?",
    "What is the status of {topic}?",
    "The latency regression dropped by {number} percent after the fix.",
    "We closed {number} tickets this week.",
    "Let's circle back on {topic} after lunch.",
    "I'll take the action item on {topic}.",
    "Actually, I disagree with that approach for {topic}.",
    "Let's park that and move to the next item.",
    "We still need sign off on {topic}.",
    "I'll send the notes after the call.",
    "Can everyone hear me okay?",
    "Sorry, go ahead.",
    "Let's take five minutes and come back to {topic}.",
    "That sounds good to me.",
    "I have a question about {topic}.",
    "We should assign an owner for {topic}.",
    "The numbers for {topic} look better this week.",
    "Let's make a decision on {topic} before we move on.",
    "The team spent {number} hours on {topic} last week.",
]
SELF_INTRO_TEMPLATES = [
    "I'm {name}, I'll be driving today's meeting.",
    "This is {name}, joining from the mobile team.",
    "Hi everyone, {name} here.",
]
BACKCHANNELS = ["Yes.", "Right.", "Mm-hm.", "Agreed.", "Sure.", "Okay.", "Got it."]

# Checked usable `say` voices (.rafu/plans/meeting-speech-spike.md, "Current behaviour").
VOICE_SAMANTHA = "Samantha"
VOICE_DANIEL = "Daniel"
VOICE_KAREN = "Karen"
VOICE_MOIRA = "Moira"
VOICE_TESSA = "Tessa"
VOICE_RISHI = "Rishi"
VOICE_AMAN = "Aman"
VOICE_TARA = "Tara"
VOICE_EDDY_US = "Eddy (English (US))"
VOICE_REED_US = "Reed (English (US))"


def gen_sentence(rng: random.Random) -> str:
    topic = rng.choice(TOPICS)
    number = rng.choice(NUMBERS)
    template = rng.choice(STATEMENT_TEMPLATES)
    return template.format(topic=topic, number=number)


def gen_rows(
    rng: random.Random,
    speakers: list[tuple[str, str]],
    duration_seconds: float,
    pause_range: tuple[float, float],
    overlap_fraction: float,
    backchannel_fraction: float,
    self_intro_count: int,
) -> list[dict]:
    rows: list[dict] = []
    total = 0.0
    idx = 0
    intros_left = self_intro_count
    while total < duration_seconds:
        label, voice = speakers[idx % len(speakers)]
        idx += 1
        if intros_left > 0 and rng.random() < 0.3:
            text = rng.choice(SELF_INTRO_TEMPLATES).format(name=rng.choice(NAMES))
            intros_left -= 1
        elif rng.random() < backchannel_fraction:
            text = rng.choice(BACKCHANNELS)
        else:
            text = gen_sentence(rng)

        if not rows:
            gap = 0.0
        elif rng.random() < overlap_fraction:
            gap = -rng.uniform(0.2, 0.8)
        else:
            gap = rng.uniform(*pause_range)

        rows.append({"speaker": label, "voice": voice, "text": text, "gap": gap})
        words = len(text.split())
        est_duration = words / 3.0 + 0.3  # ~180 wpm = 3 words/s, plus say/ffmpeg overhead
        total += max(0.0, gap) + est_duration
    return rows


def write_tsv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        for r in rows:
            f.write(f"{r['speaker']}\t{r['voice']}\t{r['text']}\t{r['gap']:.3f}\n")


def read_tsv(path: Path) -> list[dict]:
    rows = []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            speaker, voice, text, gap = line.split("\t")
            rows.append({"speaker": speaker, "voice": voice, "text": text, "gap": float(gap)})
    return rows


def say_clip(voice: str, text: str) -> Path:
    """Synthesizes `text` with `say`, converts to 16 kHz mono PCM16, trims
    leading/trailing silence. Cached by (voice, text)."""
    key = hashlib.sha1(f"{voice}|{text}".encode()).hexdigest()[:16]
    cached = CLIP_CACHE / f"{key}.wav"
    if cached.exists():
        return cached
    CLIP_CACHE.mkdir(parents=True, exist_ok=True)
    aiff = CLIP_CACHE / f"{key}.aiff"
    raw_wav = CLIP_CACHE / f"{key}.raw.wav"
    subprocess.run(["say", "-v", voice, "-r", str(SAY_RATE), "-o", str(aiff), text], check=True)
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-i", str(aiff),
         "-ar", str(SAMPLE_RATE), "-ac", "1", "-c:a", "pcm_s16le", str(raw_wav)],
        check=True,
    )
    trim_silence(raw_wav, cached)
    aiff.unlink(missing_ok=True)
    raw_wav.unlink(missing_ok=True)
    return cached


def read_wav_samples(path: Path) -> array.array:
    with wave.open(str(path), "rb") as w:
        assert w.getframerate() == SAMPLE_RATE and w.getnchannels() == 1 and w.getsampwidth() == 2
        data = w.readframes(w.getnframes())
    samples = array.array("h")
    samples.frombytes(data)
    return samples


def write_wav_samples(path: Path, samples) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        out = array.array("h", samples)
        w.writeframes(out.tobytes())


def trim_silence(src: Path, dst: Path, threshold: float = 400.0, window: int = 160) -> None:
    samples = read_wav_samples(src)
    n = len(samples)

    def rms(i: int) -> float:
        j = min(n, i + window)
        if j <= i:
            return 0.0
        s = sum(samples[k] * samples[k] for k in range(i, j))
        return (s / (j - i)) ** 0.5

    start = 0
    while start < n and rms(start) < threshold:
        start += window
    end = n
    while end > start and rms(max(start, end - window)) < threshold:
        end -= window
    if end <= start:
        start, end = 0, n
    write_wav_samples(dst, samples[start:end])


def clip_duration_seconds(path: Path) -> float:
    with wave.open(str(path), "rb") as w:
        return w.getnframes() / w.getframerate()


def layout(rows: list[dict]) -> list[dict]:
    """Places each utterance's synthesized clip on a timeline using the
    gap column (relative to the end of the previous utterance; negative =
    overlap)."""
    entries = []
    prev_end = 0.0
    for row in rows:
        clip = say_clip(row["voice"], row["text"])
        duration = clip_duration_seconds(clip)
        start = max(0.0, prev_end + row["gap"]) if entries else 0.0
        end = start + duration
        entries.append({**row, "start": start, "end": end, "duration": duration, "clip": clip})
        prev_end = end
    return entries


def mix(entries: list[dict], out_path: Path) -> None:
    total_samples = int(max(e["end"] for e in entries) * SAMPLE_RATE) + SAMPLE_RATE
    buffer = array.array("i", [0]) * total_samples
    for e in entries:
        samples = read_wav_samples(e["clip"])
        offset = int(e["start"] * SAMPLE_RATE)
        for i, s in enumerate(samples):
            buffer[offset + i] += s
    peak = max(1, max(abs(v) for v in buffer))
    scale = min(1.0, 32000.0 / peak)
    out = array.array("h", (int(v * scale) for v in buffer))
    write_wav_samples(out_path, out)


def write_ground_truth(entries: list[dict], out_dir: Path, file_id: str) -> None:
    rttm_lines = []
    stm_lines = []
    words = []
    for e in sorted(entries, key=lambda e: e["start"]):
        rttm_lines.append(
            f"SPEAKER {file_id} 1 {e['start']:.3f} {e['duration']:.3f} <NA> <NA> {e['speaker']} <NA> <NA>"
        )
        stm_lines.append(f"{file_id} 1 {e['speaker']} {e['start']:.3f} {e['end']:.3f} {e['text']}")
        words.append(e["text"])
    (out_dir / "ref.rttm").write_text("\n".join(rttm_lines) + "\n")
    (out_dir / "ref.stm").write_text("\n".join(stm_lines) + "\n")
    (out_dir / "ref.txt").write_text(" ".join(words) + "\n")


def measure_rms_db(path: Path) -> float | None:
    # metadata=0 with no `reset` (default 0) accumulates over the whole
    # stream and prints one cumulative RMS at the end; `reset=1` (tried
    # first, wrongly) resets every single frame, so the last printed value
    # is whatever the final ~1024-sample frame happens to be -- often
    # near-silence from this generator's trailing pad, which prints as
    # "-inf" and breaks the float parse.
    proc = subprocess.run(
        ["ffmpeg", "-i", str(path), "-af", "astats=metadata=0", "-f", "null", "-"],
        stderr=subprocess.PIPE, text=True,
    )
    matches = re.findall(r"RMS level dB:\s*(-?[\d.]+)", proc.stderr)
    return float(matches[-1]) if matches else None


def has_libopus() -> bool:
    proc = subprocess.run(["ffmpeg", "-encoders"], capture_output=True, text=True)
    return "libopus" in proc.stdout


def add_noise(src: Path, dst: Path, snr_db: float) -> dict:
    speech_db = measure_rms_db(src)
    duration = clip_duration_seconds(src)
    probe = src.parent / "_noise_probe.wav"
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi",
         "-i", f"anoisesrc=color=pink:amplitude=1.0:sample_rate={SAMPLE_RATE}:duration=2",
         str(probe)],
        check=True,
    )
    noise_db_at_1 = measure_rms_db(probe)
    probe.unlink(missing_ok=True)
    if speech_db is None or noise_db_at_1 is None:
        raise RuntimeError("could not measure RMS level with ffmpeg astats")
    target_noise_db = speech_db - snr_db
    amplitude = 10 ** ((target_noise_db - noise_db_at_1) / 20)
    amplitude = max(0.0005, min(1.0, amplitude))
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-i", str(src),
         "-f", "lavfi", "-i", f"anoisesrc=color=pink:amplitude={amplitude}:sample_rate={SAMPLE_RATE}:duration={duration}",
         "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=first:normalize=0",
         "-ar", str(SAMPLE_RATE), "-ac", "1", "-c:a", "pcm_s16le", str(dst)],
        check=True,
    )
    return {"speech_rms_db": speech_db, "target_snr_db": snr_db, "noise_amplitude": amplitude}


def call_roundtrip(src: Path, dst: Path) -> bool:
    opus = has_libopus()
    if opus:
        mid = src.parent / "_call_tmp.ogg"
        subprocess.run(
            ["ffmpeg", "-loglevel", "error", "-y", "-i", str(src), "-c:a", "libopus", "-b:a", "24k", str(mid)],
            check=True,
        )
    else:
        mid = src.parent / "_call_tmp.m4a"
        subprocess.run(
            ["ffmpeg", "-loglevel", "error", "-y", "-i", str(src), "-c:a", "aac", "-b:a", "32k", str(mid)],
            check=True,
        )
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-i", str(mid),
         "-ar", str(SAMPLE_RATE), "-ac", "1", "-c:a", "pcm_s16le", str(dst)],
        check=True,
    )
    mid.unlink(missing_ok=True)
    return opus


# ---- set definitions -------------------------------------------------------

def rows_for_set(set_id: str, rng: random.Random) -> list[dict]:
    if set_id == "S2":
        return gen_rows(rng, [("Them1", VOICE_DANIEL), ("Them2", VOICE_SAMANTHA)],
                         180, (0.3, 2.0), 0.0, 0.08, 0)
    if set_id == "S3":
        return gen_rows(rng, [("Them1", VOICE_SAMANTHA), ("Them2", VOICE_DANIEL), ("Them3", VOICE_RISHI)],
                         300, (0.3, 1.5), 0.05, 0.15, 2)
    if set_id == "S5":
        return gen_rows(
            rng,
            [("Them1", VOICE_SAMANTHA), ("Them2", VOICE_DANIEL), ("Them3", VOICE_RISHI),
             ("Them4", VOICE_KAREN), ("Them5", VOICE_MOIRA)],
            480, (0.3, 1.5), 0.10, 0.12, 1,
        )
    if set_id == "S8":
        return gen_rows(
            rng,
            [("Them1", VOICE_SAMANTHA), ("Them2", VOICE_DANIEL), ("Them3", VOICE_RISHI),
             ("Them4", VOICE_KAREN), ("Them5", VOICE_MOIRA), ("Them6", VOICE_TESSA),
             ("Them7", VOICE_AMAN), ("Them8", VOICE_TARA)],
            480, (0.3, 1.5), 0.05, 0.1, 0,
        )
    if set_id == "S2-similar":
        return gen_rows(rng, [("Them1", VOICE_EDDY_US), ("Them2", VOICE_REED_US)],
                         180, (0.3, 2.0), 0.0, 0.08, 0)
    if set_id == "ME":
        return gen_rows(rng, [("Me", VOICE_AMAN)], 300, (0.3, 2.0), 0.0, 0.0, 0)
    if set_id == "NUM":
        rng2 = random.Random(SEED + 999)
        rows = []
        for n in [3, 12, 25, 42, 100]:
            rows.append({
                "speaker": "Them1", "voice": VOICE_SAMANTHA,
                "text": f"We closed {n} tickets this week.", "gap": 0.0 if not rows else 1.0,
            })
        return rows
    raise ValueError(f"no generator for set {set_id}")


def build_base_set(set_id: str) -> Path:
    out_dir = WORK / set_id
    out_dir.mkdir(parents=True, exist_ok=True)
    tsv_path = SCRIPTS_DIR / f"{set_id}.tsv"
    if not tsv_path.exists():
        rows = rows_for_set(set_id, random.Random(SEED + hash(set_id) % 10000))
        write_tsv(tsv_path, rows)
    rows = read_tsv(tsv_path)
    entries = layout(rows)
    mix(entries, out_dir / "them.wav")
    write_ground_truth(entries, out_dir, set_id)
    return out_dir


def build_l30() -> Path:
    """S3 texts in a new order, repeated to about 30 minutes, reusing S3's
    synthesized clips (cached by voice+text, so no extra `say` calls)."""
    out_dir = WORK / "L30"
    out_dir.mkdir(parents=True, exist_ok=True)
    base_rows = read_tsv(SCRIPTS_DIR / "S3.tsv")
    if not base_rows:
        build_base_set("S3")
        base_rows = read_tsv(SCRIPTS_DIR / "S3.tsv")
    rng = random.Random(SEED + 30)
    rows: list[dict] = []
    total_estimate = 0.0
    target = 30 * 60.0
    pool = list(base_rows)
    while total_estimate < target:
        shuffled = pool[:]
        rng.shuffle(shuffled)
        for r in shuffled:
            gap = r["gap"] if rows else 0.0
            rows.append({**r, "gap": gap})
            total_estimate += max(0.0, gap) + len(r["text"].split()) / 3.0 + 0.3
            if total_estimate >= target:
                break
    write_tsv(SCRIPTS_DIR / "L30.tsv", rows)
    entries = layout(rows)
    mix(entries, out_dir / "them.wav")
    write_ground_truth(entries, out_dir, "L30")
    return out_dir


def build_s3_call() -> Path:
    base = WORK / "S3"
    if not (base / "them.wav").exists():
        build_base_set("S3")
    out_dir = WORK / "S3-call"
    out_dir.mkdir(parents=True, exist_ok=True)
    noisy = out_dir / "them_noise.wav"
    info = add_noise(base / "them.wav", noisy, snr_db=15.0)
    opus_used = call_roundtrip(noisy, out_dir / "them.wav")
    noisy.unlink(missing_ok=True)
    for name in ("ref.rttm", "ref.stm", "ref.txt"):
        (out_dir / name).write_text((base / name).read_text())
    (out_dir / "noise_info.txt").write_text(f"{info}\nlibopus_used={opus_used}\n")
    return out_dir


def build_s5_noise() -> Path:
    base = WORK / "S5"
    if not (base / "them.wav").exists():
        build_base_set("S5")
    noisy = base / "them.wav"
    tmp = base / "_them_noise_tmp.wav"
    info = add_noise(noisy, tmp, snr_db=20.0)
    tmp.replace(noisy)
    (base / "noise_info.txt").write_text(f"{info}\n")
    return base


SET_BUILDERS = {
    "S2": lambda: build_base_set("S2"),
    "S3": lambda: build_base_set("S3"),
    "S8": lambda: build_base_set("S8"),
    "S2-similar": lambda: build_base_set("S2-similar"),
    "ME": lambda: build_base_set("ME"),
    "NUM": lambda: build_base_set("NUM"),
    "S5": build_s5_noise,
    "S3-call": build_s3_call,
    "L30": build_l30,
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--set", default="all", help="all, or one of: " + ", ".join(SET_BUILDERS))
    args = parser.parse_args()

    SCRIPTS_DIR.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)

    targets = list(SET_BUILDERS) if args.set == "all" else [args.set]
    for set_id in targets:
        if set_id not in SET_BUILDERS:
            print(f"unknown set: {set_id}", file=sys.stderr)
            return 1
        print(f"building {set_id} ...")
        out_dir = SET_BUILDERS[set_id]()
        print(f"  wrote {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
