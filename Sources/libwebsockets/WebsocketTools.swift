import Foundation

internal extension ContiguousArray where Element == CChar {
    func toCPointer() -> UnsafePointer<CChar>! {
        return self.withUnsafeBufferPointer({ $0.baseAddress })
    }
}

internal extension Bool {
    func toCBool() -> Int32 {
        return self ? 1 : 0
    }
}

internal extension FixedWidthInteger {
    func fromCBool() -> Bool {
        return self != 0
    }
}

internal extension Data {
    func chunked(into size: Int) -> [Data] {
        return stride(from: 0, to: count, by: size).map {
            Data(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

internal extension Dictionary where Key == String {
    subscript(caseInsensitive key: Key) -> Value? {
        get {
            if let k = keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                return self[k]
            }
            return nil
        }
        set {
            if let k = keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                self[k] = newValue
            } else {
                self[key] = newValue
            }
        }
    }
}
