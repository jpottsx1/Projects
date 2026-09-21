import SwiftUI
import AppKit
import LoudnessKit

/// The survey, in the app.
///
/// This is the report that has been sending us to a terminal. Two numbers
/// on it decide things the project has been waiting on: how much of a
/// folder arrived already clipped, and how far a folder's low end sits
/// under a reference. The second is what a profile's caps are supposed to
/// be derived from.
struct SurveyPanel: View {
    let survey: Survey?
    let isMeasuring: Bool
    let progress: Double?
    let progressNote: String?
    @Binding var reference: String
    let onMeasure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isMeasuring {
                VStack(alignment: .leading, spacing: 3) {
                    if let progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(progressNote ?? "Walking the folders…")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            if let survey, survey.measured > 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        loudness(survey)
                        clipping(survey)
                        targets(survey)
                        lowEnd(survey)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                empty
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Survey").font(.headline).help(Help.survey.summary)
            if isMeasuring { ProgressView().controlSize(.small) }
            Spacer()
            if let survey, survey.measured > 0 {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(survey.asText(), forType: .string)
                }
                .buttonStyle(.link)
                .help("The whole survey as text")
            }
            Button("Measure") { onMeasure() }
                .disabled(isMeasuring)
                .help(Help.survey.detail)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text(isMeasuring ? "" : "Nothing measured yet.")
                .foregroundStyle(.secondary)
            Text("Measuring reads the files and writes nothing. "
                 + "It is how a folder's clipping and low end are found.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loudness(_ survey: Survey) -> some View {
        section("\(survey.measured) tracks measured") {
            HStack(spacing: 18) {
                figure("LUFS-I", survey.medianLUFSI)
                figure("s_p95", survey.medianSP95)
                figure("LRA", survey.medianLRA)
                figure("peak", survey.medianTruePeak, unit: "dBTP")
            }
            Text("Medians across the library.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func clipping(_ survey: Survey) -> some View {
        section("Masters that were already clipped") {
            let clip = survey.clipping
            Text(String(format: "%d of %d tracks (%.0f%%) carry runs of "
                        + "consecutive full-scale samples.",
                        clip.tracks, survey.measured, clip.share * 100))
            Text(String(format: "%d (%.0f%%) carry more than a hundred runs.",
                        clip.heavy, clip.heavyShare * 100))
                .foregroundStyle(.secondary)
            if clip.tracks > 0 {
                Text("Median among those that have any: \(clip.medianRuns) runs.")
                    .foregroundStyle(.secondary)
            }
            if let worst = clip.worst {
                Text("Worst: \(worst.name) — \(worst.runs) runs.")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            // The decision this number is for, said plainly, because the
            // honest gain through a lossy codec is small and the cost is a
            // generation of it.
            Text(advice(clip))
                .font(.callout)
                .padding(.top, 2)
        }
    }

    private func advice(_ clip: Survey.Clipping) -> String {
        switch clip.share {
        case ..<0.05:
            return "Barely any of this is clipped. De-clipping would cost a "
                 + "lossy generation to change almost nothing."
        case ..<0.20:
            return "A minority is clipped. Worth trying on those tracks, "
                 + "not worth turning on for the whole folder."
        default:
            return "A large share is clipped. This is the case de-clipping "
                 + "was built for — though through MP3 the honest gain is "
                 + "about 2 dB at light clipping, falling to 0.4 at heavy, "
                 + "so listen before committing the folder to it."
        }
    }

    /// The other half of the original problem: everything plays at a
    /// different level, and the question is what to level it TO. A negative
    /// gain is free; a positive one eventually needs a limiter, which is the
    /// thing this project exists to avoid. So the useful target is the
    /// lowest row where almost nothing is turned up.
    private func targets(_ survey: Survey) -> some View {
        section("Levelling: how many tracks would need a boost") {
            HStack(spacing: 8) {
                Text("target").frame(width: 56, alignment: .trailing)
                Text("boost").frame(width: 56, alignment: .trailing)
                Text("> +3 dB").frame(width: 62, alignment: .trailing)
                Text("over ceiling").frame(width: 84, alignment: .trailing)
                Spacer()
            }
            .font(.caption2).foregroundStyle(.secondary)
            ForEach(survey.targets) { row in
                HStack(spacing: 8) {
                    Text(String(format: "%.0f", row.targetLUFS))
                        .frame(width: 56, alignment: .trailing)
                    Text(String(format: "%.0f%%", row.needBoost * 100))
                        .frame(width: 56, alignment: .trailing)
                    Text(String(format: "%.0f%%", row.bigBoost * 100))
                        .frame(width: 62, alignment: .trailing)
                    Text(String(format: "%.0f%%", row.wouldExceedCeiling * 100))
                        .frame(width: 84, alignment: .trailing)
                        .foregroundStyle(row.wouldExceedCeiling > 0.05
                                         ? .orange : .primary)
                    Spacer()
                }
                .font(.system(.caption, design: .monospaced))
            }
            Text("On s_p95. The useful target is the lowest row where almost "
                 + "nothing is turned up.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lowEnd(_ survey: Survey) -> some View {
        section("Low end by folder, 31.5–63 Hz") {
            TextField("reference folder", text: $reference)
                .help("The folder the others are measured against. "
                      + "This is where a profile's caps come from.")
            if !reference.isEmpty && survey.reference == nil {
                Text("No single folder matches \"\(reference)\".")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(survey.folders) { row in
                HStack(spacing: 8) {
                    Text(row.folder)
                        .lineLimit(1).truncationMode(.middle)
                        .fontWeight(row.folder == survey.reference ? .semibold : .regular)
                    Spacer(minLength: 6)
                    Text("\(row.tracks)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                    Text(String(format: "%+.2f", row.mean))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 52, alignment: .trailing)
                    Text(row.deficitVsReference.map { String(format: "%+.2f", $0) }
                         ?? (row.folder == survey.reference ? "ref" : "—"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(row.folder == survey.reference
                                         ? .secondary : .primary)
                        .frame(width: 52, alignment: .trailing)
                }
                .font(.callout)
            }
            Text("Every folder measured, not only the ones selected — a "
                 + "reference measured in an earlier pass still counts.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Mean shape, then dB against the reference. A folder "
                 + "sitting several dB under is what the sub stage is for, "
                 + "and how far under is what a profile's cap should be set "
                 + "from.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func figure(_ label: String, _ value: Double?,
                        unit: String = "") -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.2f", $0) } ?? "—")
                .font(.system(.body, design: .monospaced))
            if !unit.isEmpty {
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.caption).bold().foregroundStyle(.secondary)
            content()
        }
    }
}
