import Clibwebsockets
import Dispatch
import NIOCore
import NIOConcurrencyHelpers
import Foundation

public class WebsocketClient {
    public enum Error: Swift.Error {
        case contextCreationFailed
        case connectionError
        case websocketWriteFailed
        case websocketClosed
        case websocketNotYetOpen
    }

    // MARK: - Properties

    // Queue for running websocket event polling
    private let serviceQueue = DispatchQueue(label: "websocket-service")

    // See: https://stackoverflow.com/questions/61236195/create-a-weak-unsafemutablerawpointer?rq=3
    fileprivate class WeakSelf {
        fileprivate weak var weakSelf: WebsocketClient?

        fileprivate init(weakSelf: WebsocketClient) {
            self.weakSelf = weakSelf
        }
    }
    private let selfPointer: UnsafeMutablePointer<WeakSelf> = UnsafeMutablePointer<WeakSelf>.allocate(capacity: 1)
    private let protocolsPointer: UnsafeMutablePointer<lws_protocols> = UnsafeMutablePointer<lws_protocols>.allocate(capacity: 2)

    private var lwsContextCreationInfo: lws_context_creation_info!
    private var lwsProtocols: lws_protocols!
    private var lwsEmptyProtocol: lws_protocols!
    private var lwsCCInfo: lws_client_connect_info!
    private var context: OpaquePointer!
    private var websocket: OpaquePointer!

    /// Whether the websocket was ever connected to the server. True once it connected, even if eventually disconnected.
    fileprivate let wasConnected: NIOLockedValueBox<Bool> = .init(false)

    /// True if the connection errored. Will never connect again. lwsClose Status might not be set.
    fileprivate let connectionError: NIOLockedValueBox<Bool> = .init(false)

    /// nil until a close event is received. Do not rely soely on it as connection errors lead to a never initialized close status.
    /// Instead, check `wasConnected` first to make sure a connection has been established before checking this value.
    fileprivate let lwsCloseStatus: NIOLockedValueBox<lws_close_status?> = .init(nil)

    /// Internally managed buffer of frames. Emitted once the full message is there.
    fileprivate let frameSequence: NIOLockedValueBox<WebsocketFrameSequence?> = .init(nil)

    // State variables

    /// Returns true if the underlying websocket connection is closed.
    /// Either because it isn't open yet or because the connection was closed.
    public var isClosed: Bool {
        if websocket == nil {
            return true
        }

        if !wasConnected.withLockedValue({ $0 }) {
            return true
        }

        if connectionError.withLockedValue({ $0 }) {
            return true
        }

        if lwsCloseStatus.withLockedValue({ $0 }) == nil {
            return false
        }

        return true
    }

    public var isClosedForever: Bool {
        if connectionError.withLockedValue({ $0 }) {
            return true
        }
        if lwsCloseStatus.withLockedValue({ $0 }) == nil {
            return false
        }

        return true
    }

    /// Lock for closing the connection from the client side or setting the reason from the server side
    fileprivate let closeLock = NIOLock()

    // Init properties
    public let scheme: WebsocketScheme
    public let host: String
    public let port: UInt16
    public let path: String
    public let query: String?
    public let headers: [String: String]
    public let origin: String
    public let maxFrameSize: Int

    // Needs to be emptied after usage to not create a retain cycle
    fileprivate var onConnect: EventLoopPromise<Void>?

    // Writable to the websocket
    fileprivate let toBeWritten: NIOLockedValueBox<Array<(
        data: Data,
        opcode: WebsocketOpcode,
        fin: Bool,
        promise: EventLoopPromise<Void>?
    )>> = .init([])

    // MARK: - Initialization

