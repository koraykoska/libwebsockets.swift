import Clibwebsockets
import Dispatch
import NIOCore
import NIOConcurrencyHelpers
import Foundation

public class WebsocketClient {
    public enum Error: Swift.Error {
        case contextCreationFailed
        case connectionError(description: String)
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
    private let extensionsPointer: UnsafeMutablePointer<lws_extension> = UnsafeMutablePointer<lws_extension>.allocate(capacity: 2)

    private var lwsContextCreationInfo: lws_context_creation_info!

    private var lwsProtocols: lws_protocols!
    private var lwsEmptyProtocol: lws_protocols!

    private var permessageDeflateExtension: lws_extension!
    private let permessageDeflateExtensionName: ContiguousArray<CChar>
    private let permessageDeflateExtensionHeader: ContiguousArray<CChar>
    private var emptyExtension: lws_extension!

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
    fileprivate let waitingLwsCloseStatus: NIOLockedValueBox<lws_close_status?> = .init(nil)

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
    public let permessageDeflate: Bool
    public let eventLoop: EventLoop

    // Needs to be emptied after usage to not create a retain cycle
    fileprivate var onConnect: EventLoopPromise<Void>?

    // Writable to the websocket
    fileprivate let toBeWritten: NIOLockedValueBox<Array<(
        data: Data,
        opcode: WebsocketOpcode,
        fin: Bool,
        promise: EventLoopPromise<Void>?
    )>> = .init([])

    // MARK: - Callbacks

    fileprivate var onTextCallback: NIOLoopBoundBox<@Sendable (WebsocketClient, String) -> ()>?
    fileprivate var onBinaryCallback: NIOLoopBoundBox<@Sendable (WebsocketClient, Data) -> ()>?
    fileprivate var onPingCallback: NIOLoopBoundBox<@Sendable (WebsocketClient, Data) -> ()>?
    fileprivate var onPongCallback: NIOLoopBoundBox<@Sendable (WebsocketClient, Data) -> ()>?
    fileprivate var onCloseCallback: NIOLoopBoundBox<@Sendable (lws_close_status) -> ()>?

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
        permessageDeflate: Bool = true,
        connectionTimeoutSeconds: UInt32 = 10,
        eventLoop: EventLoop,
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
        self.permessageDeflate = permessageDeflate
        self.eventLoop = eventLoop
        self.onConnect = onConnect

        self.permessageDeflateExtensionName = "permessage-deflate".utf8CString
        self.permessageDeflateExtensionHeader = "permessage-deflate".utf8CString

        // Timeout to prevent leaking promise
        eventLoop.scheduleTask(in: .seconds(2 * Int64(connectionTimeoutSeconds)), {
            if let onConnect = self.onConnect {
                onConnect.fail(Error.connectionError(description: "timeout"))
                self.onConnect = nil
            }
        })

        // lws things below

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

        // Extensions
        permessageDeflateExtension = lws_extension()
        lws_extension_zero(&permessageDeflateExtension)
        permessageDeflateExtension.name = permessageDeflateExtensionName.toCPointer()
        permessageDeflateExtension.callback = lws_extension_callback_pm_deflate
        permessageDeflateExtension.client_offer = permessageDeflateExtensionHeader.toCPointer()

        extensionsPointer.pointee = permessageDeflateExtension

        emptyExtension = lws_extension()
        lws_extension_zero(&emptyExtension)
        emptyExtension.name = nil
        emptyExtension.callback = nil
        emptyExtension.client_offer = nil

        extensionsPointer.advanced(by: 1).pointee = emptyExtension
        // END Extensions

        lwsContextCreationInfo.protocols = UnsafePointer(protocolsPointer)
        if permessageDeflate {
            lwsContextCreationInfo.extensions = UnsafePointer(extensionsPointer)
        }
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
        self.close(reason: LWS_CLOSE_STATUS_GOINGAWAY, wait: true)

        // Destroy context. User nullify necessary to prevent segfault in future callbacks.
        ws_context_user_nullify(context)
        lws_context_destroy(context)

        protocolsPointer.deinitialize(count: 2)
        protocolsPointer.deallocate()

        extensionsPointer.deinitialize(count: 2)
        extensionsPointer.deallocate()

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
            guard let self, !isClosedForever else {
                return
            }

