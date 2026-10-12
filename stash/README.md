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
| **Notes** | Written in Markdown. *Write* shows it formatted as you type, as Typora does: headings large, bold bold, links tinted, with the Markdown marks tucked away except on the line you're editing. *Source* shows the plain Markdown, *Preview* the finished page, and *Split* (on a Mac or iPad) source and preview side by side. Formatting buttons above the note (on a Mac, with Cmd-B, Cmd-I and Cmd-K) or above the keyboard mark up the selected text: bold, italics, code, links, headings, lists, checkboxes, quotes. Ticking a `- [ ]` box in the preview ticks it in the note. |
| **Templates** | Notes kept under *Templates* in the sidebar to make others from: *New Note* there makes one, or *Save as Template* copies any note. *New from Template* (the + menu, or *File* on a Mac) makes a note from one, filling in `{{date}}`, `{{time}}`, `{{weekday}}`, `{{yesterday}}`, `{{tomorrow}}`, `{{title}}`, `{{clipboard}}`, and `{{date:EEEE d MMMM}}` in any date format, in its title and text. Its pictures, tags and category come along. |
| **Daily notes** | *Today's Note* (the + menu or the sidebar's ⋯ menu; Shift-Cmd-T on a Mac) opens the day's note, titled `2026-10-12`, making it the first time in the *Daily Notes* category. Tick *Daily Note* on a template to make each day's note from it. On a Mac, *Stash › Settings* changes the title's date format. |
| **Note history** | Each time you finish editing a note (and every ten minutes during a long session) the version before is kept, up to fifty. *History* in the side panel shows them; any can be put back, and what was there is kept as a version too. |
| **Documents** | Any file: PDFs and EPUB books open in place, other files show a Quick Look preview. Each is copied into the app, so moving or deleting the original doesn't lose it. Books remember where you stopped reading, on every device. |
| **Scanning** | On an iPhone or iPad, *Scan Documents* in the + menu photographs paper pages into one PDF. On a Mac, *File › Import from iPhone or iPad* does the same with Continuity Camera. Scans have their words laid invisibly over the pictures, so they can be searched, selected and highlighted. PDFs scanned elsewhere without any text are read the same way for search. |
| **Highlights** | Select text in a PDF, a book or a saved article and choose *Highlight* (or a colour, or *Highlight and Add Note*). Highlights are listed in the side panel, where choosing one scrolls to it; tapping one in the document opens its note. Highlights and notes are searchable, and the file itself is left untouched. |
| **Links** | Paste or type a web address. The page's title and description are fetched, and a full copy of the page (text, pictures and styles) is saved, so you can read it offline exactly as it was. Pages with an article also get a clean copy of just the article, without menus, ads or comments, shown by default (*Article* / *Full Page* above it). Its words are there offline; its pictures load from the web. Links saved before this get one when you choose *Refresh*. Search covers the page's words, including text the page adds itself once it has loaded. *Refresh* fetches it all again. |
| **Feeds** | *Subscribe to Feed…* takes a feed's address or just the site's (Stash finds the feed). RSS, Atom and JSON Feed. New posts arrive as unread links under the feed in the sidebar, saved with a clean article like any link; a post you've deleted doesn't come back. Feeds are checked when Stash opens and every hour while it's open (the ⋯ menu or *Settings* changes how often). Right-click a feed to check it, mark it read, rename it, file its new posts in a category, or unsubscribe. |
| **Indexed folders** | *Index Folder…* shows a folder's documents in Stash while the files stay where they are, as DEVONthink does. It gets a category, with one inside for each folder in it. Files added, changed, renamed, moved or deleted there are followed: at once on a Mac, when Stash comes to the front on an iPhone or iPad. A moved file keeps its tags, notes and highlights. Indexed files are only read, never changed; deleting one in Stash leaves the file alone. The folder belongs to the device that indexed it: others see its items, but not the files. *Indexed Folders…* lists them. |
| **Importing notes** | *Import from Evernote…* takes `.enex` exports: each becomes a category, with its notes' text, tags, dates, to-dos, tables, pictures (in the note) and other attachments (as documents linked from it). *Import Notes Folder…* takes a folder of Markdown, text and HTML files, as Obsidian, Bear, iA Writer and Apple Notes exporters make: front-matter titles, tags and dates are kept, pictures they show go into the notes, other files come in as documents, and folders become categories. |
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
| **Pictures and tables** | Paste, drop or add (the picture button) a picture into a note: Write mode shows it in place, as do Preview, printing and PDFs. Pictures are stored with the note and sync. Markdown tables show as tables; *Insert Table* and *Tidy Table* (which lines the columns up) are in the formatting bar. |
| **Outline and focus** | The outline button above a note lists its headings to jump to, and turns on focus mode, which dims everything but the paragraph you're writing. |
| **Link graph** | *Link Graph* (the sidebar's ⋯ menu, or Option-Cmd-G on a Mac) shows how items link to each other; choosing one opens it. |
| **Apple Intelligence** | On iOS and macOS 26 with Apple Intelligence on, the side panel can summarise an item, suggest tags and a category from the ones you use, and answer questions about it, all on the device. |
| **Merging and tidying** | Select several notes and *Merge Notes* to make one, each under its own heading, keeping their tags and links (links to the old notes point at the new one). An item saved twice can take in its copies (*Merge Copies Into This One* in the side panel), keeping their tags, notes and highlights. The side panel also suggests tags from similar items, and lists notes that mention an item without linking to it, with a button to make the links. |
| **Markup** | Draw, write, add shapes and sign on PDFs and pictures (*Mark Up* above them): Quick Look's markup on an iPhone or iPad, Preview on a Mac (changes are picked up when you come back to Stash). The file as first imported is kept on that device, and *Revert to Original* puts it back. |
| **Printing and PDF** | *Print…* (Cmd-P on a Mac) or *Save as PDF…* from an item's menu: notes, articles and saved pages laid out with their title, tags, notes and highlights; PDFs and pictures as they are. |
| **Widgets** | Recent items, favorites or reminders on the Home Screen or the Mac desktop, with a New Note button. They need the same App Group as sharing (`SHARE_EXTENSION`), since widgets can't open the library and read what the app writes there. |
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
  Model/                Item, Tag, ItemCategory, SmartFilter, Highlight, SmartRule,
                        NoteAttachment, NoteVersion, Feed, IndexedFolder
  Library/              Library: every change goes through it
                        SearchIndex: SQLite full-text search
                        FileStore: copies of imported documents
                        TextExtractor: text from PDFs, images, web pages
  Intents/              Shortcuts actions (App Intents)
  Views/
ShareExtension/         "Save to Stash" in share menus (StashShare target)
Widgets/                Home Screen and desktop widgets (StashWidgets target)
StashCore/              no-interface logic, with tests
                        [[link]] parsing, search syntax, Markdown blocks,
                        tag names, web page text, ZIP files, EPUB books,
                        highlight anchors, the backup format, templates,
                        feeds (RSS, Atom, JSON Feed), HTML to Markdown,
                        Evernote exports, indexed-folder changes
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
- **Feeds** are read by `FeedParser` (StashCore). Each feed remembers the
  posts it has seen (`Feed.seenIDs`), so deleting a post doesn't bring it
  back, and a post already in the library isn't added twice.
- **Indexed folders** are found again through a security-scoped bookmark,
  which only works on the device that made it. `FolderIndex` (StashCore)
  compares what's on disk with what the library last saw there; a file
  that vanishes as one the same size and age appears is a move. On a Mac
  FSEvents says when to look (`FolderWatcher`).
- **Importing** turns HTML into Markdown with `HTMLMarkdown` (StashCore),
  which reads Evernote's ENML too; Evernote names attachments by their MD5,
  worked out by `MD5`.
- `Config/Stash.xcconfig` holds both switches. The entitlements files next
  to it are chosen from them, and none is used when both are off.

To run the `StashCore` tests, open the `StashCore` folder in Xcode and press
Cmd-U, or run `swift test` in it.

The Mac UI tests (`StashUITests`) click through the app in a separate test
library, so your own is never touched: Cmd-U with the Stash scheme and My
Mac, or `xcodebuild test -scheme Stash -destination platform=macOS`. To try
the app by hand in the same way, launch it with `-StashTestLibrary YES`
(add `-StashResetTestLibrary YES` to start it empty). The test that
subscribes to a feed needs the internet, so it's skipped unless
`TEST_RUNNER_STASH_NETWORK_TESTS=1` is set.

## Not done yet

- An app icon
