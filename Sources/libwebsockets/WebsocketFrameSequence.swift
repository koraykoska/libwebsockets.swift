import Foundation
import NIOConcurrencyHelpers

public protocol WebsocketFrameSequence: Sendable {
    var binaryBuffer: Data { get }
    var textBuffer: Data { get }
    var type: WebsocketOpcode { get }
    var count: Int { get }

    init(type: WebsocketOpcode)

    mutating func append(_ frame: Data)
}

public struct WebsocketSimpleAppendFrameSequence: WebsocketFrameSequence {
    public var binaryBuffer: Data {
        return _binaryBuffer[0..<_count]
    }
    public var textBuffer: Data {
        return _textBuffer[0..<_count]
    }
    public var count: Int {
        return _count
    }
    private var _count: Int
    private var _binaryBuffer: Data
    private var _textBuffer: Data
    public let type: WebsocketOpcode

    private let bufferSize = 1000000

    public init(type: WebsocketOpcode) {
        self._binaryBuffer = Data()
        self._textBuffer = Data()
        self._count = 0
        self.type = type
    }

    public mutating func append(_ frame: Data) {
        switch type {
        case .binary:
            if _binaryBuffer.count < _count + frame.count {
                _binaryBuffer.append(Data(count: max(bufferSize, frame.count)))
            }

            _count += frame.count
            self._binaryBuffer.insert(contentsOf: frame, at: _count)
        case .text:
            if _textBuffer.count < _count + frame.count {
                _textBuffer.append(Data(count: max(bufferSize, frame.count)))
            }

            _count += frame.count
            self._textBuffer.insert(contentsOf: frame, at: _count)
        default:
            break
        }
    }
}
