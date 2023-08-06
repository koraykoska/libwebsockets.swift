import Foundation
import NIOCore

public protocol WebsocketConnection {
    /// Returns true if the connections is currently closed. Doesn't guarantee that it won't be opened up or reconnected later.
    var isClosed: Bool { get }
    /// Returns true if the connection is closed forever. It won't be opened up reconnected later.
    var isClosedForever: Bool { get }

    /// Send the given data using the given opcode over the Websocket connection.
    /// Note: You can use `fin = false` and `.continuation` opcode to
    /// split up your message into multiple frames.
    ///
    /// - parameter data: The data to send.
    /// - parameter opcode: The opcode to use.
    /// - parameter fin: Whether this frame is the last of the message.
    /// - parameter promise: A promise that resolves once the message has been sent.
    func send(
        _ data: Data,
        opcode: WebsocketOpcode,
        fin: Bool,
        promise: EventLoopPromise<Void>?
    )
    /// Close the Websocket connection for good with the given status code.
    ///
    /// - parameter reason: The reason code for the close message.
    func close(reason: WebsocketCloseStatus)

    /// An interval to automatically send pings and expect pongs until the next interval comes.
    /// The connection will be closed automatically if no pong is received.
    var pingInterval: TimeAmount? { get set }

    /// The callback that will be called for new text messages (whole message, not fragments)
    func onText(_ callback: @Sendable @escaping (WebsocketClient, String) -> ())
    /// The callback that will be called for new binary messages (whole message, not fragments)
    func onBinary(_ callback: @Sendable @escaping (WebsocketClient, Data) -> ())
    /// The callback that will be called for new frames aka fragments
    func onFragment(
        _ callback: @Sendable @escaping (
            _ ws: WebsocketClient, _ data: Data, _ isText: Bool, _ isFirst: Bool, _ isFinal: Bool
        ) -> ()
    )
    /// The callback that will be called on pong
    func onPong(_ callback: @Sendable @escaping (WebsocketClient, Data) -> ())
    /// The callback that will be called on close
    func onClose(_ callback: @Sendable @escaping (WebsocketCloseStatus) -> ())
}
