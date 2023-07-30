import libwebsockets
import NIOCore
import Foundation
import NIOConcurrencyHelpers
import NIOPosix

print("Running Echo Client")

let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

_ = connectionPromise.futureResult.always { result in
    switch result {
        case .failure(let err):
        print(err)
        case .success:
        print("Connection success")
        websocket.send("HELLO!".data(using: .utf8)!, opcode: .binary)
    }
}

sleep(15)
