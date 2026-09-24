import SwiftUI

/// The original's shape underneath, pale, in the same bass/mid/treble
/// colors a DJ mixer's own overview waveform uses; whatever this run
/// added on top of it, drawn vivid, in the same colors, so what changed
/// and where is legible at a glance rather than buried in a number.
///
/// Additive blending rather than layering opaque bars, because that is
/// the actual technique behind a tri-band colored waveform: three colors
/// summing per pixel column, not three shapes stacked in front of one
/// another. `.plusLighter` is exactly that sum.
struct WaveformView: View {
    /// Overlay draws the original pale with the added energy vivid on top
    /// of it, in one row -- compact, and the shape of what changed reads
    /// at a glance. Compare draws both full silhouettes stacked, one row
    /// each, sharing a scale -- slower to read but literal: a track that
    /// got louder is visibly taller, not just tinted.
    enum Mode: String, CaseIterable, Identifiable {
        case overlay = "Overlay", compare = "Compare"
        var id: String { rawValue }
    }

    let original: WaveformEnvelope
    /// Nil when there is nothing to compare against -- a `--no-compare`
    /// render only ever has one file, and the view still has to be worth
    /// looking at on its own.
    let processed: WaveformEnvelope?
    let mode: Mode
    /// Off while blind and not revealed. The whole point of blind mode is
    /// that knowing which version is which is worth a couple of imagined
    /// dB; a picture of exactly what changed would hand that straight
    /// back, so it is withheld the same way the labels are.
    let showDifference: Bool
    /// 0...1
    let progress: Double
    let onSeek: (Double) -> Void

    /// Tall enough that a change reads as a change rather than a
    /// texture -- the original 72 left most of a band's own dynamic
    /// range unused because the scale below was wrong, not because the
    /// row was too short, but there is no reason not to give it room too.
    static let height: CGFloat = 132

    private static let bass = Color(red: 0.92, green: 0.30, blue: 0.24)
    private static let mid = Color(red: 0.30, green: 0.80, blue: 0.40)
    private static let treble = Color(red: 0.28, green: 0.58, blue: 0.98)

