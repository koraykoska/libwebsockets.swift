public enum WebsocketScheme: String {
    case ws = "ws"
    case wss = "wss"
}

public enum WebsocketOpcode: String {
    case binary = "binary"
    case text = "text"
    case continuation = "continuation"
    case ping = "ping"
}
