import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import SwiftData
import StashCore

/// The key locked items are encrypted with: made at random once, and kept
/// in the library itself encrypted with a key worked out from a password
/// (PBKDF2), so every device opens it with the same password. The
/// password itself is never stored.
@Model
final class Vault {
    var uuid: UUID = UUID()
    var salt: Data?
    var rounds: Int = 0
    /// The library's key, sealed with the password's key.
    var wrappedKey: Data?
    var createdAt: Date = Date()

    init(salt: Data, rounds: Int, wrappedKey: Data) {
        self.salt = salt
        self.rounds = rounds
        self.wrappedKey = wrappedKey
    }
}

enum VaultCrypto {
    enum Failure: LocalizedError {
        case notSealed
        case derivation

        var errorDescription: String? {
            switch self {
            case .notSealed: "This isn’t encrypted data."
            case .derivation: "The password couldn’t be used."
            }
        }
    }

    /// PBKDF2-SHA256, as many rounds as current advice says.
    static let rounds = 600_000

    static func deriveKey(password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &derived, derived.count)
        }
        guard status == kCCSuccess else { throw Failure.derivation }
        return SymmetricKey(data: derived)
    }

    static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    static func seal(_ data: Data, with key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw Failure.notSealed }
        return SealedFormat.wrap(combined)
    }

    static func open(_ data: Data, with key: SymmetricKey) throws -> Data {
        guard let combined = SealedFormat.unwrap(data) else { throw Failure.notSealed }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
    }
}

/// Remembers the library's key in the Keychain, behind Face ID, Touch ID or
/// the device passcode, so it needn't be typed every time. Only where the
/// Keychain allows it: an app signed without a team (or the test library)
/// asks for the password instead.
enum VaultKeychain {
    private static let service = "com.jpottsx1.stash.vault"

    static var isEnabled: Bool { !StashStore.isTestLibrary }

