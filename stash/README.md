# Stash

Notes, documents and web links in one place, for Mac and iPhone/iPad. You
can link items to each other, put them in categories, tag them, and search
everything, including the text inside PDFs, saved web pages and photos of
text.

## Running it

1. Open `Stash.xcodeproj` in **Xcode 26 or later**. It runs on macOS 26
   and later, and iOS 17.5 and later.
2. In the toolbar, choose where to run it: **My Mac**, or an iPhone simulator.
3. Press **Cmd-R**.

The Mac version runs with no setup. To run it on **your own iPhone**, choose the
Stash target, open *Signing & Capabilities*, pick your Apple ID under
*Team*, and change the Bundle Identifier if Xcode says it's taken.

## Syncing between Mac and iPhone

Sync goes through your iCloud account and is **off until you turn it on**,
because Apple only lets apps signed with a paid Apple Developer Program
membership use iCloud. With a free Apple ID the app works the same, just
without sync.

To turn it on:

1. In Xcode, select the **Stash** target, then **Signing & Capabilities**,
   and choose your paid team under **Team**.
2. Open `Config/Stash.xcconfig` and change `ICLOUD_SYNC = NO` to
   `ICLOUD_SYNC = YES`.
3. Run it on your Mac and your iPhone, both signed in to the same iCloud
   account.

The foot of the sidebar shows whether sync is working. If Xcode reports a
signing problem about the iCloud container, open *Signing & Capabilities*,
find the iCloud section, and tick the container `iCloud.com.jpottsx1.stash`.
If you changed the bundle identifier, change `ICLOUD_CONTAINER` in the same
file to match.

What syncs: every note, link and document, with their categories, tags and
links between items. Documents over 100 MB stay on the device they were
added on. A document from another device shows "Not on This Device Yet"
until iCloud has downloaded it.

If you made the same tag or category on two devices before they synced,
the two are merged into one automatically.

Before releasing through TestFlight or the App Store, deploy the CloudKit
schema to Production in the [CloudKit Console](https://icloud.developer.apple.com).
Builds run from Xcode use the Development environment, so you can skip this
until then.

## Saving from other apps

With this on, Stash appears in the share menu of Safari, Photos, Files, Mail
and most other apps. Share a web page, a file, some pictures or some text,
add a title, notes, tags and a category if you like, and tap Save. It
appears in Stash straight away if Stash is open, or the next time you open
it.

It's **off until you turn it on**, because it needs an App Group: a folder
Stash and its share extension both reach. A paid Apple Developer Program
membership allows that. With a free Apple ID it may or may not work; Apple
doesn't say, so try it and see.

1. In Xcode, select the **Stash** target, then **Signing & Capabilities**,
   and choose your team. Do the same for the **StashShare** target.
2. Open `Config/Stash.xcconfig` and change `SHARE_EXTENSION = NO` to
   `SHARE_EXTENSION = YES`.
3. Run Stash once on each device.

On a Mac, if Stash doesn't appear in a share menu, turn it on in
*System Settings › General › Login Items & Extensions › Sharing*. On an
iPhone, it may be under *More* at the end of the row of apps in the share
sheet.

If Xcode reports a signing problem about the App Group, open *Signing &
Capabilities* for each target, find App Groups, and tick
`group.com.jpottsx1.stash`. If you changed the bundle identifier, change
`APP_GROUP` in the same file to match.

## What it does

| | |
|---|---|
| **Notes** | Written in Markdown, shown as a formatted preview. Ticking a `- [ ]` box in the preview ticks it in the note. |
| **Documents** | Any file: PDFs open in place, other files show a Quick Look preview. Each is copied into the app, so moving or deleting the original doesn't lose it. |
| **Links** | Paste or type a web address. The page's title and description are fetched, and its text is kept so searching finds it. |
| **Linking items** | Type `[[` in a note and pick from the suggestions (arrows and Return or Tab on a keyboard, or tap one), or type `[[Title]]` in full, or use *Link to Item…* in the side panel for any kind of item. Each item lists what it links to and what links to it. Renaming an item updates the `[[links]]` that point at it. Tapping a link to an item that doesn't exist yet creates it. |
| **Categories** | One per item, and they can nest. Choosing a category also shows everything in the categories inside it. |
| **Tags** | As many per item as you like. Type them separated by commas. Tags are single words: "to read" becomes `to-read`. |
| **Search** | Searches titles, text, tags, web page text, PDF text, and text found in images. Results are ranked, with title matches first. Use `"quotes"` for an exact phrase and `#tag` to only show items with that tag. |

New items go into whatever category or tag the sidebar is showing.
Dropping files or web addresses onto the list adds them.

## How it's built

```
Stash.xcodeproj
Config/                 Stash.xcconfig (the sync and sharing switches),
                        entitlements, Info.plist additions
Stash/                  the app (SwiftUI + SwiftData), shared by Mac and iPhone
  StashApp.swift        window, menus
  Model/                Item, Tag, ItemCategory
  Library/              Library: every change goes through it
                        SearchIndex: SQLite full-text search
                        FileStore: copies of imported documents
                        TextExtractor: text from PDFs, images, web pages
  Views/
ShareExtension/         "Save to Stash" in share menus (StashShare target)
StashCore/              no-interface logic, with tests
                        [[link]] parsing, search syntax, Markdown blocks,
                        tag names, web page text
```

- **Data** is kept with SwiftData in the app's own storage. Imported files
  sit beside it in `Files/`, one folder per item.
- **The search index** is a separate SQLite FTS5 database. It's rebuilt from
  the library at every launch, so deleting it loses nothing.
- **Sync** is SwiftData's built-in CloudKit mirroring, into your private
  iCloud database. A document's contents are stored on its item (kept
  outside the database file), which is how files reach other devices.
  Each device writes them back out to `Files/` when first opened there.
  When changes arrive from iCloud, `Library` rebuilds the search index,
  merges duplicate tags and categories, and removes files for deleted
  documents.
- **Sharing** never touches the library from the share extension: two
  processes writing to an iCloud-synced database at once is asking for
  trouble. The extension leaves each thing in an inbox folder in the App
  Group (`SharedInbox` in StashCore), and the app takes it in at launch,
  when it comes to the front, or as soon as the extension signals. The
  app writes its category list into the same folder for the share sheet
  to offer.
- `Config/Stash.xcconfig` holds both switches. The entitlements files next
  to it are chosen from them, and none is used when both are off.

To run the `StashCore` tests, open the `StashCore` folder in Xcode and press
Cmd-U, or run `swift test` in it.

## Not done yet

- Full copies of web pages for reading offline (only the text is kept for now)
- An app icon
