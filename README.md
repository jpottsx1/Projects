# Send to ImageOptim

A macOS Finder Quick Action (Service) that sends the files you have selected to
[ImageOptim](https://imageoptim.com) — no drag-and-drop, no dragging a folder
onto the Dock icon. Select images in Finder, right-click, **Quick Actions →
Send to ImageOptim**, and they land in ImageOptim's queue exactly as if you had
dropped them on the window.

ImageOptim has no scripting interface, but it does accept files as launch
arguments, which is the same code path drag-and-drop uses:

```sh
open -a ImageOptim file1.png file2.jpg
```

That one line is the whole trick; the rest of this repo is the plumbing that
puts it on the Finder context menu, safely, for any selection.

## Requirements

- macOS (tested targets: Ventura and later; the Services mechanism is far older)
- [ImageOptim.app](https://imageoptim.com) installed

## Install

```sh
git clone <this repo>
cd projects
./install.sh
```

`install.sh` copies `Send to ImageOptim.workflow` into `~/Library/Services` and
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
```

The same three names work as environment variables and take precedence over the
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
Send to ImageOptim.workflow/     the generated Quick Action, committed
install.sh / uninstall.sh        copy it into (and out of) ~/Library/Services
```

An `.workflow` bundle is only two property lists, and the Run Shell Script
action stores its code as a string inside one of them. Rather than keep a
second, hand-edited copy of the script pasted into a plist, the bundle is
generated. After editing `src/send-to-imageoptim.sh`:

```sh
python3 tools/build-workflow.py && ./install.sh
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

## Troubleshooting

**The menu item never appears.** Services are cached. `killall Finder`, then
check the Services list in System Settings as above. Confirm the bundle is at
`~/Library/Services/Send to ImageOptim.workflow`.

**"ImageOptim is not installed."** The script looks for the bundle ID
`net.pornel.ImageOptim` via Spotlight, then in `/Applications` and
`~/Applications`. If ImageOptim lives elsewhere, or Spotlight indexing is off
for that volume, set `IMAGEOPTIM_APP` in the config file.

**Nothing happens and no notification appears.** Notifications for Script
Editor / Automator may be muted in System Settings → Notifications. Run the
same selection through `./src/send-to-imageoptim.sh` in Terminal to see the
error text directly.
