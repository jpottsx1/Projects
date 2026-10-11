import Foundation

/// Reading and writing ZIP archives -- EPUB books are ZIP files, and
/// backups are written as one. Only what those need: reading stored and
/// deflated entries, and writing stored (uncompressed) ones. ZIP64 is
/// understood both ways, so archives over 4 GB work.
///
/// Inflating is passed in, since the system's decompressor lives in an
/// Apple-only framework and this package has none.
public enum Zip {
    public enum Failure: Error, Equatable {
        case notAZip
        case damaged(String)
        case missing(String)
        case unsupportedMethod(Int)
    }

    /// Turns raw DEFLATE data into `size` bytes.
    public typealias Inflate = (_ compressed: Data, _ size: Int) throws -> Data

    // MARK: - CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    /// Continues a CRC-32 over more bytes; start from 0.
    public static func crc32(_ data: Data, continuing crc: UInt32 = 0) -> UInt32 {
        var value = ~crc
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
            }
        }
        return ~value
    }
}

// MARK: - Reading

public struct ZipReader {
    public struct Entry {
        public let path: String
        let method: Int
        let compressedSize: Int
        public let size: Int
        let localHeaderOffset: Int
        let crc: UInt32

        public var isDirectory: Bool { path.hasSuffix("/") }
    }

    private let data: Data
    public let entries: [Entry]
    private let byPath: [String: Int]

    /// `data` can be memory-mapped: only the parts asked for are read.
    public init(data: Data) throws {
        self.data = data
        let bytes = Bytes(data)
        guard let end = Self.endOfCentralDirectory(in: bytes) else { throw Zip.Failure.notAZip }

        var count = Int(try bytes.u16(end + 10))
        var directorySize = Int(try bytes.u32(end + 12))
        var directoryOffset = Int(try bytes.u32(end + 16))
        // ZIP64: the real numbers are in another record, found through a
        // locator just before this one.
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF,
           end >= 20, try bytes.u32(end - 20) == 0x0706_4b50 {
            let record = Int(try bytes.u64(end - 20 + 8))
            guard try bytes.u32(record) == 0x0606_4b50 else { throw Zip.Failure.damaged("ZIP64 record") }
            count = Int(try bytes.u64(record + 32))
            directorySize = Int(try bytes.u64(record + 40))
            directoryOffset = Int(try bytes.u64(record + 48))
        }
        _ = directorySize

        var entries: [Entry] = []
        var offset = directoryOffset
        for _ in 0..<count {
            guard try bytes.u32(offset) == 0x0201_4b50 else { throw Zip.Failure.damaged("central directory") }
            let method = Int(try bytes.u16(offset + 10))
            let crc = try bytes.u32(offset + 16)
            var compressedSize = Int(try bytes.u32(offset + 20))
            var size = Int(try bytes.u32(offset + 24))
            let nameLength = Int(try bytes.u16(offset + 28))
            let extraLength = Int(try bytes.u16(offset + 30))
            let commentLength = Int(try bytes.u16(offset + 32))
            var localOffset = Int(try bytes.u32(offset + 42))
            let name = try bytes.slice(offset + 46, nameLength)
            let path = String(decoding: name, as: UTF8.self)

            // ZIP64 extra field: whichever sizes didn't fit, in this order.
            var extra = offset + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = try bytes.u16(extra)
                let length = Int(try bytes.u16(extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    if size == 0xFFFF_FFFF { size = Int(try bytes.u64(field)); field += 8 }
                    if compressedSize == 0xFFFF_FFFF { compressedSize = Int(try bytes.u64(field)); field += 8 }
                    if localOffset == 0xFFFF_FFFF { localOffset = Int(try bytes.u64(field)) }
                }
                extra += 4 + length
            }

            entries.append(Entry(path: path, method: method, compressedSize: compressedSize, size: size,
                                 localHeaderOffset: localOffset, crc: crc))
            offset = extraEnd + commentLength
        }
        self.entries = entries
        var byPath: [String: Int] = [:]
        for (index, entry) in entries.enumerated() where byPath[entry.path] == nil {
            byPath[entry.path] = index
        }
        self.byPath = byPath
    }

    public func entry(_ path: String) -> Entry? {
        byPath[path].map { entries[$0] }
    }

    public func contains(_ path: String) -> Bool { byPath[path] != nil }

