import Foundation
import NIOConcurrencyHelpers

public protocol WebsocketFrameSequence: Sendable {
    var binaryBuffer: Data { get }
    var textBuffer: Data { get }
    var type: WebsocketOpcode { get }

    init(type: WebsocketOpcode)

    mutating func append(_ frame: Data)
}

public struct WebsocketSimpleAppendFrameSequence: WebsocketFrameSequence {
    private(set) public var binaryBuffer: Data
    private(set) public var textBuffer: Data
    public let type: WebsocketOpcode

    public init(type: WebsocketOpcode) {
        self.binaryBuffer = Data()
        self.textBuffer = Data()
        self.type = type
    }

    public mutating func append(_ frame: Data) {
        switch type {
        case .binary:
            self.binaryBuffer.append(frame)
        case .text:
            self.textBuffer.append(frame)
        default:
            break
        }
    }
}