    public init(
        scheme: WebsocketScheme = .ws,
        host: String,
        port: UInt16 = 80,
        path: String = "/",
        query: String? = nil,
        headers: [String: String] = [:],
        origin: String = "localhost",
        maxFrameSize: Int,
        connectionTimeoutSeconds: UInt32 = 10,
        onConnect: EventLoopPromise<Void>
    ) throws {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
        self.query = query
        self.headers = headers
        self.origin = origin
        self.maxFrameSize = maxFrameSize
        self.onConnect = onConnect

//        lws_set_log_level(1151, nil)
        lws_set_log_level(0, nil)

        // Context Creation Info
        lwsContextCreationInfo = lws_context_creation_info()
        lws_context_creation_info_zero(&lwsContextCreationInfo)
        lwsContextCreationInfo.port = CONTEXT_PORT_NO_LISTEN
        switch scheme {
        case .wss:
            lwsContextCreationInfo.options = UInt64(LWS_SERVER_OPTION_DO_SSL_GLOBAL_INIT)
        case .ws:
            break
        }
        lwsContextCreationInfo.timeout_secs = connectionTimeoutSeconds

        // self pointer
        selfPointer.pointee = .init(weakSelf: self)

        // Protocols
        lwsProtocols = lws_protocols()
        lws_protocols_zero(&lwsProtocols)
        let lwsProtocolName = "libwebsockets-protocol".utf8CString
        lwsProtocols.name = lwsProtocolName.toCPointer()

        lwsProtocols.callback = websocketCallback
        lwsProtocols.per_session_data_size = 0
        lwsProtocols.rx_buffer_size = maxFrameSize

        protocolsPointer.pointee = lwsProtocols
        lwsEmptyProtocol = lws_protocols()
        lws_protocols_zero(&lwsEmptyProtocol)
        lwsEmptyProtocol.name = nil
        lwsEmptyProtocol.callback = nil
        lwsEmptyProtocol.per_session_data_size = 0
        lwsEmptyProtocol.rx_buffer_size = 0
        protocolsPointer.advanced(by: 1).pointee = lwsEmptyProtocol
        // END Protocols

        lwsContextCreationInfo.protocols = UnsafePointer(protocolsPointer)
        // Below sets guid and uid to -1. Swift doesn't detect signed int correctly. No idea why.
        ws_set_guiduid(&lwsContextCreationInfo)
        // We did the below before but it was not always correct due to different int sizes.
//        lwsContextCreationInfo.gid = 0xffffffff
//        lwsContextCreationInfo.uid = 0xffffffff

        // Set a pointer back to self for communication from thr callback to the instance.
        lwsContextCreationInfo.user = UnsafeMutableRawPointer(selfPointer)

        // END Context Creation Info

        // Context
        guard let context = lws_create_context(&lwsContextCreationInfo) else {
            throw Error.contextCreationFailed
        }
        self.context = context

        // Client Connect Info
        lwsCCInfo = lws_client_connect_info()
        lws_client_connect_info_zero(&lwsCCInfo)
        lwsCCInfo.context = context
        let lwsCCInfoHost = host.utf8CString
        lwsCCInfo.address = lwsCCInfoHost.toCPointer()
        lwsCCInfo.port = Int32(port)
        let lwsCCInfoPath = path.utf8CString
        lwsCCInfo.path = lwsCCInfoPath.toCPointer()
        // TODO: Use query and all other params?
//        lwsCCInfo.host = lws_canonical_hostname(context)
        let lwsCCInfoHostHeader = "\(host):\(port)".utf8CString
        lwsCCInfo.host = lwsCCInfoHostHeader.toCPointer()
        let lwsCCInfoOrigin = origin.utf8CString
        lwsCCInfo.origin = lwsCCInfoOrigin.toCPointer()
        lwsCCInfo.protocol = lwsProtocols.name
        switch scheme {
        case .wss:
            ws_set_ssl_connection(&lwsCCInfo)
        case .ws:
            break
        }

        // Connect
        websocket = lws_client_connect_via_info(&lwsCCInfo)

        // Polling of Events, including connection success
        scheduleServiceCall()

        // Make sure the below variables are retained until function end
        _ = lwsProtocolName.count
        _ = lwsCCInfoHost.count
        _ = lwsCCInfoHostHeader.count
        _ = lwsCCInfoPath.count
        _ = lwsCCInfoOrigin.count
    }

    deinit {
        print("DEINIT")
        self.close(reason: LWS_CLOSE_STATUS_GOINGAWAY)

        protocolsPointer.deinitialize(count: 2)
        protocolsPointer.deallocate()

        // Make sure to free this only after the websocket is destroyed
        // Otherwise we might receive a callback, try to use this pointer
        // And crash...
        selfPointer.deinitialize(count: 1)
        selfPointer.deallocate()
    }

    // MARK: - Helpers

    private func scheduleServiceCall() {
        if isClosedForever {
            return
        }

        serviceQueue.async { [weak self] in
            guard let self else {
                return
            }

            // This lws_service call blocks until the next event1
            // arrives. The 250ms is ignored since the newest version.
            lws_service(self.context, 250)
            self.scheduleServiceCall()
        }
    }

    private func handleIncomingMessage() {

    }

    // MARK: - Public API