    /// Whether there is actually a second waveform to stack -- `mode` can
    /// say `.compare` while blind mode is withholding the processed side,
    /// and drawing decides that same way, so the labels below have to
    /// agree with what is actually on screen rather than what was asked for.
    private var comparing: Bool { mode == .compare && showDifference && processed != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        draw(in: &context, size: size)
                    }
                    .background(Color.black.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                onSeek(fraction(of: value.location.x, in: geometry.size.width))
                            }
                    )
                    // Which row is which -- the one thing a color legend
                    // cannot say, since both rows use the same three colors.
                    if comparing {
                        VStack(alignment: .leading) {
                            rowLabel("Original")
                            Spacer()
                            rowLabel("Processed")
                        }
                        .padding(6)
                    }
                }
            }
            .frame(height: Self.height)
            legend
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2).bold()
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.black.opacity(0.45))
            .clipShape(Capsule())
    }

    /// What the colors mean and which layer is which -- said once, in
    /// words, rather than left for a hover tooltip to explain after the
    /// fact. `.plusLighter` sums the three colors where bands overlap, so
    /// bass-and-mid together read as yellow and all three as white; that
    /// is arithmetic, not a fourth category, and worth spelling out.
    private var legend: some View {
        HStack(spacing: 12) {
            legendSwatch(Self.bass, "Bass")
            legendSwatch(Self.mid, "Mid")
            legendSwatch(Self.treble, "Treble")
            Text("(overlapping bands add -- bass+mid reads yellow)")
            Spacer()
            Text(comparing ? "Top: original · bottom: processed · white-edged lip: the increase"
                 : "Pale: original · bright: what this run added")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendSwatch(_ color: Color, _ name: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name)
        }
    }

    private func fraction(of x: CGFloat, in width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return max(0, min(1, Double(x / width)))
    }

    /// The tallest bar actually drawn, across whichever envelopes are on
    /// screen. Scaling against full-band peak used to leave a filtered
    /// sub-band's own RMS -- always well under it -- looking tiny
    /// regardless of how much a stage had actually moved it.
    private func bandCeiling(_ envelopes: [WaveformEnvelope]) -> Double {
        Double(envelopes.flatMap { [$0.bass.max() ?? 0, $0.mid.max() ?? 0,
                                    $0.treble.max() ?? 0] }.max() ?? 0)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard !original.isEmpty else { return }

        if comparing, let processed {
            drawCompare(original, processed, in: &context, size: size)
        } else {
            drawOverlay(in: &context, size: size)
        }

        let x = size.width * progress
        context.stroke(Path { p in
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: size.height))
        }, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
    }

    private func drawOverlay(in context: inout GraphicsContext, size: CGSize) {
        let midY = size.height / 2
        let reference = max(bandCeiling([original] + (processed.map { [$0] } ?? [])), 0.001)
        let scale = Double(midY) / reference * 0.95

        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            band(original.bass, in: &layer, size: size, midY: midY,
                scale: scale, color: Self.bass, opacity: 0.28)
            band(original.mid, in: &layer, size: size, midY: midY,
                scale: scale, color: Self.mid, opacity: 0.22)
            band(original.treble, in: &layer, size: size, midY: midY,
                scale: scale, color: Self.treble, opacity: 0.28)
        }

        if showDifference, let processed {
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                delta(original.bass, processed.bass, in: &layer, size: size,
                     midY: midY, scale: scale, color: Self.bass)
                delta(original.mid, processed.mid, in: &layer, size: size,
                     midY: midY, scale: scale, color: Self.mid)
                delta(original.treble, processed.treble, in: &layer, size: size,
                     midY: midY, scale: scale, color: Self.treble)
            }
        }
    }

    /// Two full silhouettes, original above and processed below, sharing
    /// one scale -- the same reason a shared scale is right above: this
    /// is a comparison, and each row scaled to its own peak would erase
    /// the level difference that is the whole point of drawing both.
    private func drawCompare(_ original: WaveformEnvelope, _ processed: WaveformEnvelope,
                             in context: inout GraphicsContext, size: CGSize) {
        let rowHeight = size.height / 2
        // The scale used to read `rowHeight` itself as a row's safe reach
        // from its own midline, when the actual reach a mirrored
        // silhouette has before hitting the next boundary is half that --
        // so a loud peak was drawn at roughly twice the height it had
        // room for, straight across the divider into the other row. This
        // is the real fix; `clearance` on top of it is just breathing room.
        let halfHeight = rowHeight / 2
        let clearance: CGFloat = 6
        let usable = max(halfHeight - clearance, 1)
        let reference = max(bandCeiling([original, processed]), 0.001)
        let scale = Double(usable) / reference
        let topMidY = halfHeight
        let bottomMidY = rowHeight + halfHeight

        row(original, in: &context, size: size, midY: topMidY, scale: scale, opacity: 0.6)
        row(processed, in: &context, size: size, midY: bottomMidY, scale: scale, opacity: 0.55)
        // The part of the processed row that sits outside where the
        // original's own edge was -- filled bright and outlined in white,
        // so the increase reads as a glow past the baseline shape rather
        // than as a second, equally-weighted waveform to compare by eye.
        growth(original, processed, in: &context, size: size,
              midY: bottomMidY, scale: scale)

        context.stroke(Path { p in
            p.move(to: CGPoint(x: 0, y: rowHeight))
            p.addLine(to: CGPoint(x: size.width, y: rowHeight))
        }, with: .color(.white.opacity(0.12)), lineWidth: 1)
    }

    private func row(_ envelope: WaveformEnvelope, in context: inout GraphicsContext,
                     size: CGSize, midY: CGFloat, scale: Double, opacity: Double) {
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            band(envelope.bass, in: &layer, size: size, midY: midY,
                scale: scale, color: Self.bass, opacity: opacity)
            band(envelope.mid, in: &layer, size: size, midY: midY,
                scale: scale, color: Self.mid, opacity: opacity * 0.8)
            band(envelope.treble, in: &layer, size: size, midY: midY,
                scale: scale, color: Self.treble, opacity: opacity)
        }
    }

    private func growth(_ before: WaveformEnvelope, _ after: WaveformEnvelope,
                        in context: inout GraphicsContext, size: CGSize,
                        midY: CGFloat, scale: Double) {
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            growthBand(before.bass, after.bass, in: &layer, size: size,
                      midY: midY, scale: scale, color: Self.bass)
            growthBand(before.mid, after.mid, in: &layer, size: size,
                      midY: midY, scale: scale, color: Self.mid)
            growthBand(before.treble, after.treble, in: &layer, size: size,
                      midY: midY, scale: scale, color: Self.treble)
        }
    }

    /// The ring between the original's edge and the processed edge, filled
    /// solid and outlined in white -- the outline is what makes it a lip
    /// standing past the baseline rather than just a brighter patch of the
    /// same shape.
    private func growthBand(_ before: [Float], _ after: [Float],
                            in context: inout GraphicsContext, size: CGSize,
                            midY: CGFloat, scale: Double, color: Color) {
        guard !before.isEmpty, before.count == after.count,
              zip(before, after).contains(where: { $1 > $0 }) else { return }
        context.fill(growthRing(before, after, size: size, midY: midY, scale: scale),
                     with: .color(color.opacity(0.95)))
        context.stroke(edge(after, size: size, midY: midY, scale: scale, sign: -1),
                       with: .color(.white.opacity(0.85)), lineWidth: 1.2)
        context.stroke(edge(after, size: size, midY: midY, scale: scale, sign: 1),
                       with: .color(.white.opacity(0.85)), lineWidth: 1.2)
    }

    /// One mirror half's outer boundary, open rather than closed -- for
    /// stroking the lip, not filling a shape.
    private func edge(_ values: [Float], size: CGSize, midY: CGFloat,
                      scale: Double, sign: CGFloat) -> Path {
        let step = size.width / CGFloat(values.count)
        var path = Path()
        for (index, value) in values.enumerated() {
            let x = CGFloat(index) * step
            let point = CGPoint(x: x, y: midY + sign * CGFloat(Double(value) * scale))
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }

    /// Both mirror halves of the annulus between `before` and `after`, as
    /// one fillable path: forward along the inner (original) edge, across
    /// to the outer (processed) edge, back along it, closed.
    private func growthRing(_ before: [Float], _ after: [Float], size: CGSize,
                            midY: CGFloat, scale: Double) -> Path {
        var path = ringHalf(before, after, size: size, midY: midY, scale: scale, sign: -1)
        path.addPath(ringHalf(before, after, size: size, midY: midY, scale: scale, sign: 1))
        return path
    }

    private func ringHalf(_ before: [Float], _ after: [Float], size: CGSize,
                          midY: CGFloat, scale: Double, sign: CGFloat) -> Path {
        let step = size.width / CGFloat(before.count)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: midY + sign * CGFloat(Double(before[0]) * scale)))
        for (index, value) in before.enumerated() {
            let x = CGFloat(index) * step
            path.addLine(to: CGPoint(x: x, y: midY + sign * CGFloat(Double(value) * scale)))
        }
        path.addLine(to: CGPoint(x: size.width,
                                 y: midY + sign * CGFloat(Double(after[after.count - 1]) * scale)))
        for (index, value) in after.enumerated().reversed() {
            let x = CGFloat(index) * step
            path.addLine(to: CGPoint(x: x, y: midY + sign * CGFloat(Double(value) * scale)))
        }
        path.closeSubpath()
        return path
    }

    /// One band's silhouette, mirrored top and bottom around the centre
    /// line -- the ordinary shape of a waveform, just in one color band
    /// rather than all of them at once.
    private func band(_ values: [Float], in context: inout GraphicsContext,
                      size: CGSize, midY: CGFloat, scale: Double,
                      color: Color, opacity: Double) {
        guard !values.isEmpty else { return }
        let path = silhouette(values, size: size, midY: midY, scale: scale)
        context.fill(path, with: .color(color.opacity(opacity)))
    }

    /// Only the part where the processed track exceeds the original --
    /// what this run actually added, in that band. Where it did not add
    /// anything, nothing is drawn, which is the honest answer rather than
    /// a colored bar implying a change that was not there.
    private func delta(_ before: [Float], _ after: [Float],
                       in context: inout GraphicsContext, size: CGSize,
                       midY: CGFloat, scale: Double, color: Color) {
        guard !before.isEmpty, before.count == after.count else { return }
        let added = zip(before, after).map { max(0, $1 - $0) }
        guard added.contains(where: { $0 > 0 }) else { return }
        let path = silhouette(added, size: size, midY: midY, scale: scale)
        context.fill(path, with: .color(color.opacity(0.95)))
    }

    /// A closed path tracing the top edge left-to-right and the mirrored
    /// bottom edge back again, rather than one rectangle per column --
    /// smoother, and `Canvas` fills one path far cheaper than hundreds of
    /// tiny ones.
    private func silhouette(_ values: [Float], size: CGSize, midY: CGFloat,
                            scale: Double) -> Path {
        let step = size.width / CGFloat(values.count)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: midY))
        for (index, value) in values.enumerated() {
            let x = CGFloat(index) * step
            let height = CGFloat(Double(value) * scale)
            path.addLine(to: CGPoint(x: x, y: midY - height))
        }
        path.addLine(to: CGPoint(x: size.width, y: midY))
        for (index, value) in values.enumerated().reversed() {
            let x = CGFloat(index) * step
            let height = CGFloat(Double(value) * scale)
            path.addLine(to: CGPoint(x: x, y: midY + height))
        }
        path.closeSubpath()
        return path
    }
}
