import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import QuickLook
import QuickLookThumbnailing

struct DocumentDetail: View {
    @Environment(Library.self) private var library
    @Bindable var item: Item
    @State private var quickLookURL: URL?
    @State private var fileURL: URL?
    @State private var hasLooked = false
    @State private var isMarkingUp = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let fileURL, item.isPDF {
                    PDFReader(item: item, url: fileURL)
                        // Marked up: load the changed file.
                        .id(library.fileRevision(of: item))
                } else if let fileURL, item.isEPUB {
                    EPUBReader(item: item, url: fileURL)
                } else if let fileURL {
                    FileThumbnail(url: fileURL)
                        .padding()
                        .id(library.fileRevision(of: item))
                } else if !hasLooked {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "Not on This Device Yet", systemImage: "icloud.and.arrow.down",
                        description: Text("If this was added on another device, it appears once iCloud has downloaded it. Files over 100 MB stay on the device they were added on."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Notes")
                        .font(.headline)
                    Spacer()
                    if let fileURL {
                        Button {
                            quickLookURL = fileURL
                        } label: {
                            Label("Quick Look", systemImage: "eye")
                        }
                        ShareLink(item: fileURL)
                    }
                }
                TextEditor(text: $item.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 100)
            }
            .padding()
        }
        .quickLookPreview($quickLookURL)
        .toolbar {
            if Library.canMarkUp(item), fileURL != nil {
                ToolbarItem {
                    Menu {
                        Button {
                            markUp()
                        } label: {
                            Label("Mark Up", systemImage: "pencil.tip.crop.circle")
                        }
                        if library.hasOriginal(item) {
                            Button("Revert to Original") { library.revertToOriginal(item) }
                        }
                    } label: {
                        Label("Mark Up", systemImage: "pencil.tip.crop.circle")
                    } primaryAction: {
                        markUp()
                    }
                    .help("Draw, write and add shapes on it")
                }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $isMarkingUp) {
            if let fileURL {
                MarkupView(url: fileURL) {
                    Task { await library.fileDidChange(item) }
                }
                .ignoresSafeArea()
            }
        }
        #endif
        // Looked for again whenever the library changes, which includes the
        // file's contents arriving from iCloud.
        .task(id: library.revision) {
            fileURL = library.localFile(for: item)
            hasLooked = true
        }
        .onChange(of: item.body) { library.didEdit(item) }
    }

    private func markUp() {
        #if os(macOS)
        library.markUpInPreview(item)
        #else
        library.keepOriginal(of: item)
        isMarkingUp = true
        #endif
    }
}

/// A large Quick Look thumbnail: pictures show as themselves, other files
/// as their first page or their icon.
struct FileThumbnail: View {
    let url: URL
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                Image(systemName: "doc")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 1200, height: 1200),
                                                       scale: 2, representationTypes: .all)
            if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = thumbnail.cgImage
            } else {
                failed = true
            }
        }
    }
}
