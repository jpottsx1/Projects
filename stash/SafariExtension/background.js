// Save to Stash: one click on the toolbar button sends the page's address
// and title to the app (SafariWebExtensionHandler), which keeps it in the
// Inbox. The button's menu (and the page's) can also keep the page as a
// PDF, a Markdown note or a web archive. A tick on the button says it
// worked; ! that it didn't.
async function save(tab, format, image) {
    let mark = "!";
    try {
        const message = { url: tab.url, title: tab.title };
        if (format) message.format = format;
        // A picture: Stash finds its biggest version, as Eagle does.
        if (image) message.imageURL = image;
        const reply = await browser.runtime.sendNativeMessage("application.id", message);
        if (reply && reply.saved) mark = "✓";
    } catch (error) {
        console.error("Stash couldn't save the page", error);
    }
    await browser.action.setBadgeText({ tabId: tab.id, text: mark });
    setTimeout(() => browser.action.setBadgeText({ tabId: tab.id, text: "" }), 2000);
}

browser.action.onClicked.addListener((tab) => save(tab));

const formats = [
    ["pdf", "Save to Stash as PDF"],
    ["markdown", "Save to Stash as Markdown Note"],
    ["webArchive", "Save to Stash as Web Archive"],
];

browser.runtime.onInstalled.addListener(() => {
    for (const [id, title] of formats) {
        browser.contextMenus.create({ id, title, contexts: ["action", "page"] });
    }
    browser.contextMenus.create({ id: "image", title: "Save Image to Stash", contexts: ["image"] });
});

browser.contextMenus.onClicked.addListener((info, tab) => {
    if (!tab) return;
    if (info.menuItemId === "image" && info.srcUrl) save(tab, null, info.srcUrl);
    else if (formats.some(([id]) => id === info.menuItemId)) save(tab, info.menuItemId);
});
