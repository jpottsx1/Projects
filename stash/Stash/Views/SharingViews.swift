import CloudKit
import CoreTransferable
import SwiftUI
import StashCore

/// A category to share through iCloud, for the system's sharing sheet:
/// the share is made (with its zone) when someone's invited.
struct CategoryShare: Transferable {
    let category: ItemCategory

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { transfer in
            .prepareShare(container: Sharing.container ?? CKContainer.default(),
                          allowedSharingOptions: CKAllowedSharingOptions(allowedParticipantPermissionOptions: .readOnly,
                                                                         allowedParticipantAccessOptions: .specifiedRecipientsOnly)) {
                guard let sharing = await Sharing.shared else { throw CKError(.notAuthenticated) }
                return try await sharing.prepareShare(for: transfer.category)
            }
        }
    }
}

/// Sharing a category: inviting people, who's in, and stopping.
struct ShareCategorySheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let category: ItemCategory
    @State private var share: CKShare?
    @State private var isLoading = true
    @State private var confirmingStop = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ShareLink(item: CategoryShare(category: category), preview: SharePreview(category.name)) {
                        Label(category.sharedZoneName.isEmpty ? "Invite People…" : "Invite More People…", systemImage: "person.crop.circle.badge.plus")
                    }
                } footer: {
                    Text("People you invite see “\(category.name)” and everything in it, in Shared with Me in their Stash, and see changes as you make them. They can read and search it, but not change it yet. Locked items aren't shared. They need Stash and an iCloud account.")
                }
                if let share, !share.participants.filter({ $0.role != .owner }).isEmpty {
                    Section("Shared With") {
                        ForEach(share.participants.filter { $0.role != .owner }, id: \.self) { participant in
                            LabeledContent(Self.name(of: participant), value: Self.status(of: participant))
                        }
                    }
                } else if isLoading, !category.sharedZoneName.isEmpty {
                    ProgressView()
                }
                if !category.sharedZoneName.isEmpty {
                    Section {
                        Button("Stop Sharing", role: .destructive) { confirmingStop = true }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Share “\(category.name)”")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .sheetSize(minWidth: 440, minHeight: 360)
        .task {
            share = await Sharing.shared?.share(of: category)
            isLoading = false
        }
        .confirmationDialog("Stop sharing “\(category.name)”?", isPresented: $confirmingStop) {
            Button("Stop Sharing", role: .destructive) {
                Task {
                    do {
                        try await Sharing.shared?.stopSharing(category)
                        dismiss()
                    } catch {
                        message = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("It's taken out of everyone else's Stash. Your copy stays as it is.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        }
    }

    private static func name(of participant: CKShare.Participant) -> String {
        if let parts = participant.userIdentity.nameComponents {
            let name = PersonNameComponentsFormatter.localizedString(from: parts, style: .default)
            if !name.isEmpty { return name }
        }
        return participant.userIdentity.lookupInfo?.emailAddress ?? participant.userIdentity.lookupInfo?.phoneNumber ?? "Someone"
    }

    private static func status(of participant: CKShare.Participant) -> String {
        switch participant.acceptanceStatus {
        case .accepted: "Joined"
        case .pending: "Invited"
        case .removed: "Removed"
        default: ""
        }
    }
}

/// Shared with Me, read only for now: says so above the list.
struct SharedLibraryBanner: View {
    var body: some View {
        Label("Shared with you. Read only for now: changes made here are replaced when the owner changes them.",
              systemImage: "person.2")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
    }
}
