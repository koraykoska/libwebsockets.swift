import Clibwebsockets
import Dispatch
import NIOCore
import NIOConcurrencyHelpers
import Foundation

public class WebsocketClient: WebsocketConnection {
    public enum Error: Swift.Error {
        case contextCreationFailed
        case connectionError(description: String)
        case websocketWriteFailed
        case websocketClosed
        case websocketNotYetOpen
    }

    // MARK: - Properties

    // See: https://stackoverflow.com/questions/61236195/create-a-weak-unsafemutablerawpointer?rq=3
    fileprivate class WeakSelf {
        fileprivate weak var weakSelf: WebsocketClient?

        fileprivate init(weakSelf: WebsocketClient) {
            self.weakSelf = weakSelf
        }
    }
    private let selfPointer: UnsafeMutablePointer<WeakSelf>

    private var websocketClientContext: WebsocketClientContext? = nil

    private var lwsCCInfo: lws_client_connect_info!

    fileprivate var websocket: NIOLockedValueBox<OpaquePointer?> = .init(nil)

    /// Whether the websocket was ever connected to the server. True once it connected, even if eventually disconnected.
    fileprivate let wasConnected: NIOLockedValueBox<Bool> = .init(false)

    /// True if the connection errored. Will never connect again. lwsClose Status might not be set.
    fileprivate let connectionError: NIOLockedValueBox<Bool> = .init(false)

    /// nil until a close event is received. Do not rely soely on it as connection errors lead to a never initialized close status.
    /// Instead, check `wasConnected` first to make sure a connection has been established before checking this value.
    fileprivate let lwsCloseStatus: NIOLockedValueBox<WebsocketCloseStatus?> = .init(nil)
    fileprivate let waitingLwsCloseStatus: NIOLockedValueBox<WebsocketCloseStatus?> = .init(nil)

    /// Internally managed buffer of frames. Emitted once the full message is there.
    /// Internal Note: This doesn't need to be a NIOLockedValueBox as we only access it from
    /// the EventLoop.
    fileprivate var frameSequence: WebsocketFrameSequence? = nil
    fileprivate let frameSequenceType: WebsocketFrameSequence.Type

    // State variables

