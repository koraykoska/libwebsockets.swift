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