    static func save(_ key: SymmetricKey, vault: UUID) {
        guard isEnabled,
              let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil)
        else { return }
        delete(vault: vault)
        let data = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vault.uuidString,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Asks for Face ID, Touch ID or the passcode; nil if there's no key
    /// kept, or it's refused.
    static func load(vault: UUID, reason: String) async -> SymmetricKey? {
        guard isEnabled else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let context = LAContext()
            context.localizedReason = reason
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: vault.uuidString,
                kSecReturnData as String: true,
                kSecUseAuthenticationContext as String: context,
                kSecUseDataProtectionKeychain as String: true,
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            return SymmetricKey(data: data)
        }.value
    }

    static func delete(vault: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vault.uuidString,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// What to do once the password has been given.
enum LockAction: Equatable {
    case lock([UUID])
    case unlock(UUID)
    case removeLock([UUID])
}

/// Asking for the password: to choose one (the first time anything is
/// locked), or to open the key.
struct PasswordRequest: Identifiable, Equatable {
    enum Kind { case create, enter }
    let id = UUID()
    var kind: Kind
    var then: LockAction
}

extension Library {
    func vaults() -> [Vault] {
        ((try? context.fetch(FetchDescriptor<Vault>())) ?? []).sorted { $0.uuid.uuidString < $1.uuid.uuidString }
    }

    /// The key new locks use: the first vault's, if it's open.
    func currentKey() -> (vault: Vault, key: SymmetricKey)? {
        for vault in vaults() {
            if let key = vaultKeys[vault.uuid] { return (vault, key) }
        }
        return nil
    }

    /// Makes the library's key, kept under this password.
    func createVault(password: String) throws {
        let key = SymmetricKey(size: .bits256)
        let salt = VaultCrypto.randomBytes(16)
        let passwordKey = try VaultCrypto.deriveKey(password: password, salt: salt, rounds: VaultCrypto.rounds)
        let wrapped = try VaultCrypto.seal(key.withUnsafeBytes { Data($0) }, with: passwordKey)
        let vault = Vault(salt: salt, rounds: VaultCrypto.rounds, wrappedKey: wrapped)
        context.insert(vault)
        save()
        vaultKeys[vault.uuid] = key
        VaultKeychain.save(key, vault: vault.uuid)
    }

    /// Opens every vault this password opens; false if it opens none.
    func openVaults(password: String) async -> Bool {
        var opened = false
        for vault in vaults() where vaultKeys[vault.uuid] == nil {
            guard let salt = vault.salt, let wrapped = vault.wrappedKey else { continue }
            let rounds = vault.rounds
            // Hundreds of thousands of rounds: off the main thread.
            let key: SymmetricKey? = await Task.detached(priority: .userInitiated) {
                guard let passwordKey = try? VaultCrypto.deriveKey(password: password, salt: salt, rounds: rounds),
                      let raw = try? VaultCrypto.open(wrapped, with: passwordKey) else { return nil }
                return SymmetricKey(data: raw)
            }.value
            if let key {
                vaultKeys[vault.uuid] = key
                VaultKeychain.save(key, vault: vault.uuid)
                opened = true
            }
        }
        return opened || vaults().contains { vaultKeys[$0.uuid] != nil }
    }

    /// The key for a vault: already open, or from the Keychain.
    func key(forVault id: UUID?, reason: String) async -> SymmetricKey? {
        guard let id else { return nil }
        if let key = vaultKeys[id] { return key }
        guard let key = await VaultKeychain.load(vault: id, reason: reason) else { return nil }
        vaultKeys[id] = key
        return key
    }

    // MARK: - Sealing

    /// Encrypts an item's text and files, leaving its title and tags.
    func seal(_ item: Item, vault: Vault, key: SymmetricKey) throws {
        guard !item.isSealed else { return }
        let contents = SealedContents(
            body: item.body, extractedText: item.extractedText, summary: item.summary,
            article: item.articleData, transcript: item.transcriptData,
            highlights: (item.highlights ?? []).map { .init(id: $0.uuid, text: $0.text, note: $0.note) })
        // Files first: if one can't be done, nothing has changed yet.
        try sealFiles(of: item, key: key)
        item.sealedData = try VaultCrypto.seal(contents.json, with: key)
        item.sealedVaultID = vault.uuid
        item.body = ""
        item.extractedText = ""
        item.summary = ""
        item.articleData = nil
        item.transcriptData = nil
        item.thumbnailData = nil
        for highlight in item.highlights ?? [] {
            highlight.text = ""
            highlight.note = ""
        }
        // Earlier versions are the text in the clear: they go.
        for version in item.versions ?? [] { context.delete(version) }
    }

    /// Puts an item back as it was before it was sealed.
    func unseal(_ item: Item, key: SymmetricKey) throws {
        guard let sealed = item.sealedData else { return }
        guard let contents = SealedContents(json: try VaultCrypto.open(sealed, with: key)) else { throw VaultCrypto.Failure.notSealed }
        try unsealFiles(of: item, key: key)
        item.body = contents.body
        item.extractedText = contents.extractedText
        item.summary = contents.summary
        item.articleData = contents.article
        item.transcriptData = contents.transcript
        for highlight in item.highlights ?? [] {
            guard let text = contents.highlights.first(where: { $0.id == highlight.uuid }) else { continue }
            highlight.text = text.text
            highlight.note = text.note
        }
        item.sealedData = nil
        item.sealedVaultID = nil
    }

    func openSealedContents(of item: Item, key: SymmetricKey) -> SealedContents? {
        guard let sealed = item.sealedData, let data = try? VaultCrypto.open(sealed, with: key) else { return nil }
        return SealedContents(json: data)
    }

    /// Changes a sealed item's text while it's unlocked, sealing it again at once.
    func updateSealed(_ item: Item, _ change: (inout SealedContents) -> Void) {
        guard var contents = openSeals[item.uuid], let id = item.sealedVaultID, let key = vaultKeys[id] else { return }
        change(&contents)
        guard let sealed = try? VaultCrypto.seal(contents.json, with: key) else { return }
        openSeals[item.uuid] = contents
        item.sealedData = sealed
        item.modifiedAt = .now
        save()
    }

    /// The document, saved page and pictures, each encrypted in place, and
    /// their synced copies with them.
    private func sealFiles(of item: Item, key: SymmetricKey) throws {
        if let path = item.storedFilePath {
            item.fileData = try sealFile(path, synced: item.fileData, key: key)
            try? FileManager.default.removeItem(at: files.url(for: files.originalPath(for: path)))
        }
        if let path = item.archivePath {
            item.archiveData = try sealFile(path, synced: item.archiveData, key: key)
        }
        for attachment in item.attachments ?? [] {
            guard let data = attachment.data, !SealedFormat.isSealed(data) else { continue }
            let sealed = try VaultCrypto.seal(data, with: key)
            attachment.data = sealed
            try? files.write(sealed, to: "\(item.uuid.uuidString)/Attachments/\(attachment.fileName)")
        }
    }

    /// Seals the file on disk (or, if it isn't here yet, its synced copy)
    /// and gives what's to sync now.
    private func sealFile(_ path: String, synced: Data?, key: SymmetricKey) throws -> Data? {
        let url = files.url(for: path)
        guard let plain = (try? Data(contentsOf: url)) ?? synced else { return nil }
        if SealedFormat.isSealed(plain) { return synced }
        let sealed = try VaultCrypto.seal(plain, with: key)
        try files.write(sealed, to: path)
        return sealed.count <= Self.largestSyncedFile ? sealed : nil
    }

    private func unsealFiles(of item: Item, key: SymmetricKey) throws {
        if let path = item.storedFilePath { item.fileData = try unsealFile(path, synced: item.fileData, key: key) }
        if let path = item.archivePath { item.archiveData = try unsealFile(path, synced: item.archiveData, key: key) }
        for attachment in item.attachments ?? [] {
            guard let data = attachment.data, SealedFormat.isSealed(data) else { continue }
            let plain = try VaultCrypto.open(data, with: key)
            attachment.data = plain
            try? files.write(plain, to: "\(item.uuid.uuidString)/Attachments/\(attachment.fileName)")
        }
    }

    private func unsealFile(_ path: String, synced: Data?, key: SymmetricKey) throws -> Data? {
        let url = files.url(for: path)
        guard let data = (try? Data(contentsOf: url)) ?? synced else { return nil }
        guard SealedFormat.isSealed(data) else { return synced }
        let plain = try VaultCrypto.open(data, with: key)
        try files.write(plain, to: path)
        return plain.count <= Self.largestSyncedFile ? plain : nil
    }

    // MARK: - Reading while unlocked

    /// Where decrypted copies are put while their items are unlocked;
    /// emptied when they lock again.
    static var unsealedFolder: URL { URL.temporaryDirectory.appendingPathComponent("StashUnsealed", isDirectory: true) }

    /// A decrypted copy of one of an unlocked sealed item's files; nil
    /// while it's locked.
    func unsealedCopy(of path: String, synced: Data?, for item: Item) -> URL? {
        guard unlocked.contains(item.uuid), let id = item.sealedVaultID, let key = vaultKeys[id] else { return nil }
        let destination = Self.unsealedFolder.appendingPathComponent(item.uuid.uuidString, isDirectory: true)
            .appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        guard let data = (try? Data(contentsOf: files.url(for: path))) ?? synced,
              let plain = try? VaultCrypto.open(data, with: key) else { return nil }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            try plain.write(to: destination, options: [.atomic, .completeFileProtection])
            #else
            try plain.write(to: destination, options: .atomic)
            #endif
        } catch {
            return nil
        }
        return destination
    }

    /// Deletes every decrypted copy.
    func removeUnsealedCopies() {
        try? FileManager.default.removeItem(at: Self.unsealedFolder)
    }
}
