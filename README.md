# AirPods Approvals for Hermes

When your Hermes agent needs a yes or no, it asks in your AirPods and you answer with your head. Nod to approve. Shake to deny. The answer drives the real Hermes approval, so you can step away from the screen and keep work moving.

## How it feels

1. A chime, then Hermes reads out what it wants to do.
2. A soft tone starts. It's listening.
3. Hit three quick beats. Each one taps: a shake taps low in the ear you turned towards, and a nod taps from above and below. The taps get louder as you go.
4. A confirmation sound, and the agent carries on.

Slow movement only taps. Miss the rhythm and a soft sound tells you the count started over.

## What it does

| | |
| --- | --- |
| Approvals | Nod approves once. Shake denies. The buttons on screen keep working. |
| Questions with two choices | Nod picks the first, shake picks the second. |
| Questions with a list | Options are read one at a time. Nod picks, shake moves on. |
| Open questions | Read aloud, then answered on screen. |

Settings are in **Settings → Plugins → AirPods Approvals**, including **Try it**, which practises the gesture without touching Hermes.

## Why a misread can't approve something by accident

A glance is as fast as a shake, so speed alone isn't safe. Gestures are recognised by rhythm, measured from real recordings ([docs/GESTURES.md](docs/GESTURES.md)).

- Listening starts only after the question has finished and your head has settled. A nod that began early counts for nothing.
- A gesture needs three alternating beats, each within 0.41 seconds of the last, mostly on one axis.
- A nod only ever sends `once`, never `session` or `always`.
- Before answering, the plugin checks that the same request is still waiting, with the same command.
- A timeout, AirPods coming out, or the helper stopping sends nothing. The prompt stays on screen and Hermes' own timeout denies it.
- Turn on **Nod twice to approve** for a second round before anything runs. It's off by default.
- The closing instruction is always added by the plugin, so text inside a command can't change what a nod means.

It reduces misreads rather than removing them. If you nod along to something during the listening window, that could count. For commands you'd never want run by accident, leave Hermes' prompts on screen and turn this off, or turn on **Nod twice to approve**.

## Requirements

- A Mac with Hermes Desktop, and AirPods that report head motion (AirPods Pro, AirPods Max, AirPods 3 and later).
- macOS 14 or later, with the Xcode Command Line Tools to build the helper.
- Hermes 0.22.5 or later.

## Install

Install the plugin on your Hermes:

```bash
hermes plugins install airpods-approvals --enable
```

Then build the helper on the Mac your AirPods connect to. It's built from the source in this repository, and nothing is downloaded:

```bash
git clone https://github.com/cineglobe/hermes-airpods-approvals
cd hermes-airpods-approvals
scripts/install-helper.sh
```

In Hermes Desktop, open **Settings → Plugins → AirPods Approvals** and press **Connect**. Allow Motion access when macOS asks.

### Why a helper?

Head motion comes from Apple's `CMHeadphoneMotionManager`, which a Desktop plugin can't reach. macOS also only allows it from a real app started by Launch Services, so the helper is a small menu bar app. It's built on your own Mac because the Hermes catalog doesn't accept compiled binaries.

### The voice

With no setup, the Mac's own voice reads prompts. For a Gemini voice, give the Hermes backend a key:

```bash
hermes config set AIRPODS_APPROVALS_GEMINI_KEY <key from aistudio.google.com/apikey>
```

`GEMINI_API_KEY`, `GOOGLE_API_KEY` and `GEMINI_LIVE_API_KEY` also work. Hermes has to restart to load the speech route. If Gemini fails or runs out of quota, the Mac's voice takes over.

## What it sends, reads and runs

- **Network:** only for the optional Gemini voice, from the Hermes backend to `generativelanguage.googleapis.com`.
- **Sent to Gemini:** the sentence being read: the approval's description and command, or the question and its choices. Hermes redacts secrets in commands first, but treat what's spoken as sent to Google. On Gemini's free tier, Google may use content to improve its products. With the Mac voice, nothing leaves your Mac.
- **Head motion:** read only while a question is open, handled on the Mac and never stored or sent anywhere. Only the answer leaves the helper.
- **Background process:** the helper stays in the menu bar while Desktop is connected, and quits 10 minutes after it goes away.
- **Local connection:** the helper listens on `127.0.0.1:47291`. Both sides prove they hold a pairing token, and browsers are refused by origin. The token sits in a file only your user can read.
- **Prompts stay private:** audio plays only through Bluetooth headphones, never the Mac's speakers.
- **Telemetry:** none.

## Uninstall

Quit Hermes AirPods from the menu bar, then delete `~/Applications/Hermes AirPods.app` and `~/Library/Application Support/Hermes AirPods`. Remove the plugin with `hermes plugins remove airpods-approvals`.

## Development

```bash
scripts/test.sh                 # JS, Python and Swift tests
python3 scripts/build.py        # regenerate desktop/plugin.js from src/
hermes plugins validate .
```

```
src/engine.mjs           what's asked, and when an answer may reach Hermes
src/desktop.js           Desktop plugin shell and settings
helper/Sources/AirPodsCore     gesture detection and session rules, tested against real recordings
helper/Sources/HermesAirPods   motion, sound, speech and the local connection
airpods_core.py          optional Gemini speech
dashboard/plugin_api.py  the speech route
```

MIT licensed. AirPods is a trademark of Apple Inc. This project isn't affiliated with Apple or Nous Research.
