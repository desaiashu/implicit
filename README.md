# Implicit

A macOS menubar app that **censors profanity in the audio you're listening to**
— music, videos, streams, calls — in real time, before it reaches your speakers.
It works like a broadcast "dump" delay: system audio is held for ~1 second, a
streaming keyword spotter listens for swear words, and any hit is muted (or
bleeped) in the still-buffered audio before you ever hear it.

No virtual audio driver to install — it uses macOS 14.4+ Core Audio process taps.

![macOS](https://img.shields.io/badge/macOS-14.4%2B-blue) ![core](https://img.shields.io/badge/core-Rust-orange) ![shell](https://img.shields.io/badge/shell-SwiftUI-red)

---

## Install (build from source)

**Requirements**

- macOS **14.4 or newer** (Core Audio process taps).
- [Rust](https://rustup.rs) (`cargo`).
- Xcode or the Command Line Tools (`xcode-select --install`) for `swift`.

**Steps**

```bash
git clone https://github.com/desaiashu/implicit.git
cd implicit

# 1. Download the keyword-spotting model (~19 MB, one time).
./scripts/fetch-model.sh

# 2. Build, bundle, sign, and launch.
./run.sh
```

`run.sh` builds the Rust core and the Swift app, assembles a self-contained,
code-signed `build/Implicit.app` (model + native libraries bundled inside), and
launches it. Look for the **speaking-person icon in your menubar**.

> The first run prompts for two permissions — **Microphone** and **Screen &
> System Audio Recording** (the latter is what actually gates system-audio
> capture on macOS 15+). Grant both in System Settings → Privacy & Security,
> then toggle Implicit on. The grant sticks across rebuilds.

### Prefer a prebuilt app?

If someone sent you `Implicit.zip`, unzip it and drag `Implicit.app` to
`/Applications`. Because it isn't notarized, the first launch needs:
**right-click → Open → Open**, then approve the permission prompts. (If macOS
still blocks it, allow it under System Settings → Privacy & Security → "Open
Anyway".)

---

## Using it

Click the menubar icon for the controls:

- **Censor system audio** — the on/off switch (starts/stops the tap).
- **Mute / Bleep** — silence the word, or replace it with a tone.
- **Sensitivity** — higher catches more (helpful for words buried under music),
  at the cost of more false hits.
- **Output delay** — how far audio is delayed (the lag). Higher reliably catches
  long words; lower feels snappier. Applied when you release the slider.
- **Word length / letter**, **Latency reach-back**, **Trailing tail** — fine
  controls over exactly how much audio around each detected word is muted (see
  *Tuning* below). These apply live.
- **Reset** — restore factory defaults. **Quit** — stop and exit (⌘Q).

Settings persist across launches.

### Tuning the censor window

The spotter only recognizes a word *after* it finishes (plus ~160–320 ms of
detector latency), so the app reaches **backward** over the just-played audio to
mute it:

- **start of a word leaks through** → raise **Word length / letter** or
  **Latency reach-back**, or raise **Output delay** for more headroom.
- **end of a word / next syllable cut off** → raise **Trailing tail**, or lower
  **Latency reach-back**.
- **too much silence around a word** → lower **Word length / letter** and
  **Trailing tail**.

Because you can't censor a word before you know it's a swear (i.e. before it
finishes), the output delay has a real floor of roughly *longest word + detector
latency* — about a second for words like "motherfucker". That's physics, not a
bug.

### Editing the word list

The words live in [`scripts/swears.txt`](scripts/swears.txt), one per line.
After editing, regenerate the model's keyword file:

```bash
./scripts/fetch-model.sh    # re-tokenizes swears.txt into the model's keywords
./run.sh                    # rebuild with the new list
```

> The keyword spotter matches *exact* phonetic token sequences, so include
> morphological variants explicitly (`fuck`, `fucking`, `fucked`, …). The model's
> vocabulary is uppercase (GigaSpeech); the tokenizer step handles the casing.

---

## How it works

```
system / app audio ─▶ Core Audio process tap (muted) ─▶ ~1 s delay line ─▶ speakers
     (macOS 14.4+)              │                              ▲
                               └─▶ streaming keyword spotter ──┘  hit → mute/bleep that span
                  (Implicit's own output is excluded from the tap — no feedback loop)
```

- **Capture (Swift, `macos-app/`).** A Core Audio *process tap* captures all
  system audio and mutes the original, so Implicit can post-process and play back
  a censored copy. An aggregate device drives the IOProc; the output follows your
  default device, so switching to AirPods/HDMI mid-stream keeps working.
- **Censor core (Rust, `rust-core/`).** A fixed delay line holds the most recent
  audio. A downmixed/resampled copy feeds a streaming Zipformer keyword spotter
  ([sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)); on a hit, the word's
  span is muted/bleeped in the still-buffered audio with click-free cosine fades.
  Detection timing is live-tunable over a small C ABI.

A keyword spotter (not Whisper) is the right tool here: it's a *streaming*
architecture (~160–320 ms latency, on-device) built for "spot these N words
now", whereas Whisper's streaming latency runs into seconds.

## Project layout

| Path | What |
|------|------|
| `rust-core/` | Censor pipeline: delay line, click-free mute/bleep, detector interface, sherpa-onnx KWS (feature-gated), C ABI. Unit-tested (`cd rust-core && cargo test`). |
| `macos-app/` | SwiftUI menubar app: Core Audio tap + aggregate-device IOProc, Rust bridge, live controls. |
| `scripts/` | `fetch-model.sh` (download/stage + tokenize the model), `swears.txt` (word list). |
| `run.sh` | Build → bundle → sign → launch. |

> Internal names: the Rust audio engine crate is `swearcore` (linked as
> `libswearcore`) and the Swift product target is `SwearFilter` — only the
> user-facing app is branded **Implicit**.

## License

Personal project. The bundled keyword model is from
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0).
