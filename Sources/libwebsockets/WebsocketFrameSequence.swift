import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOFoundationCompat

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
        return _binaryBuffer.getData(at: 0, length: _binaryBuffer.readableBytes, byteTransferStrategy: .copy) ?? Data()
    }
    public var textBuffer: Data {
        return _textBuffer.getData(at: 0, length: _textBuffer.readableBytes, byteTransferStrategy: .copy) ?? Data()
    }
    public var count: Int {
        return _count
    }
    private var _count: Int
    private var _binaryBuffer: ByteBuffer
    private var _textBuffer: ByteBuffer
    public let type: WebsocketOpcode

    private let byteBufferAllocator = ByteBufferAllocator()
    private let bufferSize = 100000
    private var bufferCurrentSize: Int

    public init(type: WebsocketOpcode) {
        self._binaryBuffer = byteBufferAllocator.buffer(capacity: bufferSize)
        self._textBuffer = byteBufferAllocator.buffer(capacity: bufferSize)
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

            self._binaryBuffer.writeBytes(frame)
            _count += frame.count
        case .text:
            if _count + frame.count > bufferCurrentSize {
                let nextBufferSize = max(bufferCurrentSize + bufferSize, bufferCurrentSize + frame.count)
                _textBuffer.reserveCapacity(nextBufferSize)
                self.bufferCurrentSize = nextBufferSize
            }

            self._textBuffer.writeBytes(frame)
            _count += frame.count
        default:
            break
        }
    }
}
