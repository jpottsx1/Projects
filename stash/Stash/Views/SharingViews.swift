import CloudKit
import CoreTransferable
import SwiftUI
import StashCore

/// A category or item to share through iCloud, for the system's sharing
/// sheet: the share is made (with its zone) when someone's invited.
struct ShareTransfer: Transferable {
    let target: ShareTarget

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { transfer in
            // The standard choices: who can open it, and whether they can make changes.
            .prepareShare(container: Sharing.container ?? CKContainer.default(), allowedSharingOptions: .standard) {
                guard let sharing = await Sharing.shared else { throw CKError(.notAuthenticated) }
                return try await sharing.prepareShare(for: transfer.target)
            }
        }
    }
}

/// Sharing a category or an item: inviting people, who's in, the link, and stopping.
struct ShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let target: ShareTarget
    @State private var share: CKShare?
    @State private var isLoading = true
    @State private var confirmingStop = false
    @State private var message: String?

    private var isShared: Bool { !target.zoneName.isEmpty }
    private var others: [CKShare.Participant] { share?.participants.filter { $0.role != .owner } ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                inviteSection
                if !others.isEmpty { peopleSection } else if isLoading, isShared { ProgressView() }
                if isShared, let share { linkSection(share) }
                if isShared {
                    Section {
                        Button("Stop Sharing", role: .destructive) { confirmingStop = true }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Share “\(target.name)”")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .sheetSize(minWidth: 440, minHeight: 400)
        .task {
            share = await Sharing.shared?.share(of: target)
            isLoading = false
        }
        .confirmationDialog("Stop sharing “\(target.name)”?", isPresented: $confirmingStop) {
            Button("Stop Sharing", role: .destructive) { stop() }
        } message: {
            Text("It's taken out of everyone else's Stash. Your copy stays as it is.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        }
    }

    private var inviteSection: some View {
        Section {
            ShareLink(item: ShareTransfer(target: target), preview: SharePreview(target.name)) {
                Label(isShared ? "Invite More People…" : "Invite People…", systemImage: "person.crop.circle.badge.plus")
            }
        } footer: {
            Text(Self.explanation(for: target))
        }
    }

    private static func explanation(for target: ShareTarget) -> String {
        let what: String
        switch target {
        case .category(let category): what = "“\(category.name)” and everything in it"
        case .item(let item): what = "“\(item.displayTitle)”"
        }
        return "People you invite see \(what) in Shared with Me in their Stash, with changes as they're made. "
            + "Invite them to view only, or to make changes: theirs come back here (anything they delete goes to your Trash), "
            + "with who made the last change. If you both change something, the later change wins and the other's note text "
            + "is kept in its history. Locked items aren't shared. They need Stash and an iCloud account."
    }

    private var peopleSection: some View {
        Section("Shared With") {
            ForEach(others, id: \.self) { participant in
                LabeledContent(Self.name(of: participant), value: Self.detail(of: participant))
            }
        }
    }

    private func linkSection(_ share: CKShare) -> some View {
        Section {
            Toggle("Anyone with the Link Can View", isOn: Binding(get: { share.publicPermission != .none }, set: { open in
                Task {
                    do {
                        self.share = try await Sharing.shared?.setOpenToAnyoneWithLink(open, target)
                    } catch {
                        message = error.localizedDescription
                    }
                }
            }))
            if let url = share.url {
                Button("Copy Link") { copyToClipboard(url.absoluteString) }
            }
        } footer: {
            Text("With the link on, anyone who has it can open this in their Stash, to view; without it, only people you invite can.")
        }
    }

    private func stop() {
        Task {
            do {
                try await Sharing.shared?.stopSharing(target)
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private static func name(of participant: CKShare.Participant) -> String {
        if let parts = participant.userIdentity.nameComponents {
            let name = PersonNameComponentsFormatter.localizedString(from: parts, style: .default)
            if !name.isEmpty { return name }
        }
        return participant.userIdentity.lookupInfo?.emailAddress ?? participant.userIdentity.lookupInfo?.phoneNumber ?? "Someone"
    }

    private static func detail(of participant: CKShare.Participant) -> String {
        let status: String
        switch participant.acceptanceStatus {
        case .accepted: status = "Joined"
        case .pending: status = "Invited"
        case .removed: status = "Removed"
        default: status = ""
        }
        let permission = participant.permission == .readWrite ? "Can make changes" : "View only"
        return [status, permission].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Shared with Me: what the marks beside categories mean.
struct SharedLibraryBanner: View {
    var body: some View {
        Label("Shared with you. Where you're allowed (a two-person mark beside the category), your changes go back to its owner; where you can only view (an eye), changes made here are replaced by the owner's.",
              systemImage: "person.2")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
    }
}

/// "Last changed by Ann, 2 hours ago", on shared items others have changed.
struct LastChangedBy: View {
    let item: Item

    var body: some View {
        if !item.lastEditedBy.isEmpty {
            Label("Last changed by \(item.lastEditedBy), \(item.modifiedAt.formatted(.relative(presentation: .named)))",
                  systemImage: "person.crop.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
