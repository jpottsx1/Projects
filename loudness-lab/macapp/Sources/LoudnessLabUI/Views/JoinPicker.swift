import SwiftUI

/// Where the song arrives, and so how much of its own opening is replaced.
///
/// An intro edit cuts the original's opening out and puts the new intro in
/// its place, so the one decision that matters is the bar line the song
/// arrives at. The tool suggests where the groove lands; this is how to see
/// that and move it: a strip of the whole track to find the drop, and a
/// zoomed strip around the join to place it, both with the bar lines drawn
/// and the marker snapping to them (a join between beats would only be a way
/// to make a bad edit).
struct JoinPicker: View {
    @ObservedObject var engine: IntroEngine
    let track: IntroEngine.Track

    /// Seconds the detail strip shows. Seconds rather than a zoom factor,
    /// because what the person is judging is "a few bars either side".
    @State private var detailSeconds = 24.0
    /// The detail strip's centre while a drag is in progress. It follows the
    /// join, which would drag the picture out from under the pointer, so for
    /// the length of a drag it stays where it was.
    @State private var frozenCenter: Double?

    private var bars: [Double] { track.barSeconds }
    private var joinSeconds: Double { JoinMath.seconds(ofBar: engine.joinBar, in: bars) }
    private var total: Double { engine.envelope?.seconds ?? track.seconds }
    private var moved: Bool { engine.joinBar != track.suggestedJoinBar }