    /// An entry's contents. A stored entry is a slice of the archive, so
    /// nothing is copied.
    public func data(for path: String, inflate: Zip.Inflate) throws -> Data {
        guard let entry = entry(path) else { throw Zip.Failure.missing(path) }
        return try data(for: entry, inflate: inflate)
    }

    public func data(for entry: Entry, inflate: Zip.Inflate) throws -> Data {
        let bytes = Bytes(data)
        let header = entry.localHeaderOffset
        guard try bytes.u32(header) == 0x0403_4b50 else { throw Zip.Failure.damaged(entry.path) }
        let start = header + 30 + Int(try bytes.u16(header + 26)) + Int(try bytes.u16(header + 28))
        let stored = try bytes.slice(start, entry.compressedSize)
        let contents: Data
        switch entry.method {
        case 0: contents = stored
        case 8: contents = try inflate(stored, entry.size)
        default: throw Zip.Failure.unsupportedMethod(entry.method)
        }
        guard contents.count == entry.size else { throw Zip.Failure.damaged(entry.path) }
        return contents
    }

    /// The end record is the last thing in the file, followed only by a
    /// comment of up to 64 KB.
    private static func endOfCentralDirectory(in bytes: Bytes) -> Int? {
        let count = bytes.count
        guard count >= 22 else { return nil }
        var offset = count - 22
        let lowest = max(0, count - 22 - 0xFFFF)
        while offset >= lowest {
            if (try? bytes.u32(offset)) == 0x0605_4b50 { return offset }
            offset -= 1
        }
        return nil
    }
}

/// Little-endian reading at offsets from the start of some Data, which may
/// be a slice that doesn't start at 0.
private struct Bytes {
    let data: Data
    init(_ data: Data) { self.data = data }

    var count: Int { data.count }

    func slice(_ offset: Int, _ length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset + length <= data.count else { throw Zip.Failure.damaged("short") }
        let start = data.startIndex + offset
        return data[start..<start + length]
    }

    private func uint(_ offset: Int, _ size: Int) throws -> UInt64 {
        let bytes = try slice(offset, size)
        var value: UInt64 = 0
        for (shift, byte) in bytes.enumerated() { value |= UInt64(byte) << (8 * UInt64(shift)) }
        return value
    }

    func u16(_ offset: Int) throws -> UInt16 { UInt16(try uint(offset, 2)) }
    func u32(_ offset: Int) throws -> UInt32 { UInt32(try uint(offset, 4)) }
    func u64(_ offset: Int) throws -> UInt64 { try uint(offset, 8) }
}

// MARK: - Writing

/// Writes a ZIP file entry by entry, straight to disk, so a backup of a
/// large library never has to fit in memory. Entries are stored rather
/// than compressed: most of what's backed up (PDFs, pictures, web
/// archives) is compressed already.
public final class ZipWriter {
    private struct Written {
        var path: Data
        var crc: UInt32
        var size: UInt64
        var offset: UInt64
        var dosTime: UInt16
        var dosDate: UInt16
    }

    private let handle: FileHandle
    private var written: [Written] = []
    private var offset: UInt64 = 0
    private var finished = false

