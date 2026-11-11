
import Foundation

/// Unpacks gzip-compressed STEP (`.stpz`, or `.step.gz`): the bytes are recognised by the gzip
/// magic number, never by the file name, so every entry point accepts both forms.
///
/// Only the deflate stream is used: the header is parsed to find where it starts, the trailer's CRC is
/// not verified. The size the trailer declares is checked before inflating, and again after.
enum STEPGzip {
    /// Refuses output above this many bytes (a STEP file this large would not parse anyway).
    static let maximumInflatedBytes = 1 << 30

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// `data` itself when it is not gzip.
    static func inflateIfGzip(_ data: Data) throws -> Data {
        guard isGzip(data) else {
            return data
        }
        #if canImport(Darwin)
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[2] == 8 else {
            throw STEP.ParseError("Unsupported or truncated gzip data", kind: .malformed)
        }
        let flags = bytes[3]
        var position = 10
        func skipTerminated() throws {
            while position < bytes.count, bytes[position] != 0 {
                position += 1
            }
            guard position < bytes.count else {
                throw STEP.ParseError("Truncated gzip header", kind: .truncated)
            }
            position += 1
        }
        if flags & 0x04 != 0 {                      // FEXTRA
            guard position + 2 <= bytes.count else {
                throw STEP.ParseError("Truncated gzip header", kind: .truncated)
            }
            position += 2 + Int(bytes[position]) + Int(bytes[position + 1]) << 8
        }
        if flags & 0x08 != 0 {
            try skipTerminated()
        } // FNAME
        if flags & 0x10 != 0 {
            try skipTerminated()
        } // FCOMMENT
        if flags & 0x02 != 0 {
            position += 2
        }        // FHCRC
        let trailer = bytes.count - 8
        guard position < trailer else {
            throw STEP.ParseError("Truncated gzip data", kind: .truncated)
        }

        // ISIZE: the uncompressed length modulo 2^32, little endian.
        let declared = (0..<4).reduce(0) { $0 | Int(bytes[trailer + 4 + $1]) << (8 * $1) }
        guard declared <= maximumInflatedBytes else {
            throw STEP.ParseError("Compressed STEP data inflates to more than \(maximumInflatedBytes) bytes", kind: .limitExceeded)
        }
        let deflated = Data(bytes[position..<trailer])
        let inflated: Data
        do {
            inflated = try (deflated as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw STEP.ParseError("Cannot inflate gzip data: \(error.localizedDescription)", kind: .malformed)
        }
        guard inflated.count <= maximumInflatedBytes, inflated.count & 0xFFFF_FFFF == declared else {
            throw STEP.ParseError("Inflated size does not match the gzip trailer", kind: .malformed)
        }
        return inflated
        #else
        throw STEP.ParseError("Compressed STEP files need the Compression framework, which this platform lacks",
                              kind: .malformed)
        #endif
    }
}
