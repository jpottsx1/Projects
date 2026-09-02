# Send to ImageOptim

A macOS Finder Quick Action (Service) that sends the files you have selected to
[ImageOptim](https://imageoptim.com) — no drag-and-drop, no dragging a folder
onto the Dock icon. Select images in Finder, right-click, **Quick Actions →
Send to ImageOptim**, and they land in ImageOptim's queue exactly as if you had
dropped them on the window.

ImageOptim has no scripting interface, so the files are handed over the way a
drop does: an "open documents" Apple Event sent straight to the app.

```sh
osascript -e 'tell application "ImageOptim" to open {POSIX file "/path/a.png"}'
```

The obvious `open -a ImageOptim a.png` is *not* used, because it goes through
LaunchServices, which on some builds refuses with *"ImageOptim cannot open
files in the PNG image format"* — the app's bundle does not advertise those
document types even though it happily accepts them by drop. A drop never
consults that list, and neither does the Apple Event. Two fallbacks follow it
if the event is refused: addressing the app by name instead of by bundle ID,
then plain `open -a`, then relaunching the app with the paths in its `argv`
(`open -n -a ImageOptim --args …`) — last, because `-n` leaves a second copy of
the app running.

Nothing about the app is hardcoded. Which ImageOptim you have is settled by
asking LaunchServices for it by name, and the bundle identifier is then read
out of that bundle — more than one shipping app is called ImageOptim, and they
do not share an identifier.

## Requirements

- macOS (tested targets: Ventura and later; the Services mechanism is far older)
- [ImageOptim.app](https://imageoptim.com) installed

## Install

One script, nothing else needed:

```sh
./setup.sh
```

It writes the command to `~/.local/bin`, installs the Quick Action that calls
it, refreshes the Services cache, and then sends ImageOptim a test image it
creates itself, reporting which handoff method worked. `./setup.sh --uninstall`
removes both. Everything it installs is baked into that one file, so it can be
copied to a machine on its own.

If you would rather install from the checkout, `install.sh` copies `Send to ImageOptim.workflow` into `~/Library/Services` and
flushes the Services cache. Add `--cli` to also symlink the command into
`/usr/local/bin` (or `--cli ~/bin` for somewhere else).

Then, in Finder: select some images → right-click → **Quick Actions → Send to
ImageOptim**. Older macOS versions list it under **Services** instead.

If the item does not show up, run `killall Finder`, or enable it under
**System Settings → Keyboard → Keyboard Shortcuts → Services → Files and
Folders** — the same place where you can assign it a keyboard shortcut such as
⌃⌥⌘O.

## What gets sent

| Selection | Behaviour |
| --- | --- |
| `.png .jpg .jpeg .gif .svg` (any capitalisation) | sent to ImageOptim |
| A folder | sent whole; ImageOptim walks it recursively |
| Anything else | silently skipped |

If nothing in the selection is usable you get a notification saying so, rather
than a silently launched empty ImageOptim.

The Quick Action appears whenever the selection contains images or folders, and
a mixed selection is fine — the non-images are dropped on the way through.

**ImageOptim rewrites files in place.** It is lossless by default, but if you
have configured lossy settings inside ImageOptim, the originals are gone. Keep
that in mind before pointing it at a folder of masters.

## Configuration

Create `~/.config/send-to-imageoptim/config` — it is sourced by the script, so
no rebuild or reinstall is needed after a change:

```sh
# only touch bitmaps, leave SVGs alone
IMAGEOPTIM_EXTS="png jpg jpeg gif"

# a copy of ImageOptim somewhere unusual
IMAGEOPTIM_APP="$HOME/Applications/ImageOptim.app"

# no notification when a selection has nothing to optimize
IMAGEOPTIM_QUIET=1

# pin the handoff instead of trying applescript, launchargs, openapp in order
IMAGEOPTIM_METHOD="applescript"
```

The same names work as environment variables and take precedence over the
config file.

## Command line

The Quick Action and the shell command are the same script:

```sh
send-to-imageoptim ~/Desktop/screenshots/*.png     # after ./install.sh --cli
./src/send-to-imageoptim.sh ~/Pictures/holiday     # or straight from the repo
```

Large selections are fine: the file list is piped through `xargs`, so it is
batched instead of overflowing the argument limit.

## Layout

```
src/send-to-imageoptim.sh        the actual logic (also the CLI)
tools/build-workflow.py          generates the .workflow from that script
tools/build-setup.py             generates setup.sh from that script
setup.sh                         the generated one-shot installer
Send to ImageOptim.workflow/     the generated Quick Action, committed
install.sh / uninstall.sh        copy it into (and out of) ~/Library/Services
```

An `.workflow` bundle is only two property lists, and the Run Shell Script
action stores its code as a string inside one of them. Rather than keep a
second, hand-edited copy of the script pasted into a plist, the bundle is
generated. After editing `src/send-to-imageoptim.sh`:

```sh
python3 tools/build-workflow.py && python3 tools/build-setup.py && ./setup.sh
```

The generator uses fixed UUIDs, so rebuilding an unchanged script produces no
diff.

## Uninstall

```sh
./uninstall.sh
```

Removes the Quick Action from `~/Library/Services` and any `send-to-imageoptim`
symlink pointing back at this checkout. The config file, if you made one, is
left alone.

## Checking it works

```sh
send-to-imageoptim --check
```

Prints which ImageOptim it found and its bundle identifier, then sends it a
1x1 PNG it writes itself — no path for you to get wrong — and reports which of
the four handoff methods was accepted. This is the first thing to run when
something is off.

## Troubleshooting

**The menu item never appears.** Services are cached. `killall Finder`, then
check the Services list in System Settings as above. Confirm the bundle is at
`~/Library/Services/Send to ImageOptim.workflow`.

**"ImageOptim is not installed."** The script looks for the bundle ID
`net.pornel.ImageOptim` via Spotlight, then in `/Applications` and
`~/Applications`. If ImageOptim lives elsewhere, or Spotlight indexing is off
for that volume, set `IMAGEOPTIM_APP` in the config file.

**"ImageOptim cannot open files in the PNG image format," and `--check` says a
method was accepted.** More than one app ships as "ImageOptim". The one on the
Mac App Store (`com.luoxiao.ImageOptim`) declares no `CFBundleDocumentTypes` at
all and takes files by drag-and-drop only: it accepts the Apple Event, then
refuses the file with that dialog. Nothing in this script can work around an
app with no way in. Get the real one and pin it:

```sh
mv /Applications/ImageOptim.app "/Applications/ImageOptim (App Store).app"
brew install --cask imageoptim
mkdir -p ~/.config/send-to-imageoptim
echo 'IMAGEOPTIM_APP="/Applications/ImageOptim.app"' > ~/.config/send-to-imageoptim/config
```

`--check` prints the bundle identifier it resolved and warns when it is not
`net.pornel.ImageOptim`.

**"ImageOptim cannot open files in the PNG image format" with every method
refused.** That dialog comes
from LaunchServices, which means every Apple Event method was refused and the
script fell through to `open -a`. Run `send-to-imageoptim --check` to see which
rung failed. If macOS is blocking Apple Events, allow the sender (Automator,
or Terminal for CLI use) under System Settings > Privacy & Security >
Automation.

**`--check` says both `applescript` rungs were refused.** macOS gates Apple
Events between apps. Allow the sender — Terminal for command-line use,
Automator for the Quick Action — under System Settings > Privacy & Security >
Automation. Without it the script still works, one rung down.

**Nothing happens and no notification appears.** Notifications for Script
Editor / Automator may be muted in System Settings → Notifications. Run the
same selection through `./src/send-to-imageoptim.sh` in Terminal to see the
error text directly.
