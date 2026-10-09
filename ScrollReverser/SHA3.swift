import CryptoKit
import Foundation

/// SHA3-256 file hashing. Uses CryptoKit where available (macOS 26+) and a built-in
/// Keccak implementation on older systems.
enum SHA3 {
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let digest: [UInt8]
        if #available(macOS 26, *) {
            var hasher = CryptoKit.SHA3_256()
            try forEachChunk(of: url) { hasher.update(data: $0) }
            digest = Array(hasher.finalize())
        } else {
            var hasher = KeccakSHA3_256()
            try forEachChunk(of: url) { hasher.update($0) }
            digest = hasher.finalize()
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func forEachChunk(of url: URL, _ body: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            body(chunk)
        }
    }
}

/// FIPS 202 SHA3-256: Keccak-f[1600] sponge with a 136-byte rate.
struct KeccakSHA3_256 {
    private static let rate = 136

    private static let roundConstants: [UInt64] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808B, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008A, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
        0x0000_0000_8000_808B, 0x8000_0000_0000_008B, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800A, 0x8000_0000_8000_000A,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
    ]
    private static let rotations: [UInt64] = [
        1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44,
    ]
    private static let piLanes = [
        10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1,
    ]

    private var state = [UInt64](repeating: 0, count: 25)
    private var pending = [UInt8]()

    mutating func update(_ data: Data) {
        pending.append(contentsOf: data)
        var offset = 0
        while pending.count - offset >= Self.rate {
            absorb(pending[offset ..< offset + Self.rate])
            offset += Self.rate
        }
        pending.removeFirst(offset)
    }

    mutating func finalize() -> [UInt8] {
        var block = pending
        block.append(0x06)
        block += [UInt8](repeating: 0, count: Self.rate - block.count)
        block[Self.rate - 1] |= 0x80
        absorb(block[...])

        return (0 ..< 32).map { UInt8(truncatingIfNeeded: state[$0 / 8] >> (8 * UInt64($0 % 8))) }
    }

    private mutating func absorb(_ block: ArraySlice<UInt8>) {
        for lane in 0 ..< Self.rate / 8 {
            let start = block.startIndex + lane * 8
            var value: UInt64 = 0
            for byte in 0 ..< 8 {
                value |= UInt64(block[start + byte]) << (8 * UInt64(byte))
            }
            state[lane] ^= value
        }
        permute()
    }

    private mutating func permute() {
        var columns = [UInt64](repeating: 0, count: 5)
        for round in 0 ..< 24 {
            // θ
            for x in 0 ..< 5 {
                columns[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }
            for x in 0 ..< 5 {
                let d = columns[(x + 4) % 5] ^ rotate(columns[(x + 1) % 5], by: 1)
                for y in stride(from: 0, to: 25, by: 5) {
                    state[y + x] ^= d
                }
            }
            // ρ and π
            var carry = state[1]
            for i in 0 ..< 24 {
                let lane = Self.piLanes[i]
                let next = state[lane]
                state[lane] = rotate(carry, by: Self.rotations[i])
                carry = next
            }
            // χ
            for y in stride(from: 0, to: 25, by: 5) {
                for x in 0 ..< 5 { columns[x] = state[y + x] }
                for x in 0 ..< 5 {
                    state[y + x] ^= ~columns[(x + 1) % 5] & columns[(x + 2) % 5]
                }
            }
            // ι
            state[0] ^= Self.roundConstants[round]
        }
    }

    private func rotate(_ value: UInt64, by amount: UInt64) -> UInt64 {
        (value << amount) | (value >> (64 - amount))
    }
}