    /// Creates (or replaces) the file at `url`.
    public init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle.close()
    }

    public func add(_ path: String, data: Data, modified: Date = Date()) throws {
        try writeEntry(path, crc: Zip.crc32(data), size: UInt64(data.count), modified: modified) {
            try handle.write(contentsOf: data)
        }
    }

    /// Copies a file in, a piece at a time.
    public func add(_ path: String, contentsOf file: URL, modified: Date = Date()) throws {
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        // The header needs the checksum first, so the file is read twice.
        var crc: UInt32 = 0
        var size: UInt64 = 0
        while let chunk = try reader.read(upToCount: 1 << 22), !chunk.isEmpty {
            crc = Zip.crc32(chunk, continuing: crc)
            size += UInt64(chunk.count)
        }
        try reader.seek(toOffset: 0)
        try writeEntry(path, crc: crc, size: size, modified: modified) {
            var left = size
            while left > 0, let chunk = try reader.read(upToCount: 1 << 22), !chunk.isEmpty {
                let piece = chunk.prefix(Int(min(UInt64(chunk.count), left)))
                try handle.write(contentsOf: piece)
                left -= UInt64(piece.count)
            }
        }
    }

    private func writeEntry(_ path: String, crc: UInt32, size: UInt64, modified: Date,
                            body: () throws -> Void) throws {
        precondition(!finished, "ZipWriter already finished")
        let name = Data(path.utf8)
        let (time, date) = Self.dosDateTime(modified)
        let large = size >= 0xFFFF_FFFF
        var header = Data()
        header.le(UInt32(0x0403_4b50))
        header.le(UInt16(large ? 45 : 20))       // version needed
        header.le(UInt16(0x0800))                // names are UTF-8
        header.le(UInt16(0))                     // stored
        header.le(time)
        header.le(date)
        header.le(crc)
        header.le(UInt32(large ? 0xFFFF_FFFF : size))
        header.le(UInt32(large ? 0xFFFF_FFFF : size))
        header.le(UInt16(name.count))
        header.le(UInt16(large ? 20 : 0))
        header.append(name)
        if large {
            header.le(UInt16(0x0001))
            header.le(UInt16(16))
            header.le(size)
            header.le(size)
        }
        try handle.write(contentsOf: header)
        try body()
        written.append(Written(path: name, crc: crc, size: size, offset: offset,
                               dosTime: time, dosDate: date))
        offset += UInt64(header.count) + size
    }

    /// Writes the directory at the end. Nothing can be added afterwards.
    public func finish() throws {
        guard !finished else { return }
        finished = true
        let directoryStart = offset
        var directory = Data()
        for entry in written {
            var extra = Data()
            if entry.size >= 0xFFFF_FFFF {
                extra.le(entry.size)
                extra.le(entry.size)
            }
            if entry.offset >= 0xFFFF_FFFF { extra.le(entry.offset) }
            var zip64 = Data()
            if !extra.isEmpty {
                zip64.le(UInt16(0x0001))
                zip64.le(UInt16(extra.count))
                zip64.append(extra)
            }
            let sizeField = entry.size >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(entry.size)
            directory.le(UInt32(0x0201_4b50))
            directory.le(UInt16(zip64.isEmpty ? 20 : 45)) // made by
            directory.le(UInt16(zip64.isEmpty ? 20 : 45)) // needed
            directory.le(UInt16(0x0800))
            directory.le(UInt16(0))
            directory.le(entry.dosTime)
            directory.le(entry.dosDate)
            directory.le(entry.crc)
            directory.le(sizeField)
            directory.le(sizeField)
            directory.le(UInt16(entry.path.count))
            directory.le(UInt16(zip64.count))
            directory.le(UInt16(0))                       // comment
            directory.le(UInt16(0))                       // disk
            directory.le(UInt16(0))                       // internal attributes
            directory.le(UInt32(0))                       // external attributes
            directory.le(entry.offset >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(entry.offset))
            directory.append(entry.path)
            directory.append(zip64)
        }
        try handle.write(contentsOf: directory)
        let directorySize = UInt64(directory.count)
        let directoryEnd = directoryStart + directorySize

        var end = Data()
        let needsZip64 = written.count >= 0xFFFF || directoryStart >= 0xFFFF_FFFF || directorySize >= 0xFFFF_FFFF
        if needsZip64 {
            end.le(UInt32(0x0606_4b50))
            end.le(UInt64(44))
            end.le(UInt16(45))
            end.le(UInt16(45))
            end.le(UInt32(0))
            end.le(UInt32(0))
            end.le(UInt64(written.count))
            end.le(UInt64(written.count))
            end.le(directorySize)
            end.le(directoryStart)
            end.le(UInt32(0x0706_4b50))
            end.le(UInt32(0))
            end.le(directoryEnd)
            end.le(UInt32(1))
        }
        end.le(UInt32(0x0605_4b50))
        end.le(UInt16(0))
        end.le(UInt16(0))
        end.le(needsZip64 ? 0xFFFF : UInt16(written.count))
        end.le(needsZip64 ? 0xFFFF : UInt16(written.count))
        end.le(needsZip64 ? 0xFFFF_FFFF : UInt32(directorySize))
        end.le(needsZip64 ? 0xFFFF_FFFF : UInt32(directoryStart))
        end.le(UInt16(0))
        try handle.write(contentsOf: end)
        try handle.close()
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(0, (parts.year ?? 1980) - 1980)
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16(year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
