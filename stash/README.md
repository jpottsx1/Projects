# Stash

Notes, documents and web links in one place, for Mac and iPhone/iPad. You
can link items to each other, put them in categories, tag them, and search
everything, including the text inside PDFs, saved web pages and photos of
text.

## Running it

1. Open `Stash.xcodeproj` in **Xcode 16 or later**.
2. In the toolbar, choose where to run it: **My Mac**, or an iPhone simulator.
3. Press **Cmd-R**.

The Mac version runs with no setup. To run it on **your own iPhone**, choose the
Stash target, open *Signing & Capabilities*, pick your Apple ID under
*Team*, and change the Bundle Identifier if Xcode says it's taken.

## What it does

| | |
|---|---|
| **Notes** | Written in Markdown, shown as a formatted preview. Ticking a `- [ ]` box in the preview ticks it in the note. |
| **Documents** | Any file: PDFs open in place, other files show a Quick Look preview. Each is copied into the app, so moving or deleting the original doesn't lose it. |
| **Links** | Paste or type a web address. The page's title and description are fetched, and its text is kept so searching finds it. |
| **Linking items** | Type `[[Title]]` in a note, or use *Link to Item…* in the side panel for any kind of item. Each item lists what it links to and what links to it. Renaming an item updates the `[[links]]` that point at it. Tapping a link to an item that doesn't exist yet creates it. |
| **Categories** | One per item, and they can nest. Choosing a category also shows everything in the categories inside it. |
| **Tags** | As many per item as you like. Type them separated by commas. Tags are single words: "to read" becomes `to-read`. |
| **Search** | Searches titles, text, tags, web page text, PDF text, and text found in images. Results are ranked, with title matches first. Use `"quotes"` for an exact phrase and `#tag` to only show items with that tag. |

New items go into whatever category or tag the sidebar is showing.
Dropping files or web addresses onto the list adds them.

## How it's built

```
Stash.xcodeproj
Stash/                  the app (SwiftUI + SwiftData), shared by Mac and iPhone
  StashApp.swift        window, menus
  Model/                Item, Tag, ItemCategory
  Library/              Library: every change goes through it
                        SearchIndex: SQLite full-text search
                        FileStore: copies of imported documents
                        TextExtractor: text from PDFs, images, web pages
  Views/
StashCore/              no-interface logic, with tests
                        [[link]] parsing, search syntax, Markdown blocks,
                        tag names, web page text
```

- **Data** is kept with SwiftData in the app's own storage. Imported files
  sit beside it in `Files/`, one folder per item.
- **The search index** is a separate SQLite FTS5 database. It's rebuilt from
  the library at every launch, so deleting it loses nothing.
- **iCloud sync is not on yet.** The data model already follows CloudKit's
  rules (every field has a default, every relationship is optional, nothing
  is unique), so switching it on shouldn't need a migration. Documents will
  need moving into CloudKit assets.

To run the `StashCore` tests, open the `StashCore` folder in Xcode and press
Cmd-U, or run `swift test` in it.

## Not done yet

- iCloud sync between Mac and iPhone
- A share extension, so you can save from Safari or other apps' share menus
- Suggestions while typing `[[`
- Full copies of web pages for reading offline (only the text is kept for now)
- An app icon
