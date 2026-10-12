import PencilKit
import SwiftUI
import StashCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Sketches in notes: drawn with PencilKit (on an iPhone or iPad with its
/// tools, with a pen or finger; on a Mac with the mouse or trackpad),
/// kept as the drawing, to change later, and a picture the note shows.
/// Handwriting in them is read on the device, so it can be searched.
extension Library {
    static let sketchPrefix = "sketch-"

    /// Saves a sketch with a note and returns the Markdown that shows it.
    /// Each version gets a name of its own, so the note shows the new picture.
    func saveSketch(_ drawing: PKDrawing, in note: Item) -> String? {
        guard let png = SketchPicture.png(of: drawing) else { return nil }
        let base = Self.sketchPrefix + String(UUID().uuidString.prefix(8)).lowercased()
        for (name, data) in [(base + ".png", png), (base + ".drawing", drawing.dataRepresentation())] {
            let attachment = NoteAttachment(fileName: name, data: data)
            context.insert(attachment)
            attachment.item = note
            try? files.write(data, to: "\(note.uuid.uuidString)/Attachments/\(name)")
        }
        save()
        recognizeText(inPicture: base + ".png", of: note)
        return "![Sketch](\(Self.attachmentScheme)\(base).png)"
    }

    /// The drawing behind a sketch the note shows, to change it.
    func sketchDrawing(_ pictureName: String, in note: Item) -> PKDrawing? {
        guard pictureName.hasPrefix(Self.sketchPrefix), pictureName.hasSuffix(".png") else { return nil }
        let name = String(pictureName.dropLast(4)) + ".drawing"
        guard let data = note.attachments?.first(where: { $0.fileName == name })?.data else { return nil }
        return try? PKDrawing(data: data)
    }

    /// Reads the words in a note's picture, for search.
    func recognizeText(inPicture name: String, of note: Item) {
        guard let attachment = note.attachments?.first(where: { $0.fileName == name }), let data = attachment.data,
              !note.isSealed else { return }
        Task {
            let text = await Task.detached(priority: .utility) { TextExtractor.recognizeText(inImage: data) }.value
            guard isAlive(note), attachment.modelContext != nil, !text.isEmpty else { return }
            attachment.recognizedText = text
            reindex(note)
            save()
        }
    }
}

enum SketchPicture {
    /// The drawing on white, a little margin round it, at twice its size:
    /// it reads the same in light and dark mode.
    static func png(of drawing: PKDrawing) -> Data? {
        guard !drawing.strokes.isEmpty else { return nil }
        let bounds = drawing.bounds.insetBy(dx: -24, dy: -24)
        #if os(iOS)
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: bounds, scale: 2)
        }
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            return format
        }())
        return renderer.pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: bounds.size))
            image.draw(in: CGRect(origin: .zero, size: bounds.size))
        }
        #else
        var image = NSImage()
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { image = drawing.image(from: bounds, scale: 2) }
        let size = NSSize(width: bounds.width * 2, height: bounds.height * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
        #endif
    }
}

