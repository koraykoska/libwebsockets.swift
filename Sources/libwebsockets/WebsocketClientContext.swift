import Clibwebsockets
import Dispatch
import NIOCore
import NIOConcurrencyHelpers
import Foundation

internal final class WebsocketClientContext {
    /// Singleton context. Needs to be checked for nil and reinitialized if nil
    private static var _shared: [WebsocketClientContext]? = nil
    private static var _nextSharedContext = NIOLockedValueBox(0)
    private static let _sharedContextCreated = NIOLockedValueBox(false)

    /// Returns one of the global instances. Check for nil and fail whatever you do if nil.
    static func shared() -> WebsocketClientContext? {
        let wasCreated = _sharedContextCreated.withLockedValue({
            if $0 {
                return true
            }

            $0 = true
            return false
        })

        func nextShared() -> WebsocketClientContext? {
            let nextId = _nextSharedContext.withLockedValue({
                let nextToBeSet: Int
                if $0 >= (((_shared?.count) ?? 0) - 1) {
                    nextToBeSet = 0
                    $0 = 0
                } else {
                    nextToBeSet = $0 + 1
                    $0 += 1
                }

                return nextToBeSet
            })

            return _shared?[nextId]
        }

        if wasCreated {
            return nextShared()
        } else {
            if _shared != nil {
                return nextShared()
            }

            var shared: [WebsocketClientContext] = []
            for _ in 0..<System.coreCount {
                if let context = WebsocketClientContext() {
                    shared.append(context)
                }
            }
            if shared.count == System.coreCount {
                self._shared = shared
            }

            if _shared == nil {
                _sharedContextCreated.withLockedValue({ $0 = false })
                return nil
            } else {
                return nextShared()
            }
        }
    }

    // MARK: - Properties

    private let serviceQueue = DispatchQueue(label: "libwebsockets-swift-context-service")
    private let writableQueue = DispatchQueue(label: "libwebsockets-swift-context-writable")

    private let eventLoopExecutionCallbacks: NIOLockedValueBox<[() -> Void]> = .init([])
    private let fastServiceExecutionCallbacks: NIOLockedValueBox<[() -> Void]> = .init([])

    private var lwsContextCreationInfo: lws_context_creation_info!

    internal private(set) var lwsProtocols: lws_protocols!
    private let lwsProtocolName: ContiguousArray<CChar>
    private var lwsEmptyProtocol: lws_protocols!

    private var permessageDeflateExtension: lws_extension!
    private let permessageDeflateExtensionName: ContiguousArray<CChar>
    private let permessageDeflateExtensionHeader: ContiguousArray<CChar>
    private var emptyExtension: lws_extension!

    private let protocolsPointer: UnsafeMutablePointer<lws_protocols>
    private let extensionsPointer: UnsafeMutablePointer<lws_extension>

    private var repeatedServiceScheduleSourceTimer: DispatchSourceTimer? = nil

    internal private(set) var context: OpaquePointer!

    // See: https://stackoverflow.com/questions/61236195/create-a-weak-unsafemutablerawpointer?rq=3
    internal class WeakSelf {
        internal weak var weakSelf: WebsocketClientContext?

        fileprivate init(weakSelf: WebsocketClientContext) {
            self.weakSelf = weakSelf
        }
    }
    private let selfPointer: UnsafeMutablePointer<WeakSelf>

    // MARK: - Initialization

