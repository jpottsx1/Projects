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
    #endif
}
