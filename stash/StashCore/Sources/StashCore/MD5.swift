import Foundation

/// MD5, which Evernote names each attachment by, written out here because
/// this package can't use CryptoKit. For matching files, never for security.
public enum MD5 {
    public static func hex(_ data: Data) -> String {
        digest(data).map { String(format: "%02x", $0) }.joined()
    }

    private static let shifts: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                           5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                           4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                           6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
    private static let constants: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4_294_967_296)) }

    public static func digest(_ data: Data) -> [UInt8] {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for byte in 0..<8 { message.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(byte)))) }

        var a0: UInt32 = 0x67452301, b0: UInt32 = 0xefcdab89, c0: UInt32 = 0x98badcfe, d0: UInt32 = 0x10325476
        var words = [UInt32](repeating: 0, count: 16)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let at = chunk + i * 4
                words[i] = UInt32(message[at]) | UInt32(message[at + 1]) << 8 | UInt32(message[at + 2]) << 16 | UInt32(message[at + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                let g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ constants[i] &+ words[g]
                a = d
                d = c
                c = b
                b = b &+ (f << shifts[i] | f >> (32 - shifts[i]))
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
        }
        return [a0, b0, c0, d0].flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * UInt32($0))) } }
    }
}
