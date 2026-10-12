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
| **Notes** | Written in Markdown, shown as a formatted preview, or both side by side on a Mac or iPad (*Split*). Formatting buttons above the note (on a Mac, with Cmd-B, Cmd-I and Cmd-K) or above the keyboard mark up the selected text: bold, italics, code, links, headings, lists, checkboxes, quotes. Ticking a `- [ ]` box in the preview ticks it in the note. |
| **Note history** | Each time you finish editing a note (and every ten minutes during a long session) the version before is kept, up to fifty. *History* in the side panel shows them; any can be put back, and what was there is kept as a version too. |
| **Documents** | Any file: PDFs and EPUB books open in place, other files show a Quick Look preview. Each is copied into the app, so moving or deleting the original doesn't lose it. Books remember where you stopped reading, on every device. |
| **Scanning** | On an iPhone or iPad, *Scan Documents* in the + menu photographs paper pages into one PDF. On a Mac, *File › Import from iPhone or iPad* does the same with Continuity Camera. Scans have their words laid invisibly over the pictures, so they can be searched, selected and highlighted. PDFs scanned elsewhere without any text are read the same way for search. |
| **Highlights** | Select text in a PDF, a book or a saved article and choose *Highlight* (or a colour, or *Highlight and Add Note*). Highlights are listed in the side panel, where choosing one scrolls to it; tapping one in the document opens its note. Highlights and notes are searchable, and the file itself is left untouched. |
| **Links** | Paste or type a web address. The page's title and description are fetched, and a full copy of the page (text, pictures and styles) is saved, so you can read it offline exactly as it was. Pages with an article also get a clean copy of just the article, without menus, ads or comments, shown by default (*Article* / *Full Page* above it). Its words are there offline; its pictures load from the web. Links saved before this get one when you choose *Refresh*. Search covers the page's words, including text the page adds itself once it has loaded. *Refresh* fetches it all again. |
| **Linking items** | Type `[[` in a note and pick from the suggestions (arrows and Return or Tab on a keyboard, or tap one), or type `[[Title]]` in full, or use *Link to Item…* in the side panel for any kind of item. Each item lists what it links to and what links to it. Renaming an item updates the `[[links]]` that point at it. Tapping a link to an item that doesn't exist yet creates it. |
| **Categories** | One per item, and they can nest. Choosing a category also shows everything in the categories inside it. |
| **Tags** | As many per item as you like. Type them separated by commas. Tags are single words: "to read" becomes `to-read`. |
| **Search** | Searches titles, text, tags, web page text, PDF text, and text found in images. Results are ranked, with title matches first. Use `"quotes"` for an exact phrase, `OR` for either word, `-word` to leave items out, `#tag` (or `-#tag`) for tags, `kind:pdf` (note, link, document, pdf, image, video, audio), `in:Category`, `is:favorite`, `is:unread`, `is:inbox`, `is:untagged`, `label:red`, `rating:3` (three stars or more), and `after:`/`before:` with a date (`2026-03-01`) or a time ago (`today`, `7d`, `2w`, `3m`, `1y`). |
| **Smart filters** | Save any search in the sidebar (the button beside the search field, or *New Smart Filter*). It shows whatever matches now. |
| **Inbox** | Links, documents and things shared from other apps or saved by Shortcuts arrive in the Inbox unless they already have a category. Giving one a category files it; *Done* takes it out without one. |
| **Unread** | New arrivals have a blue dot until you look at them. *Mark as Unread* puts it back. |
| **Labels and ratings** | A colour label (as in the Finder) and up to five stars, from an item's menu or its side panel. Sort by either, or search with `label:red` and `rating:4`. |
| **Smart rules** | *Smart Rules…* (in the sidebar's ⋯ menu, or the Item menu on a Mac) does things to items as they arrive when they match a search: file them, add tags, set a label or rating, star them, mark them read or done. Say, `invoice kind:pdf` → file in Finance and tag `money`. Rules run when an item arrives on that device, and again once its page or document has been read, so they can match words inside it. *Apply to Matching Items Now* runs one over what's already there. |
| **Thumbnails, grid and columns** | Documents and saved pages show a small picture in the list. Wider windows can show items as a grid of cards, or in columns (title, kind, category, tags, label, rating, dates) sorted by clicking a heading. |
| **Locked items** | *Lock* an item to keep its contents out of sight until you unlock it with Face ID, Touch ID or your password; they lock again when you leave the app. While locked, only its title and tags are searchable, and it's left out of Spotlight. Its contents aren't encrypted, and exports include them. Needs a passcode on the device. |
| **Selecting several** | Shift-click or Cmd-click in the list or grid on a Mac, or tap *Edit* on an iPhone or iPad, to choose several items. Then tag, file, label, rate, star, remind, mark read or done, export or trash them all at once, from the right-click menu, the panel beside the list, the Item menu, or the *Actions* button. |
| **Reminders** | *Remind Me* on an item (later today, tomorrow morning, this weekend, next week, or a time you choose) sends a notification then, and choosing it opens the item. *Reminders* in the sidebar lists them soonest first, counting those that have come round. Search with `is:due` or `is:reminder`. Reminders sync; each device notifies. |
| **Quick capture** | On a Mac, Stash's menu bar icon jots a note or saves the web address on the clipboard from anywhere (hide it in *Stash › Settings*). On an iPhone or iPad, touch and hold Stash's icon for *New Note*, *Scan Document* and *Save Copied Link*. Notes and links saved this way go to the Inbox. |
| **Favorites** | Star an item from its toolbar, its menu, a swipe, or Cmd-D on a Mac. |
| **Trash** | Deleted items go to the Trash, where they can be put back, for 30 days. |
| **Sorting** | By date modified, date created, title or kind, either way round. Search results always come best match first. |
| **See Also** | The side panel lists items most like the one you're looking at, from the words they share, and suggests a category for an uncategorized item from where those are. |
| **Duplicates** | Pages saved twice (however their addresses are written) and files imported twice are listed under *Duplicates* in the sidebar, and in each copy's side panel. |
| **Export and backup** | Export an item, a category or everything (*File › Export*, or the sidebar's backup menu) as a ZIP file: a folder per category, notes and links as Markdown, documents as they were, saved pages as web archives, readable without Stash. *Restore from Backup* adds back anything in an export that isn't already in the library, with its categories, tags, links, highlights and smart filters. |
| **Shortcuts and Spotlight** | Add Note, Save Link, Find Items and Open Item actions in Shortcuts and Siri. Items appear in the system's Spotlight search, and open in Stash. |

New items go into whatever category or tag the sidebar is showing.
Dropping files or web addresses onto the list adds them.

## How it's built

```
Stash.xcodeproj
Config/                 Stash.xcconfig (the sync and sharing switches),
                        entitlements, Info.plist additions
Stash/                  the app (SwiftUI + SwiftData), shared by Mac and iPhone
  StashApp.swift        window, menus
  Model/                Item, Tag, ItemCategory, SmartFilter, Highlight, SmartRule
  Library/              Library: every change goes through it
                        SearchIndex: SQLite full-text search
                        FileStore: copies of imported documents
                        TextExtractor: text from PDFs, images, web pages
  Intents/              Shortcuts actions (App Intents)
  Views/
ShareExtension/         "Save to Stash" in share menus (StashShare target)
StashCore/              no-interface logic, with tests
                        [[link]] parsing, search syntax, Markdown blocks,
                        tag names, web page text, ZIP files, EPUB books,
                        highlight anchors, the backup format
```

- **Data** is kept with SwiftData in the app's own storage. Imported files
  sit beside it in `Files/`, one folder per item.
- **The search index** is a separate SQLite FTS5 database. It's rebuilt from
  the library at every launch, so deleting it loses nothing. *See Also*
  uses it too: it picks the item's rarest frequent words (`Keywords` in
  StashCore) and searches for any of them. Spotlight's copy
  (`SpotlightIndex`) is rebuilt the same way.
- **Sync** is SwiftData's built-in CloudKit mirroring, into your private
  iCloud database. A document's contents are stored on its item (kept
  outside the database file), which is how files reach other devices.
  Each device writes them back out to `Files/` when first opened there.
  When changes arrive from iCloud, `Library` rebuilds the search index,
  merges duplicate tags and categories, and removes files for deleted
  documents.
- **Saved pages** are Safari web archives, made by loading the page in a
  browser view nobody sees (`PageArchiver`), so pages that build
  themselves with JavaScript are copied as shown. They sit in `Files/`
  beside documents and sync the same way, up to the same size limit.
- **Books** are read straight from the EPUB file: `EPUBReader` serves its
  chapters to a web view from inside the ZIP. A highlight in a book is
  remembered by its words and a little of the text either side
  (`TextQuote`), so it's found again however the chapter is laid out; one in
  a PDF by the rectangles it covers on its page.
- **Clean articles** are found by a script run in the page while
  `PageArchiver` copies it (`Article.script`), scoring blocks of text much
  as Mozilla's Readability does. The same visit takes the thumbnail.
- **Scans** are built by `ScannedPDF`: each page is the photo, with the
  words Vision reads from it drawn invisibly on top.
- **Exports** are ZIP files written straight to disk (`ZipWriter`, ZIP64 for
  very large libraries), with `Stash Backup.json` beside the readable files
  holding everything needed to restore them.
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

- An app icon
