public enum WebsocketScheme: String, Sendable {
    case ws = "ws"
    case wss = "wss"
}

public enum WebsocketOpcode: String, Sendable {
    case binary = "binary"
    case text = "text"
    case continuation = "continuation"
    case ping = "ping"
}
