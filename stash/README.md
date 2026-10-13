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

The share sheet's category field finds a category as you type, or makes a
new one (`Work › Clients` makes both). The same switch turns on two more
things that need the App Group:

- **Save to Stash in Safari** (the StashSafari target): a toolbar button
  that saves the page you're on as a link, in the Inbox. Turn it on in
  Safari's *Settings › Extensions*.
- **Stash in the Finder** (the StashFinder target): Stash appears under
  *Locations* in the Finder's sidebar, in Open and Save dialogs, and in
  the Files app, with a folder for each category and a file for each item
  (documents as themselves, notes as Markdown, links as `.webloc`).
  Renaming, moving, deleting, making folders, saving new files there and
  editing files there all change the library. Locked, trashed and
  indexed-folder items aren't shown.

Choose your team for the **StashSafari** and **StashFinder** targets too.

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
| **Calendar** | *Note for Event…* (the + menu, or *File › New Note for Event…*) makes a note for a meeting with when, where and who, linked to the event; any item can be linked to an event in the side panel, and opens it in Calendar. Turn on *Daily Notes List the Day's Events* (the sidebar's ⋯ menu, or *Settings*) and each day's note starts with the day's events; in a template, `{{events}}` puts them anywhere. Calendars are read on the device, with your permission. |
| **Daily notes** | *Today's Note* (the + menu or the sidebar's ⋯ menu; Shift-Cmd-T on a Mac) opens the day's note, titled `2026-10-12`, making it the first time in the *Daily Notes* category. Tick *Daily Note* on a template to make each day's note from it. On a Mac, *Stash › Settings* changes the title's date format. |
| **Voice notes** | *New Voice Note* (the + menu; Shift-Cmd-R on a Mac) records from the microphone; the microphone button above a note records into it, putting what you said at the cursor with a link to the recording. What's said is turned into text on the device (SpeechAnalyzer on iOS and macOS 26), so recordings are searchable, and imported audio and video under an hour are transcribed too (*Transcribe* does longer ones). Playing one shows the transcript following along; choosing a line plays from there. |
| **Note history** | Each time you finish editing a note (and every ten minutes during a long session) the version before is kept, up to fifty. *History* in the side panel shows them; any can be put back, and what was there is kept as a version too. |
| **Documents** | Any file: PDFs and EPUB books open in place, other files show a Quick Look preview. Each is copied into the app, so moving or deleting the original doesn't lose it. Books remember where you stopped reading, on every device. |
| **Scanning** | On an iPhone or iPad, *Scan Documents* in the + menu photographs paper pages into one PDF. On a Mac, *File › Import from iPhone or iPad* does the same with Continuity Camera. Scans have their words laid invisibly over the pictures, so they can be searched, selected and highlighted. PDFs scanned elsewhere without any text are read the same way for search. |
| **Highlights** | Select text in a PDF, a book or a saved article and choose *Highlight* (or a colour, or *Highlight and Add Note*). Highlights are listed in the side panel, where choosing one scrolls to it; tapping one in the document opens its note. Highlights and notes are searchable, and the file itself is left untouched. *Make Note* (in the side panel) gathers an item's highlights and notes into a note linked to it, with their pages, as DEVONthink's annotation files do; doing it again brings the note up to date. *Copy* puts them on the clipboard as Markdown, and *Export All Highlights…* writes every one in the library to a Markdown file. |
| **Links** | Paste or type a web address. The page's title and description are fetched, and a full copy of the page (text, pictures and styles) is saved, so you can read it offline exactly as it was. Pages with an article also get a clean copy of just the article, without menus, ads or comments, shown by default (*Article* / *Full Page* above it). Its words are there offline; its pictures load from the web. Links saved before this get one when you choose *Refresh*. Search covers the page's words, including text the page adds itself once it has loaded. *Refresh* fetches it all again. |
| **Feeds** | *Subscribe to Feed…* takes a feed's address or just the site's (Stash finds the feed). RSS, Atom and JSON Feed. New posts arrive as unread links under the feed in the sidebar, saved with a clean article like any link; a post you've deleted doesn't come back. Feeds are checked when Stash opens and every hour while it's open (the ⋯ menu or *Settings* changes how often); an iPhone or iPad also checks now and then in the background, as often as iOS allows. Subscriptions are kept in *Export Everything* backups. Right-click a feed to check it, mark it read, rename it, file its new posts in a category, or unsubscribe. |
| **Indexed folders** | *Index Folder…* shows a folder's documents in Stash while the files stay where they are, as DEVONthink does. It gets a category, with one inside for each folder in it. Files added, changed, renamed, moved or deleted there are followed: at once on a Mac, when Stash comes to the front on an iPhone or iPad. A moved file keeps its tags, notes and highlights. Indexed files are only read, never changed; deleting one in Stash leaves the file alone. The folder belongs to the device that indexed it: others see its items, but not the files. *Indexed Folders…* lists them. |
| **Importing notes** | *Import from Evernote…* takes `.enex` exports: each becomes a category, with its notes' text, tags, dates, to-dos, tables, pictures (in the note) and other attachments (as documents linked from it). *Import Notes Folder…* takes a folder of Markdown, text and HTML files, as Obsidian, Bear, iA Writer and Apple Notes exporters make: front-matter titles, tags and dates are kept, pictures they show go into the notes, other files come in as documents, and folders become categories. |
| **Email** | Import `.eml` files like any document, drag messages in from Mail, or *Import Mailbox…* for an `.mbox` (Mail's *Export Mailbox* makes one). Each message is kept as it was, titled with its subject and dated when it was sent; it shows its sender, recipients, text and attachments (*Add to Stash* takes one in as a document, linked to the email). Search covers who it's from and to, and `kind:email` finds them. A message already in the library isn't imported twice. |
| **Linking items** | Type `[[` in a note and pick from the suggestions (arrows and Return or Tab on a keyboard, or tap one), or type `[[Title]]` in full, or use *Link to Item…* in the side panel for any kind of item. Each item lists what it links to and what links to it. Renaming an item updates the `[[links]]` that point at it. Tapping a link to an item that doesn't exist yet creates it. |
| **Categories** | One per item, and they can nest. Choosing a category also shows everything in the categories inside it. |
| **Tags** | As many per item as you like. Type them separated by commas. Tags are single words: "to read" becomes `to-read`. |
| **Search** | Searches titles, text, tags, web page text, PDF text, and text found in images. Results are ranked, with title matches first. Use `"quotes"` for an exact phrase, `OR` for either word, `-word` to leave items out, `#tag` (or `-#tag`) for tags, `kind:pdf` (note, link, document, pdf, image, video, audio), `in:Category`, `list:Name`, `is:favorite`, `is:unread`, `is:inbox`, `is:untagged`, `is:readlater`, `label:red`, `rating:3` (three stars or more), and `after:`/`before:` with a date (`2026-03-01`) or a time ago (`today`, `7d`, `2w`, `3m`, `1y`). `created:` and `modified:` take a day (`created:2026-03-01`), on or after it (`created:>7d`) or before it (`modified:<1y`); `size:>1mb` and `size:<500kb` go by a document's file or a note's text; `source:example.com` finds links and feed posts from a site. |
| **Lists** | Put items in lists of your own (*Add to List* in an item's menu or side panel), as many as you like, besides their one category, as Keep It's lists and DEVONthink's replicants do. A list keeps the order you drag its items into. Search with `list:Name`. |
| **Custom fields** | Fields of your own on items, as DEVONthink's custom metadata: text, a number, a date, yes or no, or a choice (*Edit Fields…* in the side panel). Set them in the side panel; they show as columns in the column view, and search finds them by name: `Price:>20`, `Due:2026-11`, `Done:yes` (write a space in a field's name as `_`). |
| **Read Later and Timeline** | *Read Later* (an item's menu, or Control-Cmd-R on a Mac) queues things to read; the queue, in the sidebar, shows how far through each you are, and PDFs, books and articles open where you stopped. *Timeline* shows a month's calendar with a dot on each day something was added (or changed), and that day's items. |
| **Quick Open and Quick File** | Cmd-O (the sidebar's ⋯ menu on iPhone) opens any item, category, list, tag, smart filter or feed by typing a little of its name; Control-Cmd-M (*Move to Category…*) files the selected items the same way. The search field suggests tags, categories, lists, kinds, `is:` filters and your fields as you type. `is:checklist` finds notes with checkboxes, `is:highlighted` items with highlights, and pictures can be found by what's in them ("dog", "beach"), read on the device. Opened from a search, a note or PDF shows the first match. |
| **Smart filters** | Save any search in the sidebar (the button beside the search field, or *New Smart Filter*). It shows whatever matches now. A smart filter can search the whole library or just one category (and those inside it) or one list (*Search In*, or *New Smart Filter Here…* on a category or list); it then sits inside that category or under that list in the sidebar. Saved from a category or list, it searches there. |
| **Tag filter** | The tag button above the list shows the tags on the items shown, most used first, with how many have each. Choose one to see only items with it, and the tags those items also have; choose another to narrow it further. It works with the search and whatever the sidebar is showing, and *Save as Smart Filter* keeps the tags chosen. |
| **Recents and Unfiled** | *Recents* lists what was added, looked at or changed lately, most recent first (choose which, and today, the last 7, 14 or 30 days). *Unfiled* lists everything in no category. |
| **Item links and automation** | *Copy Link › Copy Item Link* (Control-Cmd-C on a Mac) copies `stash://item?id=…`, to paste into Calendar, Reminders, another notes app or a Stash note; clicking it opens the item. *Copy Markdown Link* copies `[Title](stash://item?id=…)`. Other apps and automation tools can use `stash://new-note?title=…&text=…`, `stash://save-link?url=…`, `stash://add-to-today?text=…`, `stash://today`, `stash://search?query=…` and `stash://open?title=…`, and the same as x-callback-url (`stash://x-callback-url/new-note?…&x-success=…`), which goes back with the new item's `id` and `link`. |
| **Sorter (Mac)** | *Window › Sorter* (Control-Cmd-S) is a small window that floats above other apps, listing the Inbox and every category. Drop files, web addresses, pictures or text onto one to file them there, or type a note into the one chosen. |
| **Scheduled rules** | Besides new arrivals, a smart rule can run over everything that matches when Stash opens, or every hour, day or week while it's open (*Also Run* in the rule). |
| **Concordance** | *Concordance* (the sidebar's ⋯ menu, or the Item menu on a Mac) lists the words used in the items chosen, the items shown or the whole library, how often and in how many items, as DEVONthink's does, leaving out common English words. *Cloud* shows them as a word cloud. Choosing a word searches for it. |
| **Image search** | *Search Image With* (a picture's menu, or *Item* on a Mac) looks it up with Google Lens, Bing Visual Search, TinEye or Yandex Images. Those sites can only fetch a picture from the web, never a file on your device, so a picture is searched for by the address it came from: the Mac's "Where from" on a download, the page it was dragged out of, a link straight to a picture, or one typed into *Came From* in the side panel. A picture with no address is copied instead, and the site's search page opened to paste it into. |
| **Import destination** | Right-click a category and choose *Use as Import Destination*: things that arrive with no category (shared, saved from Safari, Services, Shortcuts, quick capture, files dropped on the window) go there instead of the Inbox, as Keep It's default import destination. |
| **Inbox** | Links, documents and things shared from other apps or saved by Shortcuts arrive in the Inbox unless they already have a category. Giving one a category files it; *Done* takes it out without one. |
| **Unread** | New arrivals have a blue dot until you look at them. *Mark as Unread* puts it back. |
| **Labels and ratings** | A colour label (as in the Finder) and up to five stars, from an item's menu or its side panel. Sort by either, or search with `label:red` and `rating:4`. |
| **Smart rules** | *Smart Rules…* (in the sidebar's ⋯ menu, or the Item menu on a Mac) does things to items as they arrive when they match a search: file them, add tags, set a label or rating, star them, mark them read or done. Say, `invoice kind:pdf` → file in Finance and tag `money`. Rules run when an item arrives on that device, and again once its page or document has been read, so they can match words inside it. *Apply to Matching Items Now* runs one over what's already there. |
| **Thumbnails, grid and columns** | Documents and saved pages show a small picture in the list. Wider windows can show items as a grid of cards, or in columns (title, kind, category, tags, label, rating, dates) sorted by clicking a heading. |
| **Locked items** | *Lock* an item (its menu, or Control-Cmd-L on a Mac) to encrypt it: its text, notes, highlights, transcript, saved page, pictures and file are sealed with AES-GCM, on this device and in iCloud, leaving only its title and tags readable and searchable. The first time, you choose a locking password; the key it guards is kept in the library, so every device opens locked items with the same password, and an iPhone or iPad can remember it behind Face ID or Touch ID. Unlocked, an item opens for reading and writing, decrypted in memory and in temporary copies that are deleted when it locks again, which it does when you leave Stash. *Remove Lock* decrypts it for good. Backups keep locked items encrypted, with the key still under its password. Forget the password and locked items can't be opened. Items locked before encryption are encrypted the first time the password is given. |
| **Selecting several** | Shift-click or Cmd-click in the list or grid on a Mac, or tap *Edit* on an iPhone or iPad, to choose several items. Then tag, file, label, rate, star, remind, mark read or done, export or trash them all at once, from the right-click menu, the panel beside the list, the Item menu, or the *Actions* button. |
| **Reminders** | *Remind Me* on an item (later today, tomorrow morning, this weekend, next week, or a time you choose) sends a notification then, and choosing it opens the item. *Reminders* in the sidebar lists them soonest first, counting those that have come round. Search with `is:due` or `is:reminder`. Reminders sync; each device notifies. |
| **AppleScript (Mac)** | Script Stash from Script Editor, Automator, Keyboard Maestro and the like, as DEVONthink can be: `items`, `categories`, `tags` and the `selected items`, each item's name, text, URL, file, tags, category, dates, favorite, unread, label and rating (most can be set), and the commands `search`, `create note`, `save link`, `import`, `add tags … to`, `show` and `add to today's note`. *File › Open Dictionary* in Script Editor shows it all. For example: `tell application "Stash" to create note "Milk, eggs" titled "Shopping"`. |
| **Handoff** | The item you're looking at can be picked up on your other devices, from the Dock on a Mac or the app switcher on an iPhone; a saved link opens in the browser where Stash isn't. Only items in the main library, and only with Stash signed with your developer team on each device. |
| **Statistics** | *Statistics* (the sidebar's ⋯ menu, or the Item menu on a Mac) shows how the library has grown: items by kind each month for the last year, words written in new notes, top tags and categories, the reading queue, highlights, and each feed's posts in the last month. |
| **Services (Mac)** | *Save to Stash* is in every app's Services menu (and on Cmd-Shift-K, which *System Settings › Keyboard › Keyboard Shortcuts › Services* can change): the selected text becomes a note, a web address a link, and Finder's selected files documents, all in the Inbox. *Add to Today's Note in Stash* adds the selected text to the day's note. |
| **Quick capture** | On a Mac, Stash's menu bar icon jots a note or saves the web address on the clipboard from anywhere (hide it in *Stash › Settings*). On an iPhone or iPad, touch and hold Stash's icon for *New Note*, *Scan Document* and *Save Copied Link*. Notes and links saved this way go to the Inbox. |
| **Pictures and tables** | Paste, drop or add (the picture button) a picture into a note: Write mode shows it in place, as do Preview, printing and PDFs. *Picture Size* limits the one on the cursor's line (written `![alt|300](…)`, as Obsidian does). Pictures are stored with the note and sync. Markdown tables show as tables; the table menu inserts and tidies them and adds and deletes rows and columns. Tab and Shift-Tab (or the indent buttons) nest list and checklist items. The outline menu sets the margins and shows a word count. *Make a Note* turns a saved page, an email or a text, rich-text or HTML document into a note. |
| **Sketches** | The pencil button above a note draws a sketch into it: with PencilKit's tools and an Apple Pencil or a finger on an iPhone or iPad, with the mouse or trackpad (colours, widths, undo) on a Mac. Put the cursor on a sketch's line and press it again to change it. Handwriting in sketches, and words in any picture in a note, are read on the device so search finds them. |
| **Outline and focus** | The outline button above a note lists its headings to jump to, and turns on focus mode, which dims everything but the paragraph you're writing. |
| **Link graph** | *Link Graph* (the sidebar's ⋯ menu, or Option-Cmd-G on a Mac) shows how items link to each other; choosing one opens it. |
| **Ask your library** | *Ask Your Library…* (the sidebar's ⋯ menu, or Option-Cmd-A on a Mac) answers questions about everything you've saved, as DEVONthink's chat does: it finds the items most likely to know, gives the on-device model the passage of each that bears on the question, and lists the ones the answer came from, to open. Locked items are left out. |
| **Apple Intelligence** | On iOS and macOS 26 with Apple Intelligence on, the side panel can summarise an item, suggest tags and a category from the ones you use, and answer questions about it, all on the device. |
| **Merging and tidying** | Select several notes and *Merge Notes* to make one, each under its own heading, keeping their tags and links (links to the old notes point at the new one). An item saved twice can take in its copies (*Merge Copies Into This One* in the side panel), keeping their tags, notes and highlights. The side panel also suggests tags from similar items, and lists notes that mention an item without linking to it, with a button to make the links. |
| **PDF pages** | *Pages* beside a PDF shows its pages as thumbnails, or its outline, to go to; drag pages into another order or delete them (highlights move with their pages; *Revert to Original* undoes it). Highlights can be in a colour of your own (*Custom Color*, chosen beside them). Over a link in a saved page or article, its address shows at the bottom, as in Safari. *Import Bookmarks…* brings in a browser's exported bookmarks, with their folders as categories, their tags, and when they were bookmarked. |
| **Markup** | Draw, write, add shapes and sign on PDFs and pictures (*Mark Up* above them): Quick Look's markup on an iPhone or iPad, Preview on a Mac (changes are picked up when you come back to Stash). The file as first imported is kept on that device, and *Revert to Original* puts it back. |
| **Printing and PDF** | *Print…* (Cmd-P on a Mac) or *Save as PDF…* from an item's menu: notes, articles and saved pages laid out with their title, tags, notes and highlights; PDFs and pictures as they are. |
| **Widgets** | Recent items, favorites or reminders on the Home Screen or the Mac desktop, with a New Note button. They need the same App Group as sharing (`SHARE_EXTENSION`), since widgets can't open the library and read what the app writes there. |
| **Libraries** | Separate libraries, as DEVONthink's databases: *Library › Manage Libraries…* (the sidebar's ⋯ menu on an iPhone or iPad) makes, renames, opens and deletes them, and Control-Cmd-1 to 9 switch between them on a Mac. Each has its own items, categories, tags, lists, fields and feeds. The main library is the one that syncs with iCloud and appears in Spotlight, reminders and widgets; others stay on the device they were made on. |
| **iPad** | With a keyboard, the menu bar has the shortcuts (Cmd-N, Shift-Cmd-T, Cmd-D, Cmd-[ and so on). *Open in New Window* puts an item in a window of its own beside the library. Items drag out to other apps (notes as text, links as addresses, documents as files), and files, pictures, links and text drag in. Cards lift under the pointer. |
| **Windows and tabs** | On a Mac, double-click an item (or *Item › Open in New Window*, Option-Cmd-O) to open it in a window of its own, or *Open in New Tab* to add it as a tab. *Go › Back* and *Forward* (Cmd-[ and Cmd-], or the arrows above the item) move between items you've looked at. |
| **Favorites** | Star an item from its toolbar, its menu, a swipe, or Cmd-D on a Mac. |
| **Trash** | Deleted items go to the Trash, where they can be put back, for 30 days. |
| **Sorting** | By date modified, date created, title or kind, either way round, with *Favorites First* if you like. Search results always come best match first. Categories can be given a colour and moved up and down by hand (right-click), smart filters dragged into order, and items, categories and smart filters duplicated. |
| **See Also** | The side panel lists items most like the one you're looking at, from the words they share, and suggests a category for an uncategorized item from where those are. |
| **Duplicates** | Pages saved twice (however their addresses are written) and files imported twice are listed under *Duplicates* in the sidebar, and in each copy's side panel. |
| **Mind maps** | *New Mind Map* (the + menu, or *File*) makes a note drawn as a map: the centre on the left, branches to the right. Tab adds a branch, Return a node beside, Delete removes one, double-click renames, and dragging a node onto another moves its branch there. A node can link to an item (`[[Title]]`). It's kept as a nested list, so *Outline* edits it as text, and search, sync and other apps read it as one. *Export* copies the outline or saves a picture of the map into Stash. |
| **Export and backup** | Export an item, a category or everything (*File › Export*, or the sidebar's backup menu) as a ZIP file: a folder per category, notes and links as Markdown, documents as they were, saved pages as web archives, readable without Stash. *Restore from Backup* adds back anything in an export that isn't already in the library, with its categories, tags, links, highlights and smart filters. |
| **Shortcuts and Spotlight** | In Shortcuts and Siri: Add Note, Save Link, Find Items, Open Item, Open Today's Note, Add to Today's Note, Record Voice Note, Read Later, Get Read Later Queue, Add to List, Get Items in List, Set Field, Get Field, Subscribe to Feed, Check Feeds and Ask Your Library (which answers aloud in Siri). Items appear in the system's Spotlight search, and open in Stash. |
| **Board** | The fourth view beside list, grid and columns: items as cards in columns, by label, by top-level category or by one of your choice fields. Drag a card to another column to give it that label, category or value. |
| **Batch rename and convert** | *Rename…* on several items at once: find and replace (with regular expressions if you like), add text before or after, or new titles from a pattern (`{title}`, a counter `{n}`, `{date}` or `{date:d MMM yyyy}`, `{kind}`), previewed before anything changes; `[[links]]` follow. *Convert To* makes a PDF, Markdown or plain-text document of notes and links, filed and tagged like them and linked from them. |

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
SafariExtension/        Safari's Save to Stash button (StashSafari target)
FinderExtension/        Stash in the Finder and Files (StashFinder target)
Widgets/                Home Screen and desktop widgets (StashWidgets target)
StashCore/              no-interface logic, with tests
                        [[link]] parsing, search syntax, Markdown blocks,
                        tag names, web page text, ZIP files, EPUB books,
                        highlight anchors, the backup format, templates,
                        feeds (RSS, Atom, JSON Feed), HTML to Markdown,
                        Evernote exports, indexed-folder changes,
                        transcripts, email (MIME and mbox), highlight summaries
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
  to offer. The Safari extension leaves links in the same inbox.
- **The Finder** works the same way round (`FinderShare` in StashCore):
  the app publishes a snapshot of folders and files into the App Group,
  with each file's contents beside it (documents hard-linked where they
  can be), and the File Provider extension serves those. What's done in
  the Finder comes back as requests the app carries out, after which it
  publishes again. The extension never opens the library.
- **Backups** keep everything that syncs: category colours and order,
  smart filter order, custom highlight colours, linked calendar events,
  text read from pictures, and mind maps. Lists, fields and feeds made
  twice on two devices are merged as tags and categories are.
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
- **Transcripts** (`Transcriber`) come from SpeechAnalyzer's
  SpeechTranscriber on iOS and macOS 26, which downloads the language's
  model the first time, and SFSpeechRecognizer on earlier iPhones. Each is
  kept on its item as a `Transcript` (StashCore): phrases with their times.
- **Libraries** (`StashStore`): the main library's store is where it always
  was; each other library has a folder of its own in
  `Application Support/Stash Libraries/<id>/`, with its store, files and
  search index. Switching closes one `Library` (its feed timer and folder
  watchers stop) and opens the other; the windows start again with it.
- **Encryption** (`Vault`): a random 256-bit key, kept in the library
  sealed with a key derived from the locking password (PBKDF2-SHA256,
  600,000 rounds). A locked item's text is one AES-GCM sealed box
  (`SealedContents` in StashCore); its files are each sealed in place,
  marked so they're never taken for the real thing (`SealedFormat`).
  Unlocked items are decrypted into memory, and their files into a
  temporary folder emptied on relocking. Text written before an item was
  locked can linger in the database file's free space, and in iCloud's
  history, until it's overwritten.
- **A big library**: the search index keeps a signature of what each
  entry was made from (`SearchIndex.sync`), so launching and taking in
  changes from iCloud only index what's changed, and Spotlight is only
  sent those. The sidebar's badges are counted by the store, once per save.
  To try Stash with 10,000 made-up items, launch the test library with
  `-StashGenerateItems 10000` (with `-StashResetTestLibrary YES`, or it adds
  another 10,000), or choose *Add 10,000 Test Items* from its ⋯ menu; timings
  go to the log under the `performance` category.
- **Ask Your Library** searches the index for the question's telling words,
  takes the best passage of each of the top five items (`LibraryQuestion`
  in StashCore), and has the on-device model answer from those alone,
  citing them by number.
- **Email** stays as the original `.eml` file; `MIMEMessage` (StashCore)
  reads its headers, text and attachments when it's shown or searched.
  HTML mail is shown as Markdown, so no scripts run and no pictures load
  from the sender's servers.
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

- Locking a document in an indexed folder (its file stays in the folder,
  where Stash can't encrypt it).
