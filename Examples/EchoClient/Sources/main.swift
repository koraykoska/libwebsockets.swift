import libwebsockets
import Clibwebsockets
import NIOCore
import Foundation
import NIOConcurrencyHelpers
import NIOPosix

print("Running Echo Client")

class TestClass {
init() {
print("init")
}

deinit {
print("deinit")
}
}

let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
func createWebsocket() -> WebsocketClient {
    let connectionPromise = eventLoopGroup.next().makePromise(of: Void.self)

    let websocket = try! WebsocketClient(
        scheme: .ws,
        host: "127.0.0.1",
        port: 10000,
        path: "/",
        query: nil,
        headers: [:],
        origin: "localhost",
        maxFrameSize: 10000,
        connectionTimeoutSeconds: 5,
        onConnect: connectionPromise
    )

    _ = connectionPromise.futureResult.always { [weak websocket] result in
        guard let websocket else {
            return
        }

        switch result {
            case .failure(let err):
            print(err)
            case .success:
            print("Connection success")
            websocket.send("HELLO!".data(using: .utf8)!, opcode: .binary)
        }
    }

    return websocket
}
eventLoopGroup.next().scheduleTask(in: .seconds(5), {
    var ws = createWebsocket()
    eventLoopGroup.next().scheduleTask(in: .seconds(5), {
        ws.close(reason: LWS_CLOSE_STATUS_NORMAL)
        ws = createWebsocket()
    })
})

RunLoop.main.run()
