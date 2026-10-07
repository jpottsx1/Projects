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
    /// An outro marks where the song LEAVES; an intro where it arrives. The
    /// strips, the snapping and the controls are the same either way, so the
    /// marker is whichever bar the mode is choosing.
    private var outro: Bool { engine.mode == .outro }
    private var markerBar: Int { outro ? engine.exitBar : engine.joinBar }
    private var suggestedBar: Int { outro ? track.suggestedExitBar : track.suggestedJoinBar }
    private var joinSeconds: Double { JoinMath.seconds(ofBar: markerBar, in: bars) }
    private var total: Double { engine.envelope?.seconds ?? track.seconds }
    private var moved: Bool { markerBar != suggestedBar }
    private var lowestBar: Int { outro ? JoinMath.firstExitBar : 0 }
    private var highestBar: Int { outro ? max(JoinMath.firstExitBar, bars.count - 1) : track.lastJoinBar }

    private func nearest(to seconds: Double) -> Int {
        outro ? JoinMath.nearestExit(to: seconds, in: bars) : JoinMath.nearestBar(to: seconds, in: bars)
    }

    var body: some View {
        if bars.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text(outro ? "Where the song leaves" : "Where the song starts")
                    .font(.subheadline.weight(.semibold))
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
        if outro {
            let rest = max(0, total - seconds)
            return Text(rest < 0.5
                        ? "The song is kept to its last bar line, and the outro follows it."
                        : "The song leaves at bar \(engine.exitBar), \(JoinMath.clock(seconds)) in. "
                          + "The last \(JoinMath.clock(rest)) of the original is replaced by the outro.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        return Text(engine.joinBar == 0
                    ? "The song starts at its first bar. Its own opening is kept."
                    : "The song arrives at bar \(engine.joinBar), \(JoinMath.clock(seconds)) in. "
                      + "The first \(JoinMath.clock(seconds)) of the original is replaced by the intro.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var reason: String {
        moved
            ? "Moved from the suggestion, bar \(suggestedBar) "
              + "(\(JoinMath.clock(JoinMath.seconds(ofBar: suggestedBar, in: bars))))."
            : (outro ? track.exitReason : track.joinReason)
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
                set(bar: nearest(to: JoinMath.seconds(forX: value.location.x, in: 0...max(total, 0.001),
                                                      width: geo.size.width)))
            })
        }
        .overlay(PlayheadLayer(engine: engine, window: 0...max(total, 0.001)))
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
        .help("The whole track. Click or drag to move the \(outro ? "exit" : "join"); it snaps to a bar line.")
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
                    set(bar: nearest(to: JoinMath.seconds(forX: value.location.x, in: frozen,
                                                          width: geo.size.width)))
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
        StripDrawing.bands(&context, size: size, envelope: envelope, window: window)
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

        // Beats and half beats, only where there is room to read them: the
        // evidence for whether the bar line is on the right beat.
        if labels {
            let beatPixels = pixelsPerBar / 4
            for (index, t) in barSeconds.enumerated() where index + 1 < barSeconds.count {
                let next = barSeconds[index + 1]
                guard next >= window.lowerBound, t <= window.upperBound else { continue }
                for k in 1..<8 {
                    let isBeat = k % 2 == 0
                    guard isBeat ? beatPixels >= 14 : beatPixels >= 36 else { continue }
                    let tick = t + (next - t) * Double(k) / 8
                    guard tick >= window.lowerBound, tick <= window.upperBound else { continue }
                    let x = JoinMath.x(for: tick, in: window, width: size.width)
                    var mark = Path()
                    mark.move(to: CGPoint(x: x, y: size.height)); mark.addLine(to: CGPoint(x: x, y: size.height - (isBeat ? 12 : 6)))
                    context.stroke(mark, with: .color(.primary.opacity(isBeat ? 0.45 : 0.25)), lineWidth: 1)
                }
            }
        }

        // What the outro replaces: everything after the exit.
        if outro, joinX < size.width {
            let from = max(joinX, 0)
            context.fill(Path(CGRect(x: from, y: 0, width: size.width - from, height: size.height)),
                         with: .color(.black.opacity(0.32)))
            if labels, size.width - from > 110 {
                context.draw(Text("replaced by the outro").font(.system(size: 10).weight(.medium))
                                .foregroundColor(.white.opacity(0.85)),
                             at: CGPoint(x: from + 6, y: size.height - 10), anchor: .leading)
            }
        }

        // What the intro replaces.
        if !outro, joinX > 0 {
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
            let x = JoinMath.x(for: JoinMath.seconds(ofBar: suggestedBar, in: barSeconds),
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
                    get: { Double(markerBar) },
                    set: { set(bar: Int($0.rounded())) }),
                       in: Double(lowestBar)...Double(max(lowestBar + 1, highestBar)), step: 1)
                Text("\(markerBar)")
                    .font(.system(.callout, design: .monospaced)).frame(width: 34, alignment: .trailing)
            }
            .help(outro ? "Move the exit one bar at a time. The last bar keeps the whole song."
                        : "Move the join one bar at a time. Zero keeps the whole opening.")
            HStack(spacing: 6) {
                ForEach([-4, -1, 1, 4], id: \.self) { step in
                    Button(step > 0 ? "+\(step)" : "\(step)") { set(bar: markerBar + step) }
                        .help("Move the \(outro ? "exit" : "join") \(abs(step)) bar\(abs(step) == 1 ? "" : "s") "
                              + (step > 0 ? "later" : "earlier"))
                }
                Button("Suggested") { set(bar: suggestedBar) }
                    .disabled(!moved)
                    .help(outro ? "Back to where the groove ends." : "Back to where the groove lands.")
                Spacer()
                HearButton(engine: engine)
            }
            .controlSize(.small)
            HStack(spacing: 6) {
                Text("Beat one").frame(width: 56, alignment: .leading)
                Button("◀ 1 beat") { Task { await engine.moveBeatOne(by: -1) } }
                Button("1 beat ▶") { Task { await engine.moveBeatOne(by: 1) } }
                Button("◀ ½") { Task { await engine.moveBeatOne(by: 0, halfBeats: -1) } }
                    .help("Move the whole grid half a beat earlier, for a song whose bar lines "
                          + "sit on the offbeat.")
                Button("½ ▶") { Task { await engine.moveBeatOne(by: 0, halfBeats: 1) } }
                    .help("Move the whole grid half a beat later, for a song whose bar lines "
                          + "sit on the offbeat.")
                Text(engine.beatShift == 0 && engine.halfShift == 0 ? track.downbeatFrom
                     : "moved \(Self.beats(engine.beatShift, engine.halfShift)) by hand")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .controlSize(.small)
            .help("Which beat is the first of the bar. If the numbered bar lines in the zoomed "
                  + "strip do not sit on the heaviest kick and bass hit, move them a beat "
                  + "either way, or half a beat when they sit on the offbeat. The small ticks are the beats, the fainter ones the half beats.")
            HStack(spacing: 8) {
                Text("Zoom").frame(width: 44, alignment: .leading)
                Slider(value: Binding(get: { log(detailSeconds) },
                                      set: { detailSeconds = exp($0) }),
                       in: log(4)...log(90))
                Text("\(Int(detailSeconds.rounded())) s")
                    .font(.system(.caption, design: .monospaced)).frame(width: 42, alignment: .trailing)
            }
            .help("How many seconds the lower strip shows. Zoom in to place the "
                  + "\(outro ? "exit" : "join") against a single beat.")
        }
        .disabled(engine.isBusy)
    }

    /// "1½ beats" from whole beats and half beats, the way a person says it.
    private static func beats(_ whole: Int, _ half: Int) -> String {
        let halves = whole * 2 + half
        let n = Double(halves) / 2
        let text = n == n.rounded() ? "\(Int(n))" : String(format: "%.1f", n)
        return "\(text) beat\(n == 1 ? "" : "s")"
    }

    private func set(bar: Int) {
        if outro {
            let clamped = JoinMath.clampExit(bar, in: bars)
            if clamped != engine.exitBar { engine.exitBar = clamped }
        } else {
            let clamped = JoinMath.clamp(bar, in: bars)
            if clamped != engine.joinBar { engine.joinBar = clamped }
        }
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
                    .help(engine.mode == .outro
                          ? "Plays the original from a few seconds before the exit, and on "
                            + "into the part the outro replaces."
                          : "Plays the original from a few seconds before the join, which is "
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


/// Drawing shared by the picker's strips and the finished edit's strip, so the
/// two are read the same way.
enum StripDrawing {
    static func bands(_ context: inout GraphicsContext, size: CGSize,
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
}

/// The finished edit as it will be heard: the same three bands, the stretch
/// the new intro occupies tinted, the join marked, and the playhead on it.
/// Clicking it plays from there.
struct EditStrip: View {
    @ObservedObject var engine: IntroEngine
    let render: IntroEngine.Render
    let envelope: JoinEnvelope

    var body: some View {
        GeometryReader { geo in
            let window = 0...max(envelope.seconds, 0.001)
            Canvas { context, size in
                StripDrawing.bands(&context, size: size, envelope: envelope, window: window)
                let isOutro = render.kind == .outro
                let joinX = JoinMath.x(for: isOutro ? render.exitSeconds : render.joinSeconds,
                                       in: window, width: size.width)
                if isOutro {
                    let from = max(0, min(joinX, size.width))
                    context.fill(Path(CGRect(x: from, y: 0, width: size.width - from, height: size.height)),
                                 with: .color(.accentColor.opacity(0.16)))
                    if size.width - from > 70 {
                        context.draw(Text("new outro").font(.system(size: 10).weight(.medium))
                                        .foregroundColor(.primary.opacity(0.7)),
                                     at: CGPoint(x: from + 6, y: size.height - 9), anchor: .leading)
                    }
                } else {
                    context.fill(Path(CGRect(x: 0, y: 0, width: max(0, min(joinX, size.width)),
                                             height: size.height)),
                                 with: .color(.accentColor.opacity(0.16)))
                    if joinX > 60 {
                        context.draw(Text("new intro").font(.system(size: 10).weight(.medium))
                                        .foregroundColor(.primary.opacity(0.7)),
                                     at: CGPoint(x: 6, y: size.height - 9), anchor: .leading)
                    }
                }
                var line = Path()
                line.move(to: CGPoint(x: joinX, y: 0)); line.addLine(to: CGPoint(x: joinX, y: size.height))
                context.stroke(line, with: .color(.accentColor), lineWidth: 2)
            }
            .overlay(EditPlayhead(engine: engine, render: render, total: envelope.seconds))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                engine.play(render, from: JoinMath.seconds(forX: value.location.x, in: window,
                                                           width: geo.size.width))
            })
        }
        .frame(height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
        .help(render.kind == .outro
              ? "The finished edit: the song up to the exit, then the new outro (tinted). "
                + "Click anywhere to play from there."
              : "The finished edit: the new intro (tinted), then the song from the join. "
                + "Click anywhere to play from there.")
    }
}

private struct EditPlayhead: View {
    let engine: IntroEngine
    let render: IntroEngine.Render
    let total: Double
    @ObservedObject private var player: ABPlayer

    init(engine: IntroEngine, render: IntroEngine.Render, total: Double) {
        self.engine = engine; self.render = render; self.total = total
        self.player = engine.player
    }

    var body: some View {
        Canvas { context, size in
            guard player.isPlaying, engine.playing == render.id else { return }
            let x = JoinMath.x(for: player.position, in: 0...max(total, 0.001), width: size.width)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.white), lineWidth: 2)
            context.stroke(line, with: .color(.black.opacity(0.5)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}
