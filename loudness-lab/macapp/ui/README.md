# Loudness Lab — macOS front end

A window over the command line tool: pick folders, set the variables, process,
and compare the result against the original without a break in the music.

## What it is not

It is not a Swift port. Every measurement and every sample it shows came out
of the Python in the folder above, which has the test suite behind it —
BS.1770 validated against ffmpeg's ebur128, a de-clipper scored against
known-clean audio, a sub sized from a measured corpus. Reimplementing that
here would fork the reference and leave two things to keep honest instead of
one. The app runs `./loudness-lab subbass`, reads the `manifest.json` it
writes, and plays the files.

## Building

Needs macOS 14 or later.

    open Package.swift          # opens in Xcode; ⌘R to run

or from the terminal:

    swift run

Do not sandbox it. It runs a subprocess and reads folders you point it at,
and App Sandbox blocks both.

## Using it

1. **Tool** — choose the `loudness-lab` folder, the one with the launcher in it.
2. **Music** — add folders or individual files.
3. **Settings** — a profile, or move the sliders. Anything left at its default
   is not passed as a flag, so a chosen profile keeps deciding it.
4. **Process** — the log is the tool's own output, live.
5. Pick a track in the table, then use the buttons under the transport.

## The comparison

The thing this exists for. Every version of a track is decoded up front,
scheduled on its own player node, and started at one shared sample time on
one engine clock. They all run at once, in lockstep, for as long as you are
listening. The version buttons do not stop, start or seek anything — they
change which node reaches the output, over a 12 ms ramp so the gain step is
not a click. The bar you are in plays straight through the switch.

That only works because the files line up, and they line up because the tool
renders every version of a track from a single decode. The manifest records
that (`"aligned": true`), and `tests/test_manifest.py` holds it to it. Point
the player at an original MP3 and a processed FLAC yourself and they will not
line up — the encoder delay puts them a few hundred samples apart — so the
player checks the lengths and says so rather than letting you wonder why it
sounds doubled.

Two switches sit beside the transport:

- **Match loudness** brings every version down to the quietest of them, on
  the same estimator the tool levels on. On by default. Without it the
  comparison measures which is louder, and louder wins regardless of whether
  it is better.
- **Blind** hides the labels and shuffles the order per track, with a reveal
  when you have decided. Knowing which one is processed is worth a couple of
  imagined dB.

Shift-Space switches version; 1, 2, 3 select one directly.