            // This lws_service call blocks until the next event1
            // arrives. The 250ms is ignored since the newest version.
            lws_service(self.context, 250)
            self.scheduleServiceCall()
        }
    }

    private func close(reason: lws_close_status, wait: Bool) {
        closeLock.withLock {
            if !isClosedForever {
                //                var closeReasonText = ""
                //                lws_close_reason(websocket, reason, &closeReasonText, 0)
                //                let callerText = "libwebsockets-client".utf8CString
                //                let caller = callerText.toCPointer()
                //                lws_close_free_wsi(websocket, reason, caller)
                //                lws_set_timeout(websocket, PENDING_TIMEOUT_CLOSE_SEND, LWS_TO_KILL_SYNC)

                if wait {
                    // Fast kill for deinit
                    lws_set_timeout(websocket, PENDING_TIMEOUT_CLOSE_SEND, LWS_TO_KILL_SYNC)

                    self.markAsClosed(reason: reason)
                } else {
                    self.send("".data(using: .utf8)!, opcode: .close(reason: reason))
                }
            }
        }
    }

    fileprivate func markAsClosed(reason: lws_close_status) {
        if !self.isClosedForever {
            self.lwsCloseStatus.withLockedValue({ $0 = reason })

            // Empty write queue after setting close status
            let pendingWrites = self.toBeWritten.withLockedValue({
                let copy = $0
                $0 = []
                return copy
            })
            for pendingWrite in pendingWrites {
                pendingWrite.promise?.fail(Error.websocketClosed)
            }

            // Notify onClose callback
            let onCloseCallback = self.onCloseCallback
            self.eventLoop.execute {
                onCloseCallback?.value(reason)
            }
        }
    }

    // MARK: - Public API

    public func send(
        _ data: Data,
        opcode: WebsocketOpcode,
        fin: Bool = true,
        promise: EventLoopPromise<Void>? = nil
    ) {
        if !self.eventLoop.inEventLoop {
            self.eventLoop.execute {
                self.send(data, opcode: opcode, fin: fin, promise: promise)
            }

            return
        }

        if isClosedForever {
            promise?.fail(Error.websocketClosed)
            return
        }
        if isClosed {
            promise?.fail(Error.websocketNotYetOpen)
            return
        }

        switch opcode {
        case .binary, .text, .continuation, .ping, .close:
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
        self.close(reason: reason, wait: false)
    }

    public func onText(_ callback: @Sendable @escaping (WebsocketClient, String) -> ()) {
        if !self.eventLoop.inEventLoop {
            self.eventLoop.execute {
                self.onText(callback)
            }
            return
        }

        if let onTextCallback {
            onTextCallback.value = callback
        } else {
            self.onTextCallback = .init(callback, eventLoop: self.eventLoop)
        }
    }

    public func onBinary(_ callback: @Sendable @escaping (WebsocketClient, Data) -> ()) {
        if !self.eventLoop.inEventLoop {
            self.eventLoop.execute {
                self.onBinary(callback)
            }
            return
        }

        if let onBinaryCallback {
            onBinaryCallback.value = callback
        } else {
            self.onBinaryCallback = .init(callback, eventLoop: self.eventLoop)
        }
    }

    public func onPong(_ callback: @Sendable @escaping (WebsocketClient, Data) -> ()) {
        if !self.eventLoop.inEventLoop {
            self.eventLoop.execute {
                self.onPong(callback)
            }
            return
        }

        if let onPongCallback {
            onPongCallback.value = callback
        } else {
            self.onPongCallback = .init(callback, eventLoop: self.eventLoop)
        }
    }

    public func onPing(_ callback: @Sendable @escaping (WebsocketClient, Data) -> ()) {
        if !self.eventLoop.inEventLoop {
            self.eventLoop.execute {
                self.onPing(callback)
            }
            return
        }

        if let onPingCallback {
            onPingCallback.value = callback
        } else {
            self.onPingCallback = .init(callback, eventLoop: self.eventLoop)
        }
    }

    public func onClose(_ callback: @Sendable @escaping (lws_close_status) -> ()) {
        if !self.eventLoop.inEventLoop {
            self.eventLoop.execute {
                self.onClose(callback)
            }
            return
        }

        if let onCloseCallback {
            onCloseCallback.value = callback
        } else {
            self.onCloseCallback = .init(callback, eventLoop: self.eventLoop)
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
            return -1
        }

        websocketClient.wasConnected.withLockedValue({ $0 = true })
        websocketClient.eventLoop.execute {
            websocketClient.onConnect?.succeed()
            websocketClient.onConnect = nil
        }
        break
    case LWS_CALLBACK_CLIENT_RECEIVE:
        guard let websocketClient else {
            return -1
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
                    websocketClient.eventLoop.execute {
                        websocketClient.onBinaryCallback?.value(websocketClient, data)
                    }
                } else {
                    // TODO: Text callback
                    if let stringMessage = String(data: data, encoding: .utf8) {
                        websocketClient.eventLoop.execute {
                            websocketClient.onTextCallback?.value(websocketClient, stringMessage)
                        }
                    }
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
                    websocketClient.eventLoop.execute {
                        websocketClient.onBinaryCallback?.value(websocketClient, frameSequence.binaryBuffer)
                    }
                    break
                case .text:
                    // TODO: Text callback
                    websocketClient.eventLoop.execute {
                        websocketClient.onTextCallback?.value(websocketClient, frameSequence.textBuffer)
                    }
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
            return -1
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
                    return -1
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
                returnValue = -1
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
        case .close(let reason):
            returnValue = -1
            var dataPointer = Array<UInt8>(nextToBeWritten.data)
            lws_close_reason(wsi, reason, &dataPointer, nextToBeWritten.data.count)

            // We don't set to closed yet. Special callback for that.
            websocketClient.waitingLwsCloseStatus.withLockedValue({ $0 = reason })
        }

        // Now return the returnValue, but first make sure to resolve the promise
        // Close should return non-null. It still succeeded.
        if returnValue == 0 || nextToBeWritten.opcode.isClose() {
            nextToBeWritten.promise?.succeed()
        } else {
            nextToBeWritten.promise?.fail(WebsocketClient.Error.websocketWriteFailed)
        }

        // Return the returnValue.
        return returnValue
    case LWS_CALLBACK_WS_PEER_INITIATED_CLOSE:
        guard let websocketClient else {
            return -1
        }

        // This means the other side initiated a close.
        var closeReason = LWS_CLOSE_STATUS_NO_STATUS
        if let inBytes, len >= 2 {
            let bytesRaw = inBytes.bindMemory(to: UInt16.self, capacity: 1)
            let status = UInt16(bigEndian: bytesRaw.pointee)
            closeReason = lws_close_status(UInt32(status))
        }
        websocketClient.closeLock.withLock {
            websocketClient.markAsClosed(reason: closeReason)
        }
        break
    case LWS_CALLBACK_CLIENT_CLOSED:
        guard let websocketClient else {
            return -1
        }

        var closeReason = websocketClient.waitingLwsCloseStatus.withLockedValue({ $0 })
        if closeReason == nil, let inBytes, len >= 2 {
            let bytesRaw = inBytes.bindMemory(to: UInt16.self, capacity: 1)
            let status = UInt16(bigEndian: bytesRaw.pointee)
            closeReason = lws_close_status(UInt32(status))
        }
        websocketClient.closeLock.withLock {
            websocketClient.markAsClosed(reason: closeReason ?? LWS_CLOSE_STATUS_NO_STATUS)
        }
        break
    case LWS_CALLBACK_CLIENT_CONNECTION_ERROR:
        guard let websocketClient else {
            return -1
        }

        var description = ""
        if let inBytes {
            let typedPointer = inBytes.bindMemory(to: UInt8.self, capacity: len)
            let data = Data(Array(UnsafeMutableBufferPointer(start: typedPointer, count: len)))
            if let str = String(data: data, encoding: .utf8) {
                description = str
            }
        }

        websocketClient.connectionError.withLockedValue({ $0 = true })
        // TODO: Better Error messages
        websocketClient.eventLoop.execute {
            websocketClient.onConnect?.fail(WebsocketClient.Error.connectionError(description: description))
            websocketClient.onConnect = nil
        }
        break
    case LWS_CALLBACK_CLIENT_RECEIVE_PONG:
        // TODO: onPong
        guard let websocketClient else {
            return -1
        }

        var data = Data()
        if let inBytes {
            let typedPointer = inBytes.bindMemory(to: UInt8.self, capacity: len)
            data = Data(Array(UnsafeMutableBufferPointer(start: typedPointer, count: len)))
        }

        websocketClient.eventLoop.execute {
            websocketClient.onPongCallback?.value(websocketClient, data)
        }
        break
    case LWS_CALLBACK_CLIENT_APPEND_HANDSHAKE_HEADER:
        guard let websocketClient else {
            return -1
        }

        // TODO: Append headers.
        // Here we have to append the user headers

        guard let inBytes else {
            return -1
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
                return -1
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

    if let websocketClient, websocketClient.isClosedForever {
        // If for whatever reason we get another callback after the connection being closed, close again.

        // THIS DOES NOT WORK

//        let closeReason = websocketClient.lwsCloseStatus.withLockedValue({ $0 }) ?? LWS_CLOSE_STATUS_GOINGAWAY
//
//        var dataPointer = ""
//        lws_close_reason(wsi, closeReason, &dataPointer, dataPointer.count)
//
//        return -1
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
