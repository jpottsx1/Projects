import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A saved link: its address, the saved copy of the page to read offline,
/// and notes.
struct LinkDetail: View {
    @Environment(Library.self) private var library
    @Bindable var item: Item
    @State private var isRefreshing = false
    @State private var copyURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()

            Divider()

            Group {
                if let copyURL {
                    PageCopyView(fileURL: copyURL, pageURL: item.url)
                } else if library.copyingPages.contains(item.uuid) {
                    ProgressView("Saving a copy of the page…")
                } else if item.archivePath != nil {
                    ContentUnavailableView(
                        "Saved Copy Not on This Device Yet", systemImage: "icloud.and.arrow.down",
                        description: Text("It appears once iCloud has downloaded it. Copies over 100 MB stay on the device that saved them."))
                } else {
                    ContentUnavailableView {
                        Label("No Saved Copy", systemImage: "doc.richtext")
                    } description: {
                        Text("Save a copy to read this page offline, exactly as it was.")
                    } actions: {
                        Button("Save a Copy") {
                            Task { await library.savePageCopy(of: item) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Notes")
                    .font(.headline)
                TextEditor(text: $item.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 100)
            }
            .padding()
        }
        .onChange(of: item.body) { library.didEdit(item) }
        // Looked for again whenever the library changes: that includes a
        // copy being saved, or arriving from iCloud.
        .task(id: library.revision) {
            copyURL = library.localPageCopy(for: item)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = item.url {
                HStack {
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "safari")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        Task {
                            isRefreshing = true
                            await library.refreshPage(of: item)
                            isRefreshing = false
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshing || library.copyingPages.contains(item.uuid))
                    .help("Fetch the page again: its latest summary, text to search, and a new saved copy")
                }
            }
            if !item.summary.isEmpty {
                Text(item.summary)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let date = item.archivedAt {
                Text("Copy saved \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Shows a saved web archive. Links in it open in the browser rather than
/// replacing the copy.
#if os(macOS)
struct PageCopyView: NSViewRepresentable {
    let fileURL: URL
    let pageURL: URL?

    func makeCoordinator() -> PageCopyCoordinator { PageCopyCoordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = PageCopyCoordinator.makeWebView()
        view.navigationDelegate = context.coordinator
        context.coordinator.show(fileURL, baseURL: pageURL, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.show(fileURL, baseURL: pageURL, in: view)
    }
}
#else
struct PageCopyView: UIViewRepresentable {
    let fileURL: URL
    let pageURL: URL?

    func makeCoordinator() -> PageCopyCoordinator { PageCopyCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let view = PageCopyCoordinator.makeWebView()
        view.navigationDelegate = context.coordinator
        context.coordinator.show(fileURL, baseURL: pageURL, in: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.show(fileURL, baseURL: pageURL, in: view)
    }
}
#endif

@MainActor
final class PageCopyCoordinator: NSObject, WKNavigationDelegate {
    private var shown: URL?
    private var shownDate: Date?

    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }

    /// Loads the copy, unless it's the one already showing -- a redraw
    /// mustn't reload the page and lose your place in it.
    func show(_ fileURL: URL, baseURL: URL?, in view: WKWebView) {
        let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard fileURL != shown || modified != shownDate,
              let data = try? Data(contentsOf: fileURL) else { return }
        shown = fileURL
        shownDate = modified
        view.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8",
                  baseURL: baseURL ?? fileURL)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
            return .allow
        }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        _ = await UIApplication.shared.open(url)
        #endif
        return .cancel
    }
}
