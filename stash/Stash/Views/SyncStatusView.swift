import SwiftUI

/// One line at the foot of the sidebar, only when iCloud sync is turned on.
struct SyncStatusView: View {
    @Environment(SyncMonitor.self) private var sync

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(isProblem ? Color.orange : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var symbol: String {
        switch sync.state {
        case .starting, .syncing: "arrow.triangle.2.circlepath.icloud"
        case .upToDate: "checkmark.icloud"
        case .noAccount: "icloud.slash"
        case .failed: "exclamationmark.icloud"
        }
    }

    private var isProblem: Bool {
        switch sync.state {
        case .noAccount, .failed: true
        default: false
        }
    }

    private var headline: String {
        switch sync.state {
        case .starting: "Connecting to iCloud…"
        case .syncing: "Syncing…"
        case .upToDate: "Synced with iCloud"
        case .noAccount: "Not signed in to iCloud"
        case .failed: "Sync problem"
        }
    }

    private var detail: String? {
        switch sync.state {
        case .failed(let message): message
        case .noAccount: "Sign in to iCloud in Settings to sync between your devices."
        case .upToDate, .syncing: sync.lastSynced.map { "Last synced " + $0.formatted(date: .omitted, time: .shortened) }
        case .starting: nil
        }
    }
}