/// Drawing a sketch, new or to change.
struct SketchEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var drawing: PKDrawing
    let onSave: (PKDrawing) -> Void
    #if os(macOS)
    @State private var color: NSColor = .black
    @State private var width: CGFloat = 3
    #endif

    init(drawing: PKDrawing = PKDrawing(), onSave: @escaping (PKDrawing) -> Void) {
        _drawing = State(initialValue: drawing)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            canvas
                .navigationTitle("Sketch")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            if !drawing.strokes.isEmpty { onSave(drawing) }
                            dismiss()
                        }
                        .accessibilityIdentifier("sketchDone")
                    }
                    #if os(macOS)
                    ToolbarItemGroup {
                        ForEach([NSColor.black, .systemBlue, .systemRed, .systemGreen], id: \.self) { swatch in
                            Button {
                                color = swatch
                            } label: {
                                Image(systemName: color == swatch ? "circle.inset.filled" : "circle.fill")
                                    .foregroundStyle(Color(nsColor: swatch))
                            }
                            .help("Colour")
                        }
                        Picker("Width", selection: $width) {
                            Text("Fine").tag(CGFloat(2))
                            Text("Medium").tag(CGFloat(3))
                            Text("Bold").tag(CGFloat(6))
                        }
                        .fixedSize()
                        Button {
                            if !drawing.strokes.isEmpty { drawing.strokes.removeLast() }
                        } label: {
                            Label("Undo Stroke", systemImage: "arrow.uturn.backward")
                        }
                        .keyboardShortcut("z")
                        Button {
                            drawing = PKDrawing()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                    }
                    #endif
                }
        }
        .sheetSize(minWidth: 720, minHeight: 520)
    }

    @ViewBuilder
    private var canvas: some View {
        #if os(iOS)
        PencilCanvas(drawing: $drawing)
            .ignoresSafeArea(edges: .bottom)
        #else
        MouseCanvas(drawing: $drawing, color: color, width: width)
        #endif
    }
}

#if os(iOS)
/// PencilKit's canvas, with its tool picker; a finger draws too.
private struct PencilCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = drawing
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        // Ink as it'll be seen in the note: on white.
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = context.coordinator
        canvas.accessibilityIdentifier = "sketchCanvas"
        context.coordinator.picker.setVisible(true, forFirstResponder: canvas)
        context.coordinator.picker.addObserver(canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PencilCanvas
        let picker = PKToolPicker()

        init(_ parent: PencilCanvas) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}
#else
/// A canvas for the mouse or trackpad, making the same PencilKit strokes
/// an iPad makes, since PencilKit has no canvas on a Mac.
private struct MouseCanvas: NSViewRepresentable {
    @Binding var drawing: PKDrawing
    let color: NSColor
    let width: CGFloat

    func makeNSView(context: Context) -> CanvasView {
        let view = CanvasView()
        view.drawing = drawing
        view.onChange = { drawing = $0 }
        return view
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        view.onChange = { drawing = $0 }
        if view.drawing != drawing { view.drawing = drawing }
        view.ink = PKInk(.pen, color: color)
        view.width = width
    }

    final class CanvasView: NSView {
        var drawing = PKDrawing() { didSet { needsDisplay = true } }
        var ink = PKInk(.pen, color: .black)
        var width: CGFloat = 3
        var onChange: (PKDrawing) -> Void = { _ in }
        private var points: [PKStrokePoint] = []
        private var started = Date()

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            setAccessibilityLabel("Sketch")
            setAccessibilityIdentifier("sketchCanvas")
        }

        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func point(_ event: NSEvent) -> PKStrokePoint {
            let location = convert(event.locationInWindow, from: nil)
            return PKStrokePoint(location: location, timeOffset: Date().timeIntervalSince(started),
                                 size: CGSize(width: width, height: width), opacity: 1, force: 1,
                                 azimuth: 0, altitude: .pi / 2)
        }

        override func mouseDown(with event: NSEvent) {
            started = Date()
            points = [point(event)]
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            points.append(point(event))
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            points.append(point(event))
            // A click is a dot: a stroke needs two points.
            if points.count == 1 { points.append(points[0]) }
            let stroke = PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: started))
            points = []
            var changed = drawing
            changed.strokes.append(stroke)
            drawing = changed
            onChange(changed)
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill()
            bounds.fill()
            if !drawing.strokes.isEmpty {
                var image = NSImage()
                let scale = window?.backingScaleFactor ?? 2
                NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                    image = drawing.image(from: bounds, scale: scale)
                }
                image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            // The stroke being drawn, until it's finished.
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.move(to: points[0].location)
            for point in points.dropFirst() { path.line(to: point.location) }
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            ink.color.setStroke()
            path.stroke()
        }
    }
}
#endif