    public func send(
        _ data: Data,
        opcode: WebsocketOpcode,
        fin: Bool = true,
        promise: EventLoopPromise<Void>? = nil
    ) {
        if isClosedForever {
            promise?.fail(Error.websocketClosed)
            return
        }
        if isClosed {
            promise?.fail(Error.websocketNotYetOpen)
            return
        }

        switch opcode {
        case .binary, .text, .continuation, .ping:
            toBeWritten.withLockedValue({
                $0.append((
                    data: data,
                    opcode: opcode,
                    fin: fin,
                    promise: promise
                ))
            })

            // Make sure to ask for the write callback to execute
            lws_callback_on_writable(websocket)
        }
    }

    public func close(reason: lws_close_status) {
        closeLock.withLock {
            let callerString = "libwebsockets-protocol".utf8CString
            let caller = callerString.toCPointer()
            if let websocket, !isClosedForever {
                self.lwsCloseStatus.withLockedValue({ $0 = reason })
                lws_close_free_wsi(websocket, reason, caller)
                lws_context_destroy(context)
            }

            // Make sure the variables below are retained until function end
            _ = callerString.count
        }
    }
}

private func websocketCallback(
    wsi: OpaquePointer?,
    reason: lws_callback_reasons,
    user: UnsafeMutableRawPointer?,
    inBytes: UnsafeMutableRawPointer?,
    len: Int
) -> Int32 {
    func getWebsocketClient() -> WebsocketClient? {
        guard let wsi else {
            return nil
        }
        guard let context = lws_get_context(wsi) else {
            return nil
        }
        guard let contextUser = lws_context_user(context) else {
            return nil
        }
        let websocketClient = contextUser.assumingMemoryBound(to: WebsocketClient.WeakSelf.self).pointee

        return websocketClient.weakSelf
    }
    let websocketClient = getWebsocketClient()

    switch reason {
    case LWS_CALLBACK_CLIENT_ESTABLISHED:
        guard let websocketClient else {
            return 1
        }

        websocketClient.wasConnected.withLockedValue({ $0 = true })
        websocketClient.onConnect?.succeed()
        websocketClient.onConnect = nil
        break
    case LWS_CALLBACK_CLIENT_RECEIVE:
        guard let websocketClient else {
            return 1
        }
        guard let inBytes else {
            // We don't really care. No bytes received means we don't do anything.
            break
        }
        let typedPointer = inBytes.bindMemory(to: UInt8.self, capacity: len)
        let data = Data(Array(UnsafeMutableBufferPointer(start: typedPointer, count: len)))

        let isFirst = lws_is_first_fragment(wsi).fromCBool()
        let isFinal = lws_is_final_fragment(wsi).fromCBool()
        let isBinary = lws_frame_is_binary(wsi).fromCBool()

        websocketClient.frameSequence.withLockedValue({ currentFrameSequence in
            if isFirst && isFinal {
                // We can skip everything below. It's a simple message
                if isBinary {
                    // TODO: Binary callback
                    print("Binary Callback Simple")
                    print(data.count)
                } else {
                    // TODO: Text callback
                    print("Text Callback Simple")
                    print(String(data: data, encoding: .utf8) ?? "")
                }

                currentFrameSequence = nil
                return
            }

            var frameSequence = currentFrameSequence ?? .init(type: isBinary ? .binary : .text)
            // Append the frame and update the sequence
            frameSequence.append(data)
            currentFrameSequence = frameSequence

            if isFinal {
                switch frameSequence.type {
                case .binary:
                    // TODO: Binary callback
                    print("Binary Callback")
                    print(data.count)
                    break
                case .text:
                    // TODO: Text callback
                    print("Text Callback")
                    print(frameSequence.textBuffer)
                    break
                default:
                    // Should never happen. If it does, do nothing.
                    break
                }

                currentFrameSequence = nil
            }
        })
        break
    case LWS_CALLBACK_CLIENT_WRITEABLE:
        guard let websocketClient else {
            return 1
        }

        guard let nextToBeWritten = websocketClient.toBeWritten.withLockedValue({ return $0.count > 0 ? $0.removeFirst() : nil }) else {
            // If we don't return 0 the connection will be closed.
            // But just because we don't want to write doesn't mean
            // The connection is dead.
            break
        }
        defer {
            // Sometimes if many sends come at the same time, we only get one callback
            // Make sure to continue until there is nothing left to write.
            lws_callback_on_writable(wsi)
        }
        let returnValue: Int32
        switch nextToBeWritten.opcode {
        case .binary, .continuation:
            // For continuations, it doesn't matter if we call binary or text
            // as this will not be included into the websocket message anyways.
            var data = nextToBeWritten.data
            returnValue = data.withUnsafeMutableBytes { buffer in
                guard let pointer = buffer.baseAddress else {
                    return Int32(1)
                }

                return ws_write_bin(
                    wsi,
                    UnsafeMutablePointer<CChar>(OpaquePointer(pointer)),
                    buffer.count,
                    (nextToBeWritten.opcode != .continuation).toCBool(),
                    nextToBeWritten.fin.toCBool()
                )
            }
        case .text:
            // This will never be a continuation. So send as isStart
            guard let textString = String(data: nextToBeWritten.data, encoding: .utf8)?.utf8CString else {
                returnValue = Int32(1)
                break
            }
            let text = textString.toCPointer()
            returnValue = ws_write_text(
                wsi,
                UnsafeMutablePointer(mutating: text),
                true.toCBool(),
                nextToBeWritten.fin.toCBool()
            )
            // Make sure the string is retained until this point
            _ = textString.count
        case .ping:
            returnValue = ws_write_ping(wsi)
        }
        // Now return the returnValue, but first make sure to resolve the promise
        if returnValue == 0 {
            nextToBeWritten.promise?.succeed()
        } else {
            nextToBeWritten.promise?.fail(WebsocketClient.Error.websocketWriteFailed)
        }
        return returnValue
    case LWS_CALLBACK_WS_PEER_INITIATED_CLOSE:
        guard let websocketClient else {
            return 1
        }

        // This means the other side initiated a close.
        websocketClient.closeLock.withLock {
            var closeReason = LWS_CLOSE_STATUS_NO_STATUS
            if let inBytes, len >= 2 {
                let bytesRaw = inBytes.bindMemory(to: UInt16.self, capacity: 1)
                let status = UInt16(bigEndian: bytesRaw.pointee)
                closeReason = lws_close_status(UInt32(status))
            }

            websocketClient.lwsCloseStatus.withLockedValue({ $0 = closeReason })
        }
        break
    case LWS_CALLBACK_CLIENT_CLOSED:
        // This is emitted when the client was closed.
        // We know the reason already in LWS_CALLBACK_WS_PEER_INITIATED_CLOSE
        // Or the custom close() function if initiated from the client.
        break
    case LWS_CALLBACK_CLIENT_CONNECTION_ERROR:
        guard let websocketClient else {
            return 1
        }

        if let inBytes {
            let typedPointer = inBytes.bindMemory(to: UInt8.self, capacity: len)
            let data = Data(Array(UnsafeMutableBufferPointer(start: typedPointer, count: len)))
            if let str = String(data: data, encoding: .utf8) {
                print("ERROR: \(str)")
            }
        }

        websocketClient.connectionError.withLockedValue({ $0 = true })
        // TODO: Better Error messages
        websocketClient.onConnect?.fail(WebsocketClient.Error.connectionError)
        websocketClient.onConnect = nil
        break
    case LWS_CALLBACK_CLIENT_RECEIVE_PONG:
        // TODO: onPong
        break
    case LWS_CALLBACK_CLIENT_APPEND_HANDSHAKE_HEADER:
        guard let websocketClient else {
            return 1
        }

        // TODO: Append headers.
        // Here we have to append the user headers

        guard let inBytes else {
            return 1
        }
        let p = inBytes.assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self)
        let end = p.pointee?.advanced(by: len)

        for header in websocketClient.headers {
            let keyString = header.key.utf8CString
            let valueString = header.value.utf8CString
            guard lws_add_http_header_by_name(
                wsi,
                keyString.toCPointer(),
                valueString.toCPointer(),
                Int32(header.value.count),
                p,
                end
            ) == 0 else {
                return 1
            }

            // Make sure key and value are retained until this point
            _ = keyString.count
            _ = valueString.count
        }
        break
    case LWS_CALLBACK_CLIENT_CONFIRM_EXTENSION_SUPPORTED:
        break
    case LWS_CALLBACK_CLIENT_FILTER_PRE_ESTABLISH:
        break
    default:
        break
    }

    return 0
}

private struct WebsocketFrameSequence: Sendable {
    var binaryBuffer: Data
    var textBuffer: String
    let type: WebsocketOpcode
    let lock: NIOLock

    init(type: WebsocketOpcode) {
        self.binaryBuffer = Data()
        self.textBuffer = .init()
        self.type = type
        self.lock = .init()
    }

    mutating func append(_ frame: Data) {
        self.lock.withLockVoid {
            switch type {
            case .binary:
                self.binaryBuffer.append(frame)
            case .text:
                if let string = String(data: frame, encoding: .utf8) {
                    self.textBuffer += string
                }
            default: break
            }
        }
    }
}
