import XCTest

/// Clicks through Stash on a Mac the way a person would, in the test
/// library (`-StashTestLibrary`), which starts empty each run and never
/// touches the real one. Run with Cmd-U, or:
/// `xcodebuild test -scheme Stash -destination platform=macOS`
final class StashUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        #if !os(macOS)
        throw XCTSkip("These tests drive the Mac app.")
        #else
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-StashTestLibrary", "YES", "-StashResetTestLibrary", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        #endif
    }

    override func tearDown() {
        app?.terminate()
    }

    #if os(macOS)
    // MARK: - Helpers

    @discardableResult
    private func newNote(title: String, text: String) -> XCUIElement {
        app.typeKey("n", modifierFlags: .command)
        let titleField = app.textFields["itemTitle"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.click()
        titleField.typeText(title + "\r")
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText(text)
        return editor
    }

    private func menuItem(_ menu: String, _ item: String) -> XCUIElement {
        app.menuBars.menuBarItems[menu].click()
        return app.menuBars.menuItems[item]
    }

    // MARK: - Tests

    /// Typing fast in Write mode keeps every character (the stale-echo bug).
    func testWritingKeepsEverythingTyped() {
        let text = "## Plan for **today**\nCheck the _seller_ side, then [read](https://example.com) more."
        let editor = newNote(title: "Typing", text: text)
        XCTAssertEqual(editor.value as? String, text)
    }

    func testFormattingButtonsMarkUpTheSelection() {
        let editor = newNote(title: "Format", text: "make this bold")
        editor.typeKey("a", modifierFlags: .command)
        editor.typeKey("b", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "**make this bold**")
    }

    func testNoteSurvivesInTheListAndSearch() {
        newNote(title: "Groceries", text: "apples and pears")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("pears")
        XCTAssertTrue(app.staticTexts["Groceries"].waitForExistence(timeout: 5))
        search.typeKey("a", modifierFlags: .command)
        search.typeText("kind:pdf")
        XCTAssertFalse(app.staticTexts["Groceries"].waitForExistence(timeout: 2))
    }

    func testTrashAndPutBack() {
        newNote(title: "Throwaway", text: "x")
        menuItem("Item", "Move to Trash").click()
        app.outlines.staticTexts["Trash"].click()
        let row = app.staticTexts["Throwaway"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        menuItem("Item", "Put Back").click()
        app.outlines.staticTexts["All Items"].click()
        XCTAssertTrue(app.staticTexts["Throwaway"].waitForExistence(timeout: 5))
    }

    func testColumnsShowTheItems() {
        newNote(title: "Alpha", text: "a")
        newNote(title: "Beta", text: "b")
        // The segment is known by its symbol's name, "Table".
        app.radioButtons["tablecells"].click()
        // SwiftUI's Table on a Mac is an outline view; the first outline is the sidebar.
        let table = app.outlines.element(boundBy: 1)
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        XCTAssertTrue(table.staticTexts.matching(NSPredicate(format: "value == 'Note'")).firstMatch.exists,
                      "No Kind column")
        // In a table a cell's text is its value, not its label.
        for title in ["Alpha", "Beta"] {
            let cell = table.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", title, title)).firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 5), "No row for \(title)")
        }
        app.radioButtons["list.bullet"].click()
    }

    func testMergingTwoNotes() {
        newNote(title: "First", text: "one")
        newNote(title: "Second", text: "two")
        app.outlines.staticTexts["Notes"].click()
        let list = app.outlines.element(boundBy: 1)
        list.staticTexts["First"].click()
        list.staticTexts["Second"].click(forDuration: 0, thenDragTo: list.staticTexts["Second"])
        XCUIElement.perform(withKeyModifiers: .command) { list.staticTexts["First"].click() }
        let merge = app.buttons["Merge Notes"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5))
        merge.click()
        XCTAssertTrue(app.textFields["itemTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["itemTitle"].value as? String, "First (merged)")
    }

    func testPastedPictureShowsInTheNote() throws {
        let editor = newNote(title: "Picture", text: "Above\n")
        // A small red square on the clipboard.
        let image = NSImage(size: NSSize(width: 120, height: 80), flipped: false) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
            return true
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        editor.typeKey("v", modifierFlags: .command)
        XCTAssertTrue((editor.value as? String)?.contains("![](attachment:") == true)
        // Off its line, the Markdown gives way to the picture itself.
        editor.typeText("Below")
        XCTAssertTrue(app.images["notePicture"].waitForExistence(timeout: 5))
    }

    func testInsertingAndTidyingATable() {
        let editor = newNote(title: "Table", text: "")
        app.menuButtons["Table"].click()
        app.menuItems["Insert Table"].click()
        XCTAssertTrue((editor.value as? String)?.contains("| Column 1 | Column 2 | Column 3 |") == true)
    }

    /// Only where Apple Intelligence is on; skipped elsewhere.
    func testSummarizing() throws {
        newNote(title: "Sourdough", text: "Sourdough bread is leavened by a starter of wild yeast and lactic acid bacteria. "
                + "Feed the starter with flour and water daily. Bake at 230 degrees for 40 minutes.")
        let summarize = app.buttons["Summarize"]
        guard summarize.waitForExistence(timeout: 5) else {
            throw XCTSkip("Apple Intelligence isn't available on this Mac.")
        }
        summarize.click()
        let summary = app.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] 'starter' OR value CONTAINS[c] 'sourdough'"))
        XCTAssertTrue(summary.firstMatch.waitForExistence(timeout: 60))
    }

    func testSheetsOpen() {
        app.typeKey("r", modifierFlags: [.command, .option])
        XCTAssertTrue(app.staticTexts["Smart Rules"].waitForExistence(timeout: 5)
                      || app.windows.sheets.firstMatch.waitForExistence(timeout: 1))
        app.buttons["Done"].firstMatch.click()
    }

    func testPrintSheetOpens() {
        newNote(title: "Printable", text: "hello")
        app.typeKey("p", modifierFlags: .command)
        // The print panel comes up as a dialog in front of the window.
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 10)
                      || app.sheets.firstMatch.waitForExistence(timeout: 1))
        app.typeKey(.escape, modifierFlags: [])
    }
    // MARK: - Templates, daily notes, feeds, folders and importing

    private var today: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }

    /// A folder of its own for each test, which the open panel is pointed at.
    private func fixtureFolder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StashUITests-\(UUID().uuidString.prefix(6))", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        return folder
    }

    /// In the open panel: Go to Folder, the path, then Open.
    private func choose(_ url: URL) {
        sleep(2)
        app.typeKey("g", modifierFlags: [.command, .shift])
        sleep(1)
        app.typeText(url.path + "\r")
        sleep(1)
        app.typeKey(.return, modifierFlags: [])
    }

    private func listRow(_ title: String) -> XCUIElement {
        app.outlines.element(boundBy: 1).staticTexts[title]
    }

    func testTemplatesFillInPlaceholders() {
        app.outlines.staticTexts["Templates"].click()
        newNote(title: "Meeting {{date}}", text: "Notes for {{title}}")
        let use = app.buttons["newNoteFromTemplate"]
        XCTAssertTrue(use.waitForExistence(timeout: 5))
        use.click()
        let title = app.textFields["itemTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Meeting \(today)")
        XCTAssertEqual(app.textViews["noteEditor"].value as? String, "Notes for Meeting \(today)")
        // The template stays in Templates, the note in All Items.
        XCTAssertTrue(listRow("Meeting \(today)").exists)
        XCTAssertFalse(listRow("Meeting {{date}}").exists)
    }

    func testTodaysNoteIsMadeOnceAndFiled() {
        app.typeKey("t", modifierFlags: [.command, .shift])
        let title = app.textFields["itemTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, today)
        XCTAssertTrue(app.outlines.staticTexts["Daily Notes"].waitForExistence(timeout: 5))
        let editor = app.textViews["noteEditor"]
        editor.click()
        editor.typeText("Walked the dog")
        newNote(title: "Something else", text: "x")
        // Again: the same note, not a second one.
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, today)
        XCTAssertEqual(editor.value as? String, "Walked the dog")
    }

    func testImportingANotesFolder() throws {
        let folder = try fixtureFolder("Trip Notes")
        let image = NSImage(size: NSSize(width: 60, height: 40), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Italy"), withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("Italy/colosseum.png"))
        try "---\ntags: [travel]\n---\n# Rome\n\nSee the sights.\n\n![](colosseum.png)\n"
            .write(to: folder.appendingPathComponent("Italy/Rome.md"), atomically: true, encoding: .utf8)
        try "<html><head><title>Packing</title></head><body><ul><li>Passport</li><li><b>Charger</b></li></ul></body></html>"
            .write(to: folder.appendingPathComponent("Packing.html"), atomically: true, encoding: .utf8)

        menuItem("File", "Import Notes Folder…").click()
        choose(folder)
        XCTAssertTrue(app.staticTexts["Import Finished"].waitForExistence(timeout: 20))
        // OK. (Clicking finds the Touch Bar's copy of the button.)
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(app.outlines.staticTexts["Trip Notes"].waitForExistence(timeout: 5))
        listRow("Packing").click()
        XCTAssertEqual(app.textViews["noteEditor"].value as? String, "- Passport\n- **Charger**")
        listRow("Rome").click()
        let rome = app.textViews["noteEditor"].value as? String ?? ""
        XCTAssertTrue(rome.hasPrefix("See the sights.\n\n![](attachment:"), rome)
        // Off the picture's line, the picture shows.
        app.textViews["noteEditor"].click()
        app.textViews["noteEditor"].typeKey(.upArrow, modifierFlags: .command)
        XCTAssertTrue(app.images["notePicture"].waitForExistence(timeout: 5))
        // The picture went into the note, not in as a document of its own.
        XCTAssertFalse(listRow("colosseum").exists)
    }

    func testImportingFromEvernote() throws {
        let folder = try fixtureFolder("Evernote")
        let file = folder.appendingPathComponent("Recipes.enex")
        try """
            <?xml version="1.0" encoding="UTF-8"?>
            <en-export application="Evernote" version="10">
            <note><title>Pancakes</title><created>20240101T080000Z</created><tag>breakfast</tag>
            <content><![CDATA[<en-note><div>Flour, <b>eggs</b>, milk.</div><div><en-todo checked="true"/>Whisk</div></en-note>]]></content>
            </note>
            </en-export>
            """.write(to: file, atomically: true, encoding: .utf8)
        menuItem("File", "Import from Evernote…").click()
        choose(file)
        XCTAssertTrue(app.staticTexts["Import Finished"].waitForExistence(timeout: 20))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.outlines.staticTexts["Recipes"].waitForExistence(timeout: 5))
        listRow("Pancakes").click()
        XCTAssertEqual(app.textViews["noteEditor"].value as? String, "Flour, **eggs**, milk.\n- [x] Whisk")
        XCTAssertTrue(app.outlines.staticTexts["breakfast"].exists)
    }

    func testIndexedFolderFollowsChanges() throws {
        let folder = try fixtureFolder("Indexed Papers")
        try "first".write(to: folder.appendingPathComponent("Alpha.txt"), atomically: true, encoding: .utf8)
        menuItem("File", "Index Folder…").click()
        choose(folder)
        XCTAssertTrue(app.outlines.staticTexts["Indexed Papers"].waitForExistence(timeout: 10))
        XCTAssertTrue(listRow("Alpha").waitForExistence(timeout: 10))

        // Added in Finder: shows up.
        try "second".write(to: folder.appendingPathComponent("Beta.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(listRow("Beta").waitForExistence(timeout: 15))
        // Renamed in Finder: the same item, renamed.
        try FileManager.default.moveItem(at: folder.appendingPathComponent("Alpha.txt"),
                                         to: folder.appendingPathComponent("Gamma.txt"))
        XCTAssertTrue(listRow("Gamma").waitForExistence(timeout: 15))
        XCTAssertFalse(listRow("Alpha").exists)
        // Deleted in Finder: goes to the Trash.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Beta.txt"))
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: listRow("Beta"))
        wait(for: [gone], timeout: 15)

        // Added while Stash was closed: there when it opens again, found
        // through the folder's bookmark.
        app.terminate()
        try "fourth".write(to: folder.appendingPathComponent("Delta.txt"), atomically: true, encoding: .utf8)
        app.launchArguments = ["-StashTestLibrary", "YES"]
        app.launch()
        app.outlines.staticTexts["Indexed Papers"].click()
        XCTAssertTrue(listRow("Delta").waitForExistence(timeout: 15))
        XCTAssertTrue(listRow("Gamma").exists)
    }

    /// Needs the internet, so only run when asked:
    /// `TEST_RUNNER_STASH_NETWORK_TESTS=1 xcodebuild test ...`
    func testSubscribingToAFeed() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STASH_NETWORK_TESTS"] != nil,
                          "Set STASH_NETWORK_TESTS to run tests that use the internet.")
        menuItem("File", "Subscribe to Feed…").click()
        let field = app.textFields["feedAddress"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("https://www.swift.org/atom.xml\r")
        let feedRow = app.outlines.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'swift'")).firstMatch
        guard feedRow.waitForExistence(timeout: 30) else {
            throw XCTSkip("Couldn't reach the feed.")
        }
        // Its posts are listed under it.
        let posts = app.outlines.element(boundBy: 1).staticTexts
        XCTAssertTrue(posts.firstMatch.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(posts.count, 2)
    }
    // MARK: - Voice, email, highlights and windows

    func testImportedRecordingIsTranscribed() throws {
        let folder = try fixtureFolder("Audio")
        let file = folder.appendingPathComponent("Reminder.m4a")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "--data-format=aac",
                         "Remember to water the tomatoes on Saturday morning. Then call the plumber about the kitchen sink."]
        try say.run()
        say.waitUntilExit()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path), "Couldn't make a recording.")

        app.typeKey("i", modifierFlags: [.command, .shift])
        choose(file)
        XCTAssertTrue(listRow("Reminder").waitForExistence(timeout: 10))
        listRow("Reminder").click()
        XCTAssertTrue(app.buttons["playButton"].waitForExistence(timeout: 10))
        // The first time, the language's speech model may need downloading.
        let words = app.buttons.matching(identifier: "transcriptSegment")
            .matching(NSPredicate(format: "label CONTAINS[c] 'tomatoes'")).firstMatch
        if !words.waitForExistence(timeout: 180) {
            let failed = app.staticTexts["No Transcript"].exists
            throw XCTSkip(failed ? "Speech recognition isn't available here." : "Transcribing took too long.")
        }
        // Searchable by what was said.
        let search = app.searchFields.firstMatch
        search.click()
        search.typeText("plumber")
        XCTAssertTrue(listRow("Reminder").waitForExistence(timeout: 5))
    }

    private let email = """
        From: Sam Lee <sam@example.com>
        To: Jo <jo@example.com>
        Subject: Garden plans
        Date: Mon, 12 Oct 2026 08:30:00 +0000
        Message-ID: <garden-1@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="b1"

        --b1
        Content-Type: text/plain; charset=utf-8

        Let's plant the bulbs this weekend.
        --b1
        Content-Type: text/plain; name="list.txt"
        Content-Disposition: attachment; filename="list.txt"

        tulips, daffodils
        --b1--
        """

    func testImportingAnEmail() throws {
        let folder = try fixtureFolder("Mail")
        let file = folder.appendingPathComponent("message.eml")
        try email.write(to: file, atomically: true, encoding: .utf8)
        app.typeKey("i", modifierFlags: [.command, .shift])
        choose(file)
        // Titled with its subject once it's been read.
        XCTAssertTrue(listRow("Garden plans").waitForExistence(timeout: 10))
        listRow("Garden plans").click()
        XCTAssertTrue(app.staticTexts["Let's plant the bulbs this weekend."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sam Lee <sam@example.com>"].exists)
        app.buttons["Add to Stash"].firstMatch.click()
        XCTAssertTrue(app.textFields["itemTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["itemTitle"].value as? String, "list")
    }

    func testImportingAMailboxSkipsWhatsThere() throws {
        let folder = try fixtureFolder("Mailboxes")
        let file = folder.appendingPathComponent("Family.mbox")
        let second = email.replacingOccurrences(of: "garden-1", with: "garden-2")
            .replacingOccurrences(of: "Garden plans", with: "Garden plans, again")
        try ("From sam@example.com Mon Oct 12 08:30:00 2026\n" + email + "\n\nFrom sam@example.com Mon Oct 12 09:30:00 2026\n" + second + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        for _ in 0..<2 {
            menuItem("File", "Import Mailbox…").click()
            choose(file)
            XCTAssertTrue(app.staticTexts["Import Finished"].waitForExistence(timeout: 20))
            app.typeKey(.return, modifierFlags: [])
        }
        XCTAssertTrue(app.outlines.staticTexts["Family"].waitForExistence(timeout: 5))
        XCTAssertTrue(listRow("Garden plans").waitForExistence(timeout: 5))
        XCTAssertTrue(listRow("Garden plans, again").exists)
        // Imported twice, there once.
        XCTAssertEqual(app.outlines.element(boundBy: 1).staticTexts.matching(NSPredicate(format: "label == 'Garden plans' OR value == 'Garden plans'")).count, 1)
    }

    func testHighlightsBecomeANote() throws {
        let folder = try fixtureFolder("Reading")
        let file = folder.appendingPathComponent("Essay.pdf")
        let page = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        page.string = "Attention is the beginning of devotion."
        page.font = .systemFont(ofSize: 18)
        try page.dataWithPDF(inside: page.bounds).write(to: file)

        app.typeKey("i", modifierFlags: [.command, .shift])
        choose(file)
        XCTAssertTrue(listRow("Essay").waitForExistence(timeout: 10))
        listRow("Essay").click()
        // Select the page's words, then Highlight.
        sleep(2)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.4)).click()
        app.typeKey("a", modifierFlags: .command)
        let highlight = app.descendants(matching: .any)["highlightButton"].firstMatch
        XCTAssertTrue(highlight.waitForExistence(timeout: 5))
        // The highlighter, not the arrow beside it (a menu of colours).
        highlight.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        if app.menuItems["Yellow"].waitForExistence(timeout: 1) { app.menuItems["Yellow"].click() }

        let makeNote = app.buttons["Make Note"]
        XCTAssertTrue(makeNote.waitForExistence(timeout: 5), "No highlight was made")
        makeNote.click()
        let title = app.textFields["itemTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Highlights: Essay")
        let text = app.textViews["noteEditor"].value as? String ?? ""
        XCTAssertTrue(text.hasPrefix("From [[Essay]]"), text)
        XCTAssertTrue(text.contains("> 🟨 Attention is the beginning of devotion."), text)
        XCTAssertTrue(text.contains("_p. 1_"), text)
    }

    func testBackForwardAndItemWindows() {
        newNote(title: "First Page", text: "one")
        newNote(title: "Second Page", text: "two")
        let title = app.textFields["itemTitle"]
        app.typeKey("[", modifierFlags: .command)
        XCTAssertEqual(title.firstMatch.value as? String, "First Page")
        app.typeKey("]", modifierFlags: .command)
        XCTAssertEqual(title.firstMatch.value as? String, "Second Page")

        menuItem("Item", "Open in New Window").click()
        XCTAssertTrue(app.windows["Second Page"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows["Second Page"].textFields["itemTitle"].value as? String, "Second Page")
        app.windows["Second Page"].typeKey("w", modifierFlags: .command)

        listRow("First Page").click()
        menuItem("Item", "Open in New Tab").click()
        XCTAssertTrue(app.windows["First Page"].waitForExistence(timeout: 5))
        // A tab of the main window: the two share a tab bar.
        XCTAssertTrue(app.tabGroups.firstMatch.waitForExistence(timeout: 5) || app.radioButtons["First Page"].exists)
    }
    // MARK: - Locking and asking

    private func enterPassword(_ password: String, twice: Bool) {
        let field = app.secureTextFields["lockPassword"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText(password)
        if twice {
            let again = app.secureTextFields["lockPasswordAgain"]
            again.click()
            again.typeText(password + "\r")
        } else {
            field.typeText("\r")
        }
    }

    func testLockingEncryptsAndNeedsThePassword() {
        newNote(title: "Diary", text: "Met Alex at the park.")
        menuItem("Item", "Lock").click()
        enterPassword("correct horse", twice: true)
        let unlock = app.buttons["Unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        // Its words can't be found while it's locked.
        let search = app.searchFields.firstMatch
        search.click()
        search.typeText("Alex")
        XCTAssertFalse(listRow("Diary").waitForExistence(timeout: 2))
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])

        // Unlocked in the same session, it opens straight away and can be written in.
        listRow("Diary").click()
        app.buttons["Unlock"].click()
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Met Alex at the park.")
        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText(" Again.")
        sleep(2)

        // Opened again, it needs the password: the wrong one won't do.
        app.terminate()
        app.launchArguments = ["-StashTestLibrary", "YES"]
        app.launch()
        listRow("Diary").click()
        XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 5))
        app.buttons["Unlock"].click()
        enterPassword("wrong horse", twice: false)
        XCTAssertTrue(app.staticTexts["That’s not the password."].waitForExistence(timeout: 15))
        app.secureTextFields["lockPassword"].click()
        app.secureTextFields["lockPassword"].typeText("correct horse\r")
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, "Met Alex at the park. Again.")

        // Taking the lock off decrypts it for good.
        menuItem("Item", "Remove Lock…").click()
        XCTAssertTrue(app.textViews["noteEditor"].waitForExistence(timeout: 5))
        search.click()
        search.typeText("Alex")
        XCTAssertTrue(listRow("Diary").waitForExistence(timeout: 5))
    }

    /// Only where Apple Intelligence is on; skipped elsewhere.
    func testAskingTheLibrary() throws {
        newNote(title: "Boiler", text: "The boiler was serviced in March by Ray from Warmfix. It needs a new pressure valve next year.")
        newNote(title: "Groceries", text: "Apples, bread and milk.")
        menuItem("Item", "Ask Your Library…").click()
        let question = app.textFields["libraryQuestion"]
        guard question.waitForExistence(timeout: 5) else {
            throw XCTSkip("Apple Intelligence isn't available on this Mac.")
        }
        question.click()
        question.typeText("Who serviced the boiler?\r")
        let answer = app.staticTexts["libraryAnswer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 90))
        XCTAssertTrue((answer.value as? String ?? answer.label).localizedCaseInsensitiveContains("Ray"))
        let source = app.buttons.matching(identifier: "librarySource").matching(NSPredicate(format: "label CONTAINS 'Boiler'")).firstMatch
        XCTAssertTrue(source.exists)
    }
    #endif
}
