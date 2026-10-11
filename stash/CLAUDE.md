# Stash

A notes, documents and links app for Mac and iPhone/iPad: SwiftUI and
SwiftData, one multiplatform target. Read README.md first.

## Building

- `Stash.xcodeproj` uses **Xcode 16 file-system-synchronized groups**:
  any file put under `Stash/` is part of the app, so adding a Swift file
  doesn't require editing the project file.
- `StashCore/` is a local Swift package with no UI and no Apple-only
  frameworks. Logic that can live there should, because it's the only part
  that can be tested without building the app. `swift test --package-path StashCore`.
- The code was first written on a Linux machine with no Swift toolchain, so
  that first version had never been compiled. If you have Xcode, build both
  platforms (My Mac, and an iPhone simulator) before trusting a change.
- Without a compiler, at least check the braces balance:
  `find stash -name '*.swift' | xargs python3 loudness-lab/tools/check_braces.py`.
  That checker doesn't understand raw strings (`#"..."#`), so it falsely
  reports files that use them as unbalanced.

## Rules

- **Every change to items goes through `Library`.** It keeps the search
  index, the files on disk and the links in step. A view that edits an
  item's text calls `library.didEdit(item)`.
- **Keep the model CloudKit-compatible**: a default on every attribute,
  every relationship optional, no `@Attribute(.unique)`. Sync is the next
  big feature, and breaking this means a migration.
- **`[[Title]]` links are read from the note's text, never stored.**
  Hand-made links (`Item.linksTo`) are stored. Backlinks combine both.
- The search index can always be rebuilt from the library. Never store
  anything in it that exists nowhere else.