    var body: some View {
        if bars.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Where the song starts").font(.subheadline.weight(.semibold))
                readout
                if let envelope = engine.envelope {
                    overview(envelope)
                    detail(envelope)
                } else {
                    Text("Drawing the track…").font(.caption).foregroundStyle(.secondary)
                }
                controls
                Text(reason)
                    .font(.caption).foregroundStyle(moved ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Text

    private var readout: some View {
        let seconds = joinSeconds
        return Text(engine.joinBar == 0
                    ? "The song starts at its first bar. Its own opening is kept."
                    : "The song arrives at bar \(engine.joinBar), \(JoinMath.clock(seconds)) in. "
                      + "The first \(JoinMath.clock(seconds)) of the original is replaced by the intro.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var reason: String {
        moved
            ? "Moved from the suggestion, bar \(track.suggestedJoinBar) "
              + "(\(JoinMath.clock(JoinMath.seconds(ofBar: track.suggestedJoinBar, in: bars))))."
            : track.joinReason
    }

    // MARK: - Strips

    private func overview(_ envelope: JoinEnvelope) -> some View {
        GeometryReader { geo in
            Canvas { context, size in
                let window = 0...max(total, 0.001)
                drawBands(&context, size: size, envelope: envelope, window: window)
                drawJoin(&context, size: size, window: window, labels: false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                set(bar: JoinMath.nearestBar(
                    to: JoinMath.seconds(forX: value.location.x, in: 0...max(total, 0.001),
                                         width: geo.size.width),
                    in: bars))
            })
        }
        .overlay(PlayheadLayer(engine: engine, window: 0...max(total, 0.001)))
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
        .help("The whole track. Click or drag to move the join; it snaps to a bar line.")
    }

    private func detail(_ envelope: JoinEnvelope) -> some View {
        GeometryReader { geo in
            let window = JoinMath.window(center: frozenCenter ?? joinSeconds,
                                         width: detailSeconds, total: total)
            Canvas { context, size in
                drawBands(&context, size: size, envelope: envelope, window: window)
                drawJoin(&context, size: size, window: window, labels: true)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let center = frozenCenter ?? joinSeconds
                    if frozenCenter == nil { frozenCenter = center }
                    let frozen = JoinMath.window(center: center, width: detailSeconds, total: total)
                    set(bar: JoinMath.nearestBar(
                        to: JoinMath.seconds(forX: value.location.x, in: frozen, width: geo.size.width),
                        in: bars))
                }
                .onEnded { _ in frozenCenter = nil })
        }
        .overlay(PlayheadLayer(engine: engine,
                               window: JoinMath.window(center: frozenCenter ?? joinSeconds,
                                                       width: detailSeconds, total: total)))
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
        .help("Zoomed in on the join, with the bar lines drawn. Click or drag to place "
              + "it; it snaps to a bar line.")
    }

    /// The three bands as mirrored columns, bass in front, in the colours the
    /// rest of the app uses for them. A column on screen is the PEAK of what it
    /// covers: a mean would flatten the kicks the picture is for.
    private func drawBands(_ context: inout GraphicsContext, size: CGSize,
                           envelope: JoinEnvelope, window: ClosedRange<Double>) {
        let midY = size.height / 2
        let columns = max(1, Int(size.width))
        let span = window.upperBound - window.lowerBound
        let step = span / Double(columns)
        for column in 0..<columns {
            let t0 = window.lowerBound + Double(column) * step
            let t1 = t0 + step
            let x = CGFloat(column)
            for (band, color, opacity) in [(envelope.treble, WaveformView.treble, 0.55),
                                           (envelope.mid, WaveformView.mid, 0.55),
                                           (envelope.bass, WaveformView.bass, 0.75)] {
                let height = CGFloat(envelope.peak(band, from: t0, to: t1)) * midY * 0.95
                guard height > 0.2 else { continue }
                context.fill(Path(CGRect(x: x, y: midY - height, width: 1, height: height * 2)),
                             with: .color(color.opacity(opacity)))
            }
        }
    }

    /// Bar lines, the replaced part dimmed, and the join itself.
    private func drawJoin(_ context: inout GraphicsContext, size: CGSize,
                          window: ClosedRange<Double>, labels: Bool) {
        let barSeconds = bars
        let joinX = JoinMath.x(for: joinSeconds, in: window, width: size.width)

        // Bar lines, thinned until they are not a wall: one per bar when
        // there is room, then every 2nd, 4th... as the picture is squeezed.
        let span = window.upperBound - window.lowerBound
        let barLength = barSeconds.count > 1 ? (barSeconds.last! - barSeconds.first!) / Double(barSeconds.count - 1) : 2
        let pixelsPerBar = size.width * CGFloat(barLength / max(span, 0.001))
        let every = [1, 2, 4, 8, 16, 32].first { CGFloat($0) * pixelsPerBar >= (labels ? 34 : 6) } ?? 32
        for (index, t) in barSeconds.enumerated() where t >= window.lowerBound && t <= window.upperBound {
            guard index % every == 0 else { continue }
            let x = JoinMath.x(for: t, in: window, width: size.width)
            var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.primary.opacity(index % 4 == 0 ? 0.22 : 0.12)), lineWidth: 0.5)
            if labels {
                context.draw(Text("\(index)").font(.system(size: 9)).foregroundColor(.secondary),
                             at: CGPoint(x: x + 3, y: 8), anchor: .leading)
            }
        }

        // What the intro replaces.
        if joinX > 0 {
            context.fill(Path(CGRect(x: 0, y: 0, width: min(joinX, size.width), height: size.height)),
                         with: .color(.black.opacity(0.32)))
            if labels, joinX > 90 {
                context.draw(Text("replaced by the intro").font(.system(size: 10).weight(.medium))
                                .foregroundColor(.white.opacity(0.85)),
                             at: CGPoint(x: min(joinX, size.width) - 6, y: size.height - 10),
                             anchor: .trailing)
            }
        }

        // The suggestion, when the person has moved off it.
        if moved {
            let x = JoinMath.x(for: JoinMath.seconds(ofBar: track.suggestedJoinBar, in: barSeconds),
                               in: window, width: size.width)
            if x >= 0 && x <= size.width {
                var dash = Path(); dash.move(to: CGPoint(x: x, y: 0)); dash.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(dash, with: .color(.orange.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }

        // The join.
        if joinX >= -1 && joinX <= size.width + 1 {
            var line = Path(); line.move(to: CGPoint(x: joinX, y: 0)); line.addLine(to: CGPoint(x: joinX, y: size.height))
            context.stroke(line, with: .color(.accentColor), lineWidth: 2)
            var flag = Path()
            flag.move(to: CGPoint(x: joinX, y: 0))
            flag.addLine(to: CGPoint(x: joinX + 9, y: 0))
            flag.addLine(to: CGPoint(x: joinX, y: 9))
            flag.closeSubpath()
            context.fill(flag, with: .color(.accentColor))
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Bar").frame(width: 44, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(engine.joinBar) },
                    set: { set(bar: Int($0.rounded())) }),
                       in: 0...Double(max(1, track.lastJoinBar)), step: 1)
                Text("\(engine.joinBar)")
                    .font(.system(.callout, design: .monospaced)).frame(width: 34, alignment: .trailing)
            }
            .help("Move the join one bar at a time. Zero keeps the whole opening.")
            HStack(spacing: 6) {
                ForEach([-4, -1, 1, 4], id: \.self) { step in
                    Button(step > 0 ? "+\(step)" : "\(step)") { set(bar: engine.joinBar + step) }
                        .help("Move the join \(abs(step)) bar\(abs(step) == 1 ? "" : "s") "
                              + (step > 0 ? "later" : "earlier"))
                }
                Button("Suggested") { set(bar: track.suggestedJoinBar) }
                    .disabled(!moved)
                    .help("Back to where the groove lands.")
                Spacer()
                HearButton(engine: engine)
            }
            .controlSize(.small)
            HStack(spacing: 8) {
                Text("Zoom").frame(width: 44, alignment: .leading)
                Slider(value: Binding(get: { log(detailSeconds) },
                                      set: { detailSeconds = exp($0) }),
                       in: log(4)...log(90))
                Text("\(Int(detailSeconds.rounded())) s")
                    .font(.system(.caption, design: .monospaced)).frame(width: 42, alignment: .trailing)
            }
            .help("How many seconds the lower strip shows. Zoom in to place the join "
                  + "against a single beat.")
        }
        .disabled(engine.isBusy)
    }

