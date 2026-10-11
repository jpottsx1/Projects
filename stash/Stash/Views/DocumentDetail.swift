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

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let fileURL, item.contentType?.conforms(to: .pdf) == true {
                    PDFKitView(url: fileURL)
                } else if let fileURL {
                    FileThumbnail(url: fileURL)
                        .padding()
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
        // Looked for again whenever the library changes, which includes the
        // file's contents arriving from iCloud.
        .task(id: library.revision) {
            fileURL = library.localFile(for: item)
            hasLooked = true
        }
        .onChange(of: item.body) { library.didEdit(item) }
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

#if os(macOS)
struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}
#else
struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}
#endif
