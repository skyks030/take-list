import Compression
import Foundation

public enum ZipError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let m): return "Ungültige Datei: \(m)" }
    }
}

/// Minimal ZIP reader (stored + deflate), sufficient for .xlsx packages.
public struct ZipArchive {
    public private(set) var names: [String] = []
    public private(set) var entries: [String: Data] = [:]

    public init() {}

    public init(data: Data) throws {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count >= 22 else { throw ZipError.invalid("zu kurz") }
        var eocd = -1
        var i = b.count - 22
        let lower = max(0, b.count - 22 - 65_535)
        while i >= lower {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.invalid("kein ZIP-Verzeichnis (ist es eine .xlsx-Datei?)") }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x0201_4B50 else { throw ZipError.invalid("Verzeichniseintrag") }
            let method = u16(p + 10)
            let compSize = u32(p + 20)
            let size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let local = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen
            guard local + 30 <= b.count, u32(local) == 0x0403_4B50 else { throw ZipError.invalid("lokaler Header") }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compSize <= b.count else { throw ZipError.invalid("abgeschnitten") }
            let raw = Data(b[start..<(start + compSize)])
            let content: Data
            switch method {
            case 0: content = raw
            case 8: content = try Self.inflate(raw, size: size)
            default: throw ZipError.invalid("Kompression \(method) nicht unterstützt")
            }
            if entries[name] == nil { names.append(name) }
            entries[name] = content
        }
    }

    public subscript(name: String) -> Data? {
        get { entries[name] }
        set {
            if let newValue {
                if entries[name] == nil { names.append(name) }
                entries[name] = newValue
            } else {
                entries[name] = nil
                names.removeAll { $0 == name }
            }
        }
    }

    static func inflate(_ data: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard n == size else { throw ZipError.invalid("Entpacken fehlgeschlagen") }
        return out
    }

    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let cap = data.count + 1024
        var out = Data(count: cap)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0, n < data.count else { return nil }
        return out.prefix(n)
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buf in
            for byte in buf { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }

    /// Serialises all entries (in their original order) into a ZIP file.
    public func serialized() -> Data {
        var out = Data()
        var central = Data()
        func le16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func le32(_ v: UInt32, _ d: inout Data) { le16(Int(v & 0xFFFF), &d); le16(Int(v >> 16), &d) }
        let dosTime = 0, dosDate = (2026 - 1980) << 9 | 1 << 5 | 1
        for name in names {
            guard let content = entries[name] else { continue }
            let crc = Self.crc32(content)
            let packed = Self.deflate(content)
            let method = packed == nil ? 0 : 8
            let body = packed ?? content
            let nameData = Data(name.utf8)
            let offset = UInt32(out.count)
            // local header
            le32(0x0403_4B50, &out); le16(20, &out); le16(0x0800, &out); le16(method, &out)
            le16(dosTime, &out); le16(dosDate, &out); le32(crc, &out)
            le32(UInt32(body.count), &out); le32(UInt32(content.count), &out)
            le16(nameData.count, &out); le16(0, &out); out.append(nameData); out.append(body)
            // central directory
            le32(0x0201_4B50, &central); le16(20, &central); le16(20, &central); le16(0x0800, &central)
            le16(method, &central); le16(dosTime, &central); le16(dosDate, &central); le32(crc, &central)
            le32(UInt32(body.count), &central); le32(UInt32(content.count), &central)
            le16(nameData.count, &central); le16(0, &central); le16(0, &central); le16(0, &central)
            le16(0, &central); le32(0, &central); le32(offset, &central); central.append(nameData)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        le32(0x0605_4B50, &out); le16(0, &out); le16(0, &out)
        le16(names.count, &out); le16(names.count, &out)
        le32(UInt32(central.count), &out); le32(cdOffset, &out); le16(0, &out)
        return out
    }
}