    private init?() {
        //        lws_set_log_level(1151, nil)
        lws_set_log_level(0, nil)

        protocolsPointer = UnsafeMutablePointer<lws_protocols>.allocate(capacity: 2)
        extensionsPointer = UnsafeMutablePointer<lws_extension>.allocate(capacity: 2)
        permessageDeflateExtensionName = "permessage-deflate".utf8CString
        permessageDeflateExtensionHeader = "permessage-deflate; client_max_window_bits".utf8CString
        lwsProtocolName = "libwebsockets-protocol".utf8CString

        // Context Creation Info
        lwsContextCreationInfo = lws_context_creation_info()
        lws_context_creation_info_zero(&lwsContextCreationInfo)
        lwsContextCreationInfo.port = CONTEXT_PORT_NO_LISTEN
        lwsContextCreationInfo.options = UInt64(LWS_SERVER_OPTION_DO_SSL_GLOBAL_INIT)
        // TODO: Per instance customization?
        lwsContextCreationInfo.timeout_secs = 10

        // self pointer
        selfPointer = UnsafeMutablePointer<WeakSelf>.allocate(capacity: 1)
        selfPointer.initialize(to: .init(weakSelf: self))
        // Set a pointer back to self for communication from thr callback to the instance.
        lwsContextCreationInfo.user = UnsafeMutableRawPointer(selfPointer)

        // Protocols
        lwsProtocols = lws_protocols()
        lws_protocols_zero(&lwsProtocols)
        lwsProtocols.name = lwsProtocolName.toCPointer()
        lwsProtocols.callback = _lws_swift_websocketClientCallback
        lwsProtocols.per_session_data_size = 0
        // TODO: Per instance customization?
        lwsProtocols.rx_buffer_size = 50000

        protocolsPointer.initialize(to: lwsProtocols)

        lwsEmptyProtocol = lws_protocols()
        lws_protocols_zero(&lwsEmptyProtocol)
        lwsEmptyProtocol.name = nil
        lwsEmptyProtocol.callback = nil
        lwsEmptyProtocol.per_session_data_size = 0
        lwsEmptyProtocol.rx_buffer_size = 0

        protocolsPointer.advanced(by: 1).initialize(to: lwsEmptyProtocol)
        // END Protocols

        // Extensions
        permessageDeflateExtension = lws_extension()
        lws_extension_zero(&permessageDeflateExtension)
        permessageDeflateExtension.name = permessageDeflateExtensionName.toCPointer()
        permessageDeflateExtension.callback = lws_extension_callback_pm_deflate
        permessageDeflateExtension.client_offer = permessageDeflateExtensionHeader.toCPointer()

        extensionsPointer.initialize(to: permessageDeflateExtension)

        emptyExtension = lws_extension()
        lws_extension_zero(&emptyExtension)
        emptyExtension.name = nil
        emptyExtension.callback = nil
        emptyExtension.client_offer = nil

        extensionsPointer.advanced(by: 1).initialize(to: emptyExtension)
        // END Extensions

        lwsContextCreationInfo.protocols = UnsafePointer(protocolsPointer)
        lwsContextCreationInfo.extensions = UnsafePointer(extensionsPointer)
        // Below sets guid and uid to -1. Swift doesn't detect signed int correctly. No idea why.
        ws_set_guiduid(&lwsContextCreationInfo)
        // We did the below before but it was not always correct due to different int sizes.
//        lwsContextCreationInfo.gid = 0xffffffff
//        lwsContextCreationInfo.uid = 0xffffffff

        // END Context Creation Info

        let retValue = serviceQueue.sync { () -> OpaquePointer? in
            // Context
            guard let context = lws_create_context(&lwsContextCreationInfo) else {
                return nil
            }

            return context
        }
        guard let retValue else {
            return nil
        }
        self.context = retValue

        // Polling of Events, including connection success
        scheduleServiceCall()

        // Repeated service calls if necessary
        repeatedServiceScheduleSourceTimer = DispatchSource.makeTimerSource(queue: writableQueue)
        repeatedServiceScheduleSourceTimer?.schedule(deadline: .now(), repeating: .seconds(1))
        repeatedServiceScheduleSourceTimer?.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            if self.fastServiceExecutionCallbacks.withLockedValue({ $0.count }) > 0 ||
                self.eventLoopExecutionCallbacks.withLockedValue({ $0.count }) > 0 {
                self.forceCancelService()
            }
        }
        repeatedServiceScheduleSourceTimer?.resume()
    }

    deinit {
        // Stop repeated service timer
        repeatedServiceScheduleSourceTimer?.cancel()

        // Destroy context. User nullify necessary to prevent segfault in future callbacks.
        ws_context_user_nullify(context)
        lws_context_destroy(context)

        protocolsPointer.deinitialize(count: 2)
        protocolsPointer.deallocate()

        extensionsPointer.deinitialize(count: 2)
        extensionsPointer.deallocate()

        // After everything is destroyed
        selfPointer.deinitialize(count: 1)
        selfPointer.deallocate()
    }

    // MARK: - Helpers

    private func scheduleServiceCall() {
        serviceQueue.async { [weak self] in
            //  !isClosedForever
            guard let self, let context = self.context else {
                return
            }

            // This lws_service call blocks until the next event1
            // arrives. The 250ms is ignored since the newest version.
            lws_service(context, 250)

            while let callback = self.fastServiceExecutionCallbacks.withLockedValue({
                let next = $0.count > 0 ? $0.removeFirst() : nil
                return next
            }) {
                callback()
            }

            self.scheduleServiceCall()
        }
    }

    private func forceCancelService() {
        lws_cancel_service(context)
    }

    // MARK: - API

    func callWritable(wsi: OpaquePointer!) {
        _ = writableQueue.sync {
            lws_callback_on_writable(wsi)
        }
    }

    func scheduleFastServiceExecution(_ callback: @escaping () -> Void) {
        fastServiceExecutionCallbacks.withLockedValue({ $0.append(callback) })
        forceCancelService()
    }

    func scheduleEventLoopExecution(_ wsi: OpaquePointer!, _ callback: @escaping () -> Void) {
        eventLoopExecutionCallbacks.withLockedValue({ $0.append(callback) })
        // Call Writable is faster and we prevent calling every websocket callbacks.
        callWritable(wsi: wsi)
    }

    func popEventLoopExecution() -> (() -> Void)? {
        return eventLoopExecutionCallbacks.withLockedValue({
            let nextElement = $0.count > 0 ? $0.removeFirst() : nil
            return nextElement
        })
    }
}
