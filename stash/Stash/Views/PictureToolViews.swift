import SwiftUI
import StashCore

/// Rotate, flip, crop, resize and convert: in item menus.
struct PictureToolMenu: View {
    @Environment(Library.self) private var library
    let items: [Item]

    var body: some View {
        let editable = items.filter(Library.canEditPicture)
        let pictures = items.filter(Library.isPicture)
        if !pictures.isEmpty {
            Menu("Picture") {
                if !editable.isEmpty {
                    Button("Rotate Left") { library.change(editable, .rotateLeft) }
                    Button("Rotate Right") { library.change(editable, .rotateRight) }
                    Button("Flip Horizontal") { library.change(editable, .flipHorizontal) }
                    Button("Flip Vertical") { library.change(editable, .flipVertical) }
                    Divider()
                    if editable.count == 1 {
                        Button("Crop…") { library.croppingPicture = editable[0] }
                    }
                    Button("Resize…") { library.resizingPictures = editable }
                    Divider()
                }
                Menu("Convert To") {
                    ForEach(Library.PictureFormat.allCases) { format in
                        Button(format.name) { library.convert(pictures, to: format) }
                    }
                }
            }
        }
    }
}

/// Drag across the picture to choose what to keep.
struct CropSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let item: Item
    @State private var image: CGImage?
    @State private var start: CGPoint?
    @State private var selection: CGRect?
    @State private var shownSize: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if let image {
                    let fitted = fit(image, in: geometry.size)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .overlay(alignment: .topLeading) {
                            if let selection {
                                Rectangle()
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                                    .background(Color.accentColor.opacity(0.12))
                                    .frame(width: selection.width, height: selection.height)
                                    .offset(x: selection.minX, y: selection.minY)
                            }
                        }
                        .gesture(DragGesture(minimumDistance: 2).onChanged { drag in
                            let origin = start ?? drag.startLocation
                            start = origin
                            selection = CGRect(x: min(origin.x, drag.location.x), y: min(origin.y, drag.location.y),
                                               width: abs(drag.location.x - origin.x), height: abs(drag.location.y - origin.y))
                                .intersection(CGRect(origin: .zero, size: fitted))
                        }.onEnded { _ in start = nil })
                        .onAppear { shownSize = fitted }
                        .onChange(of: fitted) { shownSize = fitted; selection = nil }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding()
            .navigationTitle("Crop “\(item.displayTitle)”")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crop") {
                        if let image, let selection,
                           let rect = PictureGeometry.pixelRect(x: selection.minX, y: selection.minY, width: selection.width,
                                                                height: selection.height, shownWidth: shownSize.width,
                                                                shownHeight: shownSize.height, pixelWidth: image.width,
                                                                pixelHeight: image.height) {
                            library.change([item], .crop(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
                        }
                        dismiss()
                    }
                    .disabled(selection == nil)
                }
            }
        }
        .sheetSize(minWidth: 560, minHeight: 520)
        .task {
            image = library.localFile(for: item).flatMap(Library.uprightImage(at:))
        }
    }

    private func fit(_ image: CGImage, in size: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height), 1)
        return CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }
}

/// Makes pictures smaller: no side longer than the size chosen.
struct ResizeSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let items: [Item]
    @AppStorage("resizeMaxDimension") private var maxDimension = 1600

    var body: some View {
        NavigationStack {
            Form {
                Picker("Longest Side", selection: $maxDimension) {
                    ForEach([4000, 3000, 2400, 2000, 1600, 1200, 1024, 800, 640, 400], id: \.self) { size in
                        Text("\(size) pixels").tag(size)
                    }
                }
                Text(items.count == 1
                     ? "“\(items[0].displayTitle)” is made smaller if it's bigger; Revert to Original puts it back."
                     : "Each of these \(items.count) pictures is made smaller if it's bigger; Revert to Original puts each back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Resize")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Resize") {
                        library.change(items, .fit(maxDimension: maxDimension))
                        dismiss()
                    }
                }
            }
        }
        .sheetSize(minWidth: 380, minHeight: 240)
    }
}
