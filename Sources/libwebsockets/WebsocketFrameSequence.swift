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
        return _binaryBuffer
    }
    public var textBuffer: Data {
        return _textBuffer
    }
    public var count: Int {
        return _count
    }
    private var _count: Int
    private var _binaryBuffer: Data
    private var _textBuffer: Data
    public let type: WebsocketOpcode

    private let bufferSize = 100000
    private var bufferCurrentSize: Int

    public init(type: WebsocketOpcode) {
        self._binaryBuffer = Data(capacity: bufferSize)
        self._textBuffer = Data(capacity: bufferSize)
        self.bufferCurrentSize = bufferSize
        self._count = 0
        self.type = type
    }

    public mutating func append(_ frame: Data) {
        switch type {
        case .binary:
            if _count + frame.count > bufferCurrentSize {
                let nextBufferSize = max(bufferCurrentSize + bufferSize, bufferCurrentSize + frame.count)
                _binaryBuffer.reserveCapacity(nextBufferSize)
                self.bufferCurrentSize = nextBufferSize
            }

            self._binaryBuffer.append(frame)
            _count += frame.count
        case .text:
            if _count + frame.count > bufferCurrentSize {
                let nextBufferSize = max(bufferCurrentSize + bufferSize, bufferCurrentSize + frame.count)
                _textBuffer.reserveCapacity(nextBufferSize)
                self.bufferCurrentSize = nextBufferSize
            }

            self._textBuffer.append(frame)
            _count += frame.count
        default:
            break
        }
    }
}