    /// Returns true if the underlying websocket connection is closed.
    /// Either because it isn't open yet or because the connection was closed.
    public var isClosed: Bool {
        if websocket.withLockedValue({ $0 == nil }) {
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
    public let maxMessageSize: Int?
    public let permessageDeflate: Bool
    public let eventLoop: EventLoop

    // Needs to be emptied after usage to not create a retain cycle
    fileprivate var onConnect: NIOLockedValueBox<EventLoopPromise<Void>?>
    fileprivate var fetchOnConnect: EventLoopPromise<Void>? {
        return onConnect.withLockedValue({
            if let promise = $0 {
                $0 = nil
                return promise
            }

            return nil
        })
    }

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
    fileprivate var onFragmentCallback: NIOLoopBoundBox<
        @Sendable (_ ws: WebsocketClient, _ data: Data, _ isText: Bool, _ isFirst: Bool, _ isFinal: Bool) -> ()
    >?
//    fileprivate var onPingCallback: NIOLoopBoundBox<@Sendable (WebsocketClient, Data) -> ()>?
    fileprivate var onPongCallback: NIOLoopBoundBox<@Sendable (WebsocketClient, Data) -> ()>?
    fileprivate var onCloseCallback: NIOLoopBoundBox<@Sendable (WebsocketCloseStatus) -> ()>?

    private let _pingInterval: NIOLockedValueBox<TimeAmount?> = .init(nil)
    private let scheduledPingIntervalTimeoutTask: NIOLockedValueBox<Scheduled<Void>?> = .init(nil)
    fileprivate let waitingForPong: NIOLockedValueBox<Bool> = .init(false)

    // MARK: - Initialization

    /// Connect to the given Websocket server.
    /// Resolves with the `WebsocketClient` when the connection succeeds or fails.
    ///
    /// Note: `maxFrameSize` does not prevent the other side to send larger frames. It does 2 things:
    /// 1) If you call `send()` with more bytes than `maxFrameSize`, the message is automatically
    ///     split into frames of size (at most) `maxFrameSize`.
    /// 2) If a frame is received that is larger than `maxFrameSize`, the frame is split into frames of size
    ///     `maxFrameSize` (at most) and delivered individually.
    ///
    /// If you want to set a limit on message sizes (to kill the connection if exceeded), set `maxMessageSize`.
    ///
    /// - parameter scheme: `.ws` or `.wss`.
    /// - parameter host: The host to connect to. e.g.: `ws.echoserver.org`
    /// - parameter port: The port to connect to. Defaults to 443 for wss and 80 otherwise.
    /// - parameter path: The path section of the ws connect url. e.g.: `/echo`
    /// - parameter query: The query section of the ws connect url. e.g.: `?someParam=true&otherParam=15`
    /// - parameter headers: Custom headers to add to the connect request.
    /// - parameter origin: The origin the request comes from (origin header). Defaults to localhost.
    /// - parameter maxFrameSize: The maximum size of a single frame of the websocket connection (in bytes).
    ///                           Defaults to 3000 as 2x MTU is a good value and 1500 MTU is standard.
    /// - parameter maxMessageSize: The maximum size of a single message. Kills the connection if a message is received that's larger.
    /// - parameter permessageDeflate: Whether to enable compression support. Server still decides to enable or not. Defaults to true.
    /// - parameter connectionTimeoutSeconds: Seconds to wait before timing out the connection request.
    /// - parameter eventLoop: The swift-nio EventLoop to run operations and callbacks on.
    /// - parameter onText: The onText callback to be set on the websocket connection.
    /// - parameter onBinary: The onBinary callback to be set on the websocket connection.
    /// - parameter onFragment: The onFragment callback to be set on the websocket connection.
    /// - parameter onPong: The onPong callback to be set on the websocket connection.
    /// - parameter onClose: The onClose callback to be set on the websocket connection.
    ///
    /// - returns: The EventLoopFuture of the connected Websocket in form of an instance of `WebsocketClient`.
    public static func connect(
        scheme: WebsocketScheme = .ws,
        host: String,
        port: UInt16? = nil,
        path: String = "/",
        query: String? = nil,
        headers: [String: String] = [:],
        origin: String = "localhost",
        maxFrameSize: Int = 3000,
        maxMessageSize: Int? = nil,
        permessageDeflate: Bool = true,
        connectionTimeoutSeconds: UInt32 = 10,
        eventLoop: EventLoop,
        onText: (@Sendable (WebsocketClient, String) -> ())? = nil,
        onBinary: (@Sendable (WebsocketClient, Data) -> ())? = nil,
        onFragment: (@Sendable (
            _ ws: WebsocketClient, _ data: Data, _ isText: Bool, _ isFirst: Bool, _ isFinal: Bool
        ) -> ())? = nil,
        onPong: (@Sendable (WebsocketClient, Data) -> ())? = nil,
        onClose: (@Sendable (WebsocketCloseStatus) -> ())? = nil
    ) -> EventLoopFuture<WebsocketClient> {
        let connectPromise = eventLoop.makePromise(of: Void.self)

        let parsedPort = port ?? (scheme == .wss ? 443 : 80)
        let ws = WebsocketClient(
            scheme: scheme,
            host: host,
            port: parsedPort,
            path: path,
            query: query,
            headers: headers,
            origin: origin,
            maxFrameSize: maxFrameSize,
            maxMessageSize: maxMessageSize,
            permessageDeflate: permessageDeflate,
            connectionTimeoutSeconds: connectionTimeoutSeconds,
            eventLoop: eventLoop,
            onConnect: connectPromise
        )

        if let onText {
            ws.onText(onText)
        }
        if let onBinary {
            ws.onBinary(onBinary)
        }
        if let onFragment {
            ws.onFragment(onFragment)
        }
        if let onPong {
            ws.onPong(onPong)
        }
        if let onClose {
            ws.onClose(onClose)
        }

        return connectPromise.futureResult.map({ return ws })
    }

    /// Connect to the given Websocket server.
    /// Returns the `WebsocketClient` when the connection succeeds or throws with the connection error.
    ///
    /// Note: `maxFrameSize` does not prevent the other side to send larger frames. It does 2 things:
    /// 1) If you call `send()` with more bytes than `maxFrameSize`, the message is automatically
    ///     split into frames of size (at most) `maxFrameSize`.
    /// 2) If a frame is received that is larger than `maxFrameSize`, the frame is split into frames of size
    ///     `maxFrameSize` (at most) and delivered individually.
    ///
    /// If you want to set a limit on message sizes (to kill the connection if exceeded), set `maxMessageSize`.
    ///
    /// - parameter scheme: `.ws` or `.wss`.
    /// - parameter host: The host to connect to. e.g.: `ws.echoserver.org`
    /// - parameter port: The port to connect to. Defaults to 443 for wss and 80 otherwise.
    /// - parameter path: The path section of the ws connect url. e.g.: `/echo`
    /// - parameter query: The query section of the ws connect url. e.g.: `?someParam=true&otherParam=15`
    /// - parameter headers: Custom headers to add to the connect request.
    /// - parameter origin: The origin the request comes from (origin header). Defaults to localhost.
    /// - parameter maxFrameSize: The maximum size of a single frame of the websocket connection (in bytes).
    ///                           Defaults to 3000 as 2x MTU is a good value and 1500 MTU is standard.
    /// - parameter maxMessageSize: The maximum size of a single message. Kills the connection if a message is received that's larger.
    /// - parameter permessageDeflate: Whether to enable compression support. Server still decides to enable or not. Defaults to true.
    /// - parameter connectionTimeoutSeconds: Seconds to wait before timing out the connection request.
    /// - parameter eventLoop: The swift-nio EventLoop to run operations and callbacks on.
    /// - parameter onText: The onText callback to be set on the websocket connection.
    /// - parameter onBinary: The onBinary callback to be set on the websocket connection.
    /// - parameter onFragment: The onFragment callback to be set on the websocket connection.
    /// - parameter onPong: The onPong callback to be set on the websocket connection.
    /// - parameter onClose: The onClose callback to be set on the websocket connection.
    ///
    /// - returns: The instance of `WebsocketClient`.
    public static func connect(
        scheme: WebsocketScheme = .ws,
        host: String,
        port: UInt16? = nil,
        path: String = "/",
        query: String? = nil,
        headers: [String: String] = [:],
        origin: String = "localhost",
        maxFrameSize: Int = 3000,
        maxMessageSize: Int? = nil,
        permessageDeflate: Bool = true,
        connectionTimeoutSeconds: UInt32 = 10,
        eventLoop: EventLoop,
        onText: (@Sendable (WebsocketClient, String) -> ())? = nil,
        onBinary: (@Sendable (WebsocketClient, Data) -> ())? = nil,
        onFragment: (@Sendable (
            _ ws: WebsocketClient, _ data: Data, _ isText: Bool, _ isFirst: Bool, _ isFinal: Bool
        ) -> ())? = nil,
        onPong: (@Sendable (WebsocketClient, Data) -> ())? = nil,
        onClose: (@Sendable (WebsocketCloseStatus) -> ())? = nil
    ) async throws -> WebsocketClient {
        return try await WebsocketClient.connect(
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            query: query,
            headers: headers,
            origin: origin,
            maxFrameSize: maxFrameSize,
            maxMessageSize: maxMessageSize,
            permessageDeflate: permessageDeflate,
            connectionTimeoutSeconds: connectionTimeoutSeconds,
            eventLoop: eventLoop,
            onText: onText,
            onBinary: onBinary,
            onFragment: onFragment,
            onPong: onPong,
            onClose: onClose
        ).get()
    }

    private init(
        scheme: WebsocketScheme = .ws,
        host: String,
        port: UInt16,
        path: String,
        query: String?,
        headers: [String: String],
        origin: String,
        maxFrameSize: Int,
        maxMessageSize: Int?,
        frameSequenceType: WebsocketFrameSequence.Type = WebsocketSimpleAppendFrameSequence.self,
        permessageDeflate: Bool,
        connectionTimeoutSeconds: UInt32,
        eventLoop: EventLoop,
        onConnect: EventLoopPromise<Void>
    ) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
        self.query = query
        self.headers = headers
        self.origin = origin
        self.maxFrameSize = maxFrameSize
        self.maxMessageSize = maxMessageSize
        self.frameSequenceType = frameSequenceType
        self.permessageDeflate = permessageDeflate
        self.eventLoop = eventLoop
        self.onConnect = .init(onConnect)

        selfPointer = UnsafeMutablePointer<WeakSelf>.allocate(capacity: 1)

        guard let websocketClientContext = WebsocketClientContext.shared() else {
            eventLoop.execute {
                if let onConnect = self.fetchOnConnect {
                    onConnect.fail(Error.contextCreationFailed)
                }
            }
            return
        }
        self.websocketClientContext = websocketClientContext

        // Timeout to prevent leaking promise
        eventLoop.scheduleTask(in: .seconds(2 * Int64(connectionTimeoutSeconds)), {
            if let onConnect = self.fetchOnConnect {
                onConnect.fail(Error.connectionError(description: "timeout"))
            }
        })

        // lws things below

        // self pointer
        selfPointer.initialize(to: .init(weakSelf: self))

        // Client Connect Info
        lwsCCInfo = lws_client_connect_info()
        lws_client_connect_info_zero(&lwsCCInfo)
        lwsCCInfo.context = websocketClientContext.context
        let lwsCCInfoHost = host.utf8CString
        lwsCCInfo.address = lwsCCInfoHost.toCPointer()
        lwsCCInfo.port = Int32(port)
        let lwsCCInfoPath = "\(path)\(query ?? "")".utf8CString
        lwsCCInfo.path = lwsCCInfoPath.toCPointer()
        // TODO: Use query and all other params?
//        lwsCCInfo.host = lws_canonical_hostname(context)
        let lwsCCInfoHostHeader = "\(host):\(port)".utf8CString
        lwsCCInfo.host = lwsCCInfoHostHeader.toCPointer()
        let lwsCCInfoOrigin = origin.utf8CString
        lwsCCInfo.origin = lwsCCInfoOrigin.toCPointer()
        lwsCCInfo.protocol = websocketClientContext.lwsProtocols.name
        switch scheme {
        case .wss:
            ws_set_ssl_connection(&lwsCCInfo)
        case .ws:
            break
        }

        // Set a pointer back to self for communication from thr callback to the instance.
        lwsCCInfo.opaque_user_data = UnsafeMutableRawPointer(selfPointer)

        // This is to be able to later use lws_set_wsi_user
        lwsCCInfo.userdata = UnsafeMutableRawPointer(&_defaultLwsUserPointer)

        // Connect
        websocketClientContext.scheduleFastServiceExecution {
            guard let websocket = lws_client_connect_via_info(&self.lwsCCInfo) else {
                eventLoop.execute {
                    if let onConnect = self.fetchOnConnect {
                        onConnect.fail(Error.connectionError(description: "lws_client_connect_via_info failed"))
                    }
                }
                return
            }
            self.websocket.withLockedValue({ $0 = websocket })

            // Make sure the below variables are retained until function end
            _ = lwsCCInfoHost.count
            _ = lwsCCInfoHostHeader.count
            _ = lwsCCInfoPath.count
            _ = lwsCCInfoOrigin.count
        }
    }

    deinit {
        // The below is for rare cases where the connection neither succeeded nor failed yet.
        if let onConnect = self.fetchOnConnect {
            _ = eventLoop.execute {
                onConnect.fail(Error.connectionError(description: "websocket freed (deinit called) before connection succeeded"))
            }
        }

        // Close if not yet closed
        if let websocket = self.websocket.withLockedValue({ $0 }) {
            websocketClientContext?.scheduleEventLoopExecution(websocket) {
                // Makes sure our callback returns -1 always. Will close itself.
                lws_set_wsi_user(websocket, &_closedLwsUserPointer)
            }
        }
        self.close(reason: .goingAway, fastCallbackOnly: true)

        // Make sure to free this only after the websocket is destroyed
        // Otherwise we might receive a callback, try to use this pointer
        // And crash...
        selfPointer.deinitialize(count: 1)
        selfPointer.deallocate()
    }

    // MARK: - Helpers

    private func close(reason: WebsocketCloseStatus, fastCallbackOnly: Bool) {
        closeLock.withLock {
            if !isClosedForever {
                if fastCallbackOnly {
                    // Fast kill for deinit
                    self.markAsClosed(reason: reason)
                } else {
                    self.send("".data(using: .utf8)!, opcode: .close(reason: reason))
                }
            }
        }
    }

    fileprivate func markAsClosed(reason: WebsocketCloseStatus) {
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
                // TODO: To prevent retain cycles if user retains websocket in onClose, we can now set the onCloseCallback to nil if self exists?
                onCloseCallback?.value(reason)
            }
        }
    }

    @Sendable
    private func pingAndScheduleNextTimeoutTask() {
        if !self.eventLoop.inEventLoop {
            self.eventLoop.execute {
                self.pingAndScheduleNextTimeoutTask()
            }
            return
        }

        guard let pingInterval = pingInterval else {
            return
        }

        if waitingForPong.withLockedValue({ $0 }) {
            self.waitingForPong.withLockedValue { $0 = false }
            // We never received a pong from our last ping, so the connection has timed out
            self.close(reason: .abnormalClose)
        } else {
            self.waitingForPong.withLockedValue { $0 = true }
            self.send(Data(), opcode: .ping)
            self.scheduledPingIntervalTimeoutTask.withLockedValue {
                $0 = self.eventLoop.scheduleTask(
                    deadline: .now() + pingInterval,
                    self.pingAndScheduleNextTimeoutTask
                )
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
        guard let wsi = websocket.withLockedValue({ $0 }) else {
            promise?.fail(Error.websocketClosed)
            return
        }

        switch opcode {
        case .binary, .text, .continuation:
            if data.count <= maxFrameSize {
                toBeWritten.withLockedValue({
                    $0.append((
                        data: data,
                        opcode: opcode,
                        fin: fin,
                        promise: promise
                    ))
                })
                break
            }

            let splitted = data.chunked(into: maxFrameSize)
            var writeChunks = [(data: Data, opcode: WebsocketOpcode, fin: Bool, promise: EventLoopPromise<Void>?)?](
                repeating: nil, count: splitted.count
            )
            for i in 0..<splitted.count {
                writeChunks[i] = (
                    data: splitted[i],
                    opcode: i == 0 ? opcode : .continuation,
                    fin: i == splitted.count - 1 ? fin : false,
                    promise: i == splitted.count - 1 ? promise : nil
                )
            }
            toBeWritten.withLockedValue({
                $0.append(contentsOf: writeChunks.compactMap({ $0 }))
            })
        case .ping, .close:
            toBeWritten.withLockedValue({
                $0.append((
                    data: data,
                    opcode: opcode,
                    fin: fin,
                    promise: promise
                ))
            })
        }

        // Make sure to ask for the write callback to execute
        websocketClientContext?.callWritable(wsi: wsi)
    }

    public func close(reason: WebsocketCloseStatus) {
        self.close(reason: reason, fastCallbackOnly: false)
    }

    public var pingInterval: TimeAmount? {
        get {
            return _pingInterval.withLockedValue { $0 }
        }
        set {
            _pingInterval.withLockedValue { $0 = newValue }
            if newValue != nil {
                scheduledPingIntervalTimeoutTask.withLockedValue({
                    $0?.cancel()
                    waitingForPong.withLockedValue { $0 = false }

                    // This should not block as we would be in a deadlock
                    // in certain cases (if we are in the correct EventLoop).
                    // Hence we schedule it into the EventLoop to return immediately
                    // without blocking.
                    self.eventLoop.execute {
                        self.pingAndScheduleNextTimeoutTask()
                    }
                })
            } else {
                scheduledPingIntervalTimeoutTask.withLockedValue {
                    $0?.cancel()
                    waitingForPong.withLockedValue { $0 = false }
                }
            }
        }
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

    public func onFragment(
        _ callback: @Sendable @escaping (
            _ ws: WebsocketClient, _ data: Data, _ isText: Bool, _ isFirst: Bool, _ isFinal: Bool
        ) -> ()
    ) {
        if !self.eventLoop.inEventLoop {
            self.eventLoop.execute {
                self.onFragment(callback)
            }
            return
        }

        if let onFragmentCallback {
            onFragmentCallback.value = callback
        } else {
            self.onFragmentCallback = .init(callback, eventLoop: self.eventLoop)
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

//    public func onPing(_ callback: @Sendable @escaping (WebsocketClient, Data) -> ()) {
//        if !self.eventLoop.inEventLoop {
//            self.eventLoop.execute {
//                self.onPing(callback)
//            }
//            return
//        }
//
//        if let onPingCallback {
//            onPingCallback.value = callback
//        } else {
//            self.onPingCallback = .init(callback, eventLoop: self.eventLoop)
//        }
//    }

    public func onClose(_ callback: @Sendable @escaping (WebsocketCloseStatus) -> ()) {
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

internal func _lws_swift_websocketClientCallback(
    wsi: OpaquePointer?,
    reason: lws_callback_reasons,
    user: UnsafeMutableRawPointer?,
    inBytes: UnsafeMutableRawPointer?,
    len: Int
) -> Int32 {
    if let wsi, let context = lws_get_context(wsi), let user = lws_context_user(context) {
        let websocketClientContext = user.assumingMemoryBound(to: WebsocketClientContext.WeakSelf.self).pointee.weakSelf

        // To make sure things get removed if necessary before we do anything else.
        while let callback = websocketClientContext?.popEventLoopExecution() {
            callback()
        }
    }

    func getWebsocketClient() -> WebsocketClient? {
        guard let wsi else {
            return nil
        }

        guard let wsiUser = lws_get_opaque_user_data(wsi) else {
            return nil
        }

        if lws_wsi_user(wsi) == UnsafeMutableRawPointer(&_closedLwsUserPointer) {
            // This means we explicitly marked the websocket as "done" or freed.
            // Doing the below would crash.
            return nil
        }

        let websocketClient = wsiUser.assumingMemoryBound(to: WebsocketClient.WeakSelf.self).pointee

        return websocketClient.weakSelf
    }
    lazy var websocketClient: WebsocketClient? = getWebsocketClient()

    switch reason {
    case LWS_CALLBACK_CLIENT_ESTABLISHED:
        guard let websocketClient else {
            return -1
        }

        websocketClient.wasConnected.withLockedValue({ $0 = true })
        websocketClient.eventLoop.execute {
            websocketClient.fetchOnConnect?.succeed()
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
        // TODO: Performance measure
//        let typedPointer = inBytes.bindMemory(to: UInt8.self, capacity: len)
//        let data = Data(Array(UnsafeMutableBufferPointer(start: typedPointer, count: len)))
        let data = Data(bytes: inBytes, count: len)

        let isFirst = lws_is_first_fragment(wsi).fromCBool()
        let isFinal = lws_is_final_fragment(wsi).fromCBool()
        let isBinary = lws_frame_is_binary(wsi).fromCBool()

        websocketClient.eventLoop.execute {
            websocketClient.onFragmentCallback?.value(websocketClient, data, !isBinary, isFirst, isFinal)
        }

        websocketClient.eventLoop.execute {
            if isFirst && isFinal {
                // We can skip everything below. It's a simple message

                // We don't check max message size here. If user set `maxFrameSize`
                // greater than `maxMessageSize`, he will have to deal with the consequences.
                // If not, this case is handled by `rx_buffer_size` in libwebsockets already.

                if isBinary {
                    websocketClient.eventLoop.execute {
                        websocketClient.onBinaryCallback?.value(websocketClient, data)
                    }
                } else {
                    if let stringMessage = String(data: data, encoding: .utf8) {
                        websocketClient.eventLoop.execute {
                            websocketClient.onTextCallback?.value(websocketClient, stringMessage)
                        }
                    } else {
                        websocketClient.close(reason: .invalidPayload)
                    }
                }

                websocketClient.frameSequence = nil
                return
            }

            var frameSequence = websocketClient.frameSequence ?? websocketClient.frameSequenceType.init(type: isBinary ? .binary : .text)
            // Append the frame and update the sequence
            frameSequence.append(data)

            // Check message size
            let messageSize = isBinary ? frameSequence.binaryBuffer.count : frameSequence.textBuffer.count
            if let maxMessageSize = websocketClient.maxMessageSize, messageSize > maxMessageSize {
                // Close connection
                websocketClient.close(reason: .messageTooLarge)
                // Reset frame sequence just in case
                websocketClient.frameSequence = nil
                return
            }

            // Set current frame sequence
            websocketClient.frameSequence = frameSequence

            if isFinal {
                switch frameSequence.type {
                case .binary:
                    websocketClient.eventLoop.execute {
                        websocketClient.onBinaryCallback?.value(websocketClient, frameSequence.binaryBuffer)
                    }
                    break
                case .text:
                    websocketClient.eventLoop.execute {
                        guard let text = String(data: frameSequence.textBuffer, encoding: .utf8) else {
                            websocketClient.close(reason: .invalidPayload)
                            return
                        }
                        websocketClient.onTextCallback?.value(websocketClient, text)
                    }
                    break
                default:
                    // Should never happen. If it does, do nothing.
                    break
                }

                websocketClient.frameSequence = nil
            }
        }
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
        case .binary, .text, .continuation:
            var data = nextToBeWritten.data
            returnValue = data.withUnsafeMutableBytes { buffer in
                guard let pointer = buffer.baseAddress else {
                    return -1
                }

                // For continuations, it doesn't matter if we call binary or text
                // as this will not be included into the websocket message anyways.

                return ws_write_bin_text(
                    wsi,
                    UnsafeMutablePointer<CChar>(OpaquePointer(pointer)),
                    buffer.count,
                    (nextToBeWritten.opcode == .text).toCBool(),
                    (nextToBeWritten.opcode != .continuation).toCBool(),
                    nextToBeWritten.fin.toCBool()
                )
            }
        case .ping:
            returnValue = ws_write_ping(wsi)
        case .close(let reason):
            returnValue = -1
            var dataPointer = Array<UInt8>(nextToBeWritten.data)
            lws_close_reason(wsi, reason.toLwsCloseStatus(), &dataPointer, nextToBeWritten.data.count)

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
        websocketClient.eventLoop.execute {
            websocketClient.closeLock.withLock {
                websocketClient.markAsClosed(reason: WebsocketCloseStatus(fromLwsCloseStatus: closeReason))
            }
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
            closeReason = WebsocketCloseStatus(fromLwsCloseStatus: lws_close_status(UInt32(status)))
        }
        websocketClient.eventLoop.execute {
            websocketClient.closeLock.withLock {
                websocketClient.markAsClosed(reason: closeReason ?? .noStatus)
            }
        }
        break
    case LWS_CALLBACK_CLIENT_CONNECTION_ERROR:
        guard let websocketClient else {
            return -1
        }

        var description = ""
        if let inBytes, len > 0 {
            let data = Data(bytes: inBytes, count: len)
            if let str = String(data: data, encoding: .utf8) {
                description = str
            }
        }

        websocketClient.connectionError.withLockedValue({ $0 = true })
        websocketClient.eventLoop.execute {
            websocketClient.fetchOnConnect?.fail(WebsocketClient.Error.connectionError(description: description))
        }
        break
    case LWS_CALLBACK_CLIENT_RECEIVE_PONG:
        guard let websocketClient else {
            return -1
        }

        // Pong received so not waiting anymore
        websocketClient.waitingForPong.withLockedValue { $0 = false }

        var data = Data()
        if len > 0, let inBytes {
            data = Data(bytes: inBytes, count: len)
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
    case LWS_CALLBACK_EVENT_WAIT_CANCELLED:
        // Handled as first step of the function
        break
    case LWS_CALLBACK_WSI_DESTROY:
        guard let websocketClient else {
            return -1
        }
        websocketClient.websocket.withLockedValue({ $0 = nil })
    default:
        break
    }

//    if let websocketClient, websocketClient.isClosedForever {
        // If for whatever reason we get another callback after the connection being closed, close again.

        // THIS DOES NOT WORK

//        let closeReason = websocketClient.lwsCloseStatus.withLockedValue({ $0 }) ?? LWS_CLOSE_STATUS_GOINGAWAY
//
//        var dataPointer = ""
//        lws_close_reason(wsi, closeReason, &dataPointer, dataPointer.count)
//
//        return -1
//    }

    return 0
}

fileprivate var _defaultLwsUserPointer = "global-lws-user-default"
fileprivate var _closedLwsUserPointer = "global-lws-user-closed"