    private func set(bar: Int) {
        let clamped = JoinMath.clamp(bar, in: bars)
        if clamped != engine.joinBar { engine.joinBar = clamped }
    }
}


/// Hear it, which becomes Stop while something is playing, with the time.
private struct HearButton: View {
    @ObservedObject var engine: IntroEngine
    @ObservedObject private var player: ABPlayer

    init(engine: IntroEngine) {
        self.engine = engine
        self.player = engine.player
    }

    var body: some View {
        HStack(spacing: 8) {
            if player.isPlaying {
                Text(JoinMath.clock(engine.originalTime(atPlayerPosition: player.position) ?? player.position))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Button("Stop") { engine.stopPlaying() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Stop playing.")
            } else {
                Button("Hear it") { engine.playOriginal() }
                    .help("Plays the original from a few seconds before the join, which is "
                          + "what the intro will lead into.")
            }
        }
    }
}

/// The playhead, drawn over a strip. It lives in its own view because the
/// player moves twenty times a second and the picker should not be redrawn
/// for that. For the original it is where the song is; for a rendered file it
/// sweeps the replaced stretch while the new intro plays, then follows the
/// song (see `IntroEngine.originalTime`).
private struct PlayheadLayer: View {
    let engine: IntroEngine
    @ObservedObject private var player: ABPlayer
    let window: ClosedRange<Double>

    init(engine: IntroEngine, window: ClosedRange<Double>) {
        self.engine = engine
        self.player = engine.player
        self.window = window
    }

    var body: some View {
        Canvas { context, size in
            guard player.isPlaying,
                  let t = engine.originalTime(atPlayerPosition: player.position),
                  t >= window.lowerBound, t <= window.upperBound else { return }
            let x = JoinMath.x(for: t, in: window, width: size.width)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.white), lineWidth: 2)
            context.stroke(line, with: .color(.black.opacity(0.5)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}
