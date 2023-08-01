import Clibwebsockets

public enum WebsocketScheme: String, Sendable {
    case ws = "ws"
    case wss = "wss"
}

public enum WebsocketOpcode: Sendable, Equatable {
    case binary
    case text
    case continuation
    case ping
    case close(reason: lws_close_status)

    func isClose() -> Bool {
        if case .close = self {
            return true
        }

        return false
    }
}
