# Stash

A notes, documents and links app for Mac and iPhone/iPad: SwiftUI and
SwiftData, one multiplatform target. Read README.md first.

## Building

- Deployment targets: **macOS 26, iOS 17.5** (both targets and
  `StashCore/Package.swift`; keep the three in step). Building needs Xcode 26.
- `Stash.xcodeproj` uses **Xcode 16 file-system-synchronized groups**:
  any file put under `Stash/` is part of the app, so adding a Swift file
  doesn't require editing the project file.
- **Test library**: launched with `-StashTestLibrary YES`, Stash uses a
  separate library (Application Support/StashTest) that never syncs and
  stays out of Spotlight, notifications and widgets. The Mac UI tests
  (`StashUITests`, in the Stash scheme) use it; run them before trusting a
  change to the Mac interface.
- Five targets: **Stash** (the app), **StashShare** (the share
  extension, folder `ShareExtension/`), **StashWidgets** (the widgets,
  folder `Widgets/`), **StashSafari** (Safari's Save to Stash button,
  `SafariExtension/`) and **StashFinder** (the File Provider extension,
  `FinderExtension/`), all embedded in the app. The widgets read a snapshot
  the app writes into the App Group (`WidgetSnapshot`), the Finder another
  (`FinderShare`); like the share and Safari extensions they never open
  the SwiftData store.
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
  every relationship optional, no `@Attribute(.unique)`. CloudKit rejects
  the whole schema if any of these is broken. Add new attributes; never
  rename or remove one that has synced.
- **Sync is off by default** (`ICLOUD_SYNC` in `Config/Stash.xcconfig`)
  because iCloud entitlements need a paid developer team, and the app has
  to keep building without one. Code that touches CloudKit directly, such as
  the account check in `SyncMonitor`, goes behind `SyncMonitor.isEnabled` or
  `#if ICLOUD_SYNC`. Without the entitlement it crashes.
- **Sharing is off by default** (`SHARE_EXTENSION`) for the same reason.
  The share extension never opens the SwiftData store. It writes to the
  `SharedInbox`, and the app imports from it. Keep it that way.
- Entitlements come from both switches together: `STASH_X_<sync>_<share>`
  in `Config/Stash.xcconfig`, one file per combination. Changing an
  entitlement means changing every file that has it.
- Anything deduplicated across devices picks its survivor by `uuid`, so
  every device makes the same choice.
- **`[[Title]]` links are read from the note's text, never stored.**
  Hand-made links (`Item.linksTo`) are stored. Backlinks combine both.
- **The microphone** (voice notes) comes from `ENABLE_RESOURCE_ACCESS_AUDIO_INPUT`
  and the `INFOPLIST_KEY_NS…UsageDescription` settings on the Stash target,
  not an entitlements file, so it works with sync and sharing off.
- **Give a sheet its minimum size with `.sheetSize(minWidth:minHeight:)`**,
  never `.frame(minWidth:)`: on an iPhone a minimum wider than the screen
  pushes the sheet's content off the side.
- **There can be several libraries** (`StashStore.libraries`); only the main
  one (`Library.isMain`) syncs, and only it touches what's shared by the
  whole app: Spotlight, reminder notifications, widgets, the share inbox.
  Anything new of that kind checks `isMain` too.
- **Templates are notes with `isTemplate` set.** `Library.isInSidebar`
  keeps them out of every list but Templates; anything else that walks all
  items (the graph, widgets, `[[link]]` lookup, See Also) skips them too.
- **Indexed documents' files are never written** (bookmarks are read-only),
  and they're reached only through `Library.localFile(for:)`, never
  `storedFilePath`, which they don't have.
- **The search index syncs by signature** (`Library.indexSignature`): if
  something new goes into an item's index entry, put it in the signature
  too, or changes to it won't be indexed until something else changes.
- **Sharing with other people goes through CloudKit directly** (`Sharing`,
  two `CKSyncEngine`s), never SwiftData: SwiftData's sync can't share. A
  shared category is a zone of its own (`SharedZones.zoneName`), a record
  per item named by its uuid; the engine on your private database only
  fetches those zones, leaving SwiftData's zone alone. What others share
  arrives in the *Shared with Me* library (`LibraryInfo.sharedID`), on this
  device only. Both sides remember the signature of what they last sent or
  took in (`SharedItemPayload.signature`, which leaves out anything worked
  out, like read text and hashes, or every device would keep resending);
  `SharedMerge` decides whose change wins. Changes to your categories that
  arrive while another library is open wait in `Sharing/Waiting` (the main
  store syncs through SwiftData, so it's never opened twice). All of it
  runs only when `Sharing.shared` exists, which is only with `ICLOUD_SYNC` on.
- The search index can always be rebuilt from the library. Never store
  anything in it that exists nowhere else.
