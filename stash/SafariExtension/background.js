// Save to Stash: one click on the toolbar button sends the page's address
// and title to the app (SafariWebExtensionHandler), which keeps it in the
// Inbox. A tick on the button says it worked; ! that it didn't.
browser.action.onClicked.addListener(async (tab) => {
    let mark = "!";
    try {
        const reply = await browser.runtime.sendNativeMessage("application.id", { url: tab.url, title: tab.title });
        if (reply && reply.saved) mark = "✓";
    } catch (error) {
        console.error("Stash couldn't save the page", error);
    }
    await browser.action.setBadgeText({ tabId: tab.id, text: mark });
    setTimeout(() => browser.action.setBadgeText({ tabId: tab.id, text: "" }), 2000);
});
