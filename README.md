# Censor Audio

A macOS menubar app that **censors profanity in the audio you're listening to**
— music, videos, streams, calls — in real time, before it reaches your speakers.
It works like a broadcast "dump" delay: system audio is held for a couple of
seconds, an on-device **Whisper** model transcribes it, and any word on your
list is muted (or bleeped) in the still-buffered audio before you ever hear it.

No virtual audio driver to install — it uses macOS 14.4+ Core Audio process taps.

![macOS](https://img.shields.io/badge/macOS-14.4%2B-blue) ![core](https://img.shields.io/badge/core-Rust-orange) ![asr](https://img.shields.io/badge/ASR-whisper.cpp%20(Metal)-purple) ![shell](https://img.shields.io/badge/shell-SwiftUI-red)

---

## Install (build from source)

**Requirements**

- macOS **14.4 or newer** (Core Audio process taps), Apple Silicon recommended (Metal).
- [Rust](https://rustup.rs) (`cargo`) and `cmake` (`brew install cmake`) — whisper.cpp builds from source.
- Xcode or the Command Line Tools (`xcode-select --install`) for `swift`.

**Steps**

```bash
git clone https://github.com/desaiashu/implicit.git
cd implicit

# 1. Download the Whisper model (~465 MB, one time).
./scripts/fetch-model.sh

# 2. Build, bundle, sign, and launch. (First build compiles whisper.cpp — a few minutes.)
./run.sh
```

`run.sh` builds the Rust core (with whisper.cpp statically linked + Metal) and
the Swift app, assembles a self-contained, code-signed `build/Censor Audio.app`
(model + library bundled inside), and launches it. Look for the **ear icon in
your menubar**.

> First run prompts for **Microphone** and **Screen & System Audio Recording**
> (the latter is what gates system-audio capture on macOS 15+). Grant both in
> System Settings → Privacy & Security, then toggle Censor Audio on.

### Prefer a prebuilt app?

If someone sent you `CensorAudio.zip`, unzip it and drag `Censor Audio.app` to
`/Applications`. It isn't notarized, so the first launch needs **right-click →
Open → Open**, then approve the permission prompts.

---

## Using it

Click the menubar ear for the controls:

- **Censor system audio** — the on/off switch.
- **Mute / Bleep** — silence the word, or replace it with a tone.
- **Output delay** — how far audio is delayed. Whisper recognizes words with
  some lag, so this needs to be ~2–3 s; higher catches more, with more lag.
- **Trailing tail** — extra silence kept after a censored word.
- **Edit Words…** — opens a window to edit the censored-word list (one per line).
  It's plain text, so **any word works instantly** — no rebuild, no tokenization.
- **Reset** / **Quit**.

Settings persist across launches; the on/off switch starts off each launch so it
never taps your audio without you.

## How it works

```
system / app audio ─▶ Core Audio process tap (muted) ─▶ ~2.5 s delay ─▶ speakers
     (macOS 14.4+)              │                              ▲
                               └─▶ Whisper (rolling windows) ──┘  word on the list → mute/bleep that span
                  (Censor Audio's own output is excluded from the tap — no feedback loop)
```

- **Capture (Swift, `macos-app/`).** A Core Audio *process tap* captures all
  system audio and mutes the original; Censor Audio plays back a delayed, censored
  copy. An aggregate device drives the IOProc and follows your default output, so
  switching to AirPods/HDMI mid-stream keeps working.
- **Detector (Rust, `rust-core/`).** The delayed audio (downmixed to 16 kHz) is
  transcribed in rolling windows by **whisper.cpp** (Metal-accelerated, ~20×
  realtime for `small.en`). Words on the list are matched in the transcript and
  censored using Whisper's per-word timestamps, with click-free cosine fades.

### Why Whisper

The original streaming keyword-spotter (and even much larger streaming ASR
models) mis-hear vocals buried under a beat — they're trained on clean speech.
Whisper is trained on far noisier/musical audio and transcribes rap vocals
cleanly, so it actually catches the words. The tradeoffs are higher CPU and a
bit more latency, which is why the delay sits around 2–3 s.

## Project layout

| Path | What |
|------|------|
| `rust-core/` | Delay line, click-free mute/bleep, detector interface, and the whisper.cpp detector (feature `whisper`). C ABI for the Swift shell. |
| `macos-app/` | SwiftUI menubar app: Core Audio tap + aggregate-device IOProc, Rust bridge, controls + word editor. |
| `scripts/` | `fetch-model.sh` (download the Whisper model), `swears.txt` (default word list). |
| `run.sh` | Build → bundle → sign → launch. |

> Internal names: the Rust engine crate is `swearcore` / the Swift product target
> is `SwearFilter` — only the user-facing app is branded **Censor Audio**. A legacy
> sherpa keyword-spotter detector remains behind the `sherpa` feature but is not
> used by the app.

## License

Personal project. Bundles the [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
`ggml-small.en` model (MIT).
