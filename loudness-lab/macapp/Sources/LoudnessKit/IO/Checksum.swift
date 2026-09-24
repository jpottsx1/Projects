import Foundation

/// FNV-1a, 64-bit.
///
/// Not for security -- for saying "these bytes are the bytes the Python
/// produced" in one number, in a way both languages implement identically in
/// six lines. A gain pass rewrites a few hundred bytes scattered through a
/// file; comparing whole files through the golden vectors would mean
/// shipping them twice.
public enum Checksum {
    public static func fnv1a(_ data: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
