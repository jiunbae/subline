import Foundation

/// Native Messaging framing: 4-byte little-endian length + UTF-8 JSON payload.
public enum Framing {
    public static let defaultMaxFrame = 4 * 1024 * 1024

    public static func encode(_ payload: Data) -> Data {
        var len = UInt32(payload.count).littleEndian
        var out = Data(bytes: &len, count: 4)
        out.append(payload)
        return out
    }

    public enum DecodeError: Error, Equatable {
        case frameTooLarge(Int)
    }

    /// Incremental decoder; feed arbitrary chunks, pull complete frames.
    public struct Decoder {
        private var buffer = Data()
        private var readOffset = 0
        public let maxFrame: Int

        public init(maxFrame: Int = Framing.defaultMaxFrame) {
            self.maxFrame = maxFrame
        }

        public mutating func append(_ chunk: Data) {
            buffer.append(chunk)
        }

        public mutating func next() throws -> Data? {
            let available = buffer.count - readOffset
            guard available >= 4 else { compact(); return nil }
            let start = buffer.startIndex + readOffset
            let b = buffer[start..<start + 4]
            let len = b.enumerated().reduce(0) { acc, item in acc | (Int(item.element) << (8 * item.offset)) }
            guard len <= maxFrame else { throw DecodeError.frameTooLarge(len) }
            guard available >= 4 + len else { compact(); return nil }
            let payload = buffer.subdata(in: (start + 4)..<(start + 4 + len))
            readOffset += 4 + len
            return payload
        }

        private mutating func compact() {
            if readOffset > 0 {
                buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + readOffset)
                readOffset = 0
            }
        }
    }
}
