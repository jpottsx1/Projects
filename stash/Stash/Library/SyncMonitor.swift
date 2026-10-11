import CloudKit
import CoreData
import Foundation
import Observation

/// Whether iCloud sync is working, for the line at the foot of the sidebar.
///
/// SwiftData syncs through Core Data's CloudKit mirroring, which announces
/// each setup, import and export it does; this listens to those.
@MainActor
@Observable
final class SyncMonitor {
    /// Set by `ICLOUD_SYNC` in Config/Stash.xcconfig.
    #if ICLOUD_SYNC
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif

    enum State: Equatable {
        case starting
        case syncing
        case upToDate
        case noAccount
        case failed(String)
    }

    private(set) var state: State = .starting
    private(set) var lastSynced: Date?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        guard Self.isEnabled else { return }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            MainActor.assumeIsolated { self?.handle(event) }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccount() }
        })

        checkAccount()
    }

    private func handle(_ event: NSPersistentCloudKitContainer.Event) {
        if event.endDate == nil {
            state = .syncing
        } else if event.succeeded {
            lastSynced = event.endDate
            state = .upToDate
        } else if let error = event.error {
            state = .failed(Self.describe(error))
        }
    }

    /// CloudKit's own messages are written for developers; the commonest
    /// ones get plainer words.
    private static func describe(_ error: Error) -> String {
        switch (error as? CKError)?.code {
        case .networkUnavailable, .networkFailure: "No internet connection. Changes will sync when you're back online."
        case .quotaExceeded: "Your iCloud storage is full."
        case .notAuthenticated: "Sign in to iCloud in Settings to sync."
        default: error.localizedDescription
        }
    }

    private func checkAccount() {
        Task {
            let status = try? await CKContainer.default().accountStatus()
            if status == .available {
                if state == .noAccount { state = .starting }
            } else {
                state = .noAccount
            }
        }
    }
}
