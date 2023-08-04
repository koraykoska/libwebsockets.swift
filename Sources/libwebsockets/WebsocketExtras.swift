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
    case close(reason: WebsocketCloseStatus)

    func isClose() -> Bool {
        if case .close = self {
            return true
        }

        return false
    }
}

public enum WebsocketCloseStatus: UInt32, Sendable {
    case unknownDoNotUse = 0

    case normal = 1000
    case goingAway = 1001
    case protocolError = 1002
    case unacceptableOpcode = 1003
    case reserved = 1004
    case noStatus = 1005
    case abnormalClose = 1006
    case invalidPayload = 1007
    case policyViolation = 1008
    case messageTooLarge = 1009
    case extensionRequired = 1010
    case unexpectedCondition = 1011
    case tlsFailure = 1015
    case clientTransactionDone = 2000
    case noStatusContextDestroy = 9999

    public init(fromLwsCloseStatus closeStatus: lws_close_status) {
        if let status = WebsocketCloseStatus(rawValue: closeStatus.rawValue) {
            self = status
        } else {
            self = .unknownDoNotUse
        }
    }

    public func toLwsCloseStatus() -> lws_close_status {
        return lws_close_status(self.rawValue)
    }
}
