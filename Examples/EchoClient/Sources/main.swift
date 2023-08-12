import libwebsockets
import Clibwebsockets
import NIOCore
import Foundation
import NIOConcurrencyHelpers
import NIOPosix

print("Running Echo Client")

let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
func createWebsocket() -> EventLoopFuture<WebsocketClient> {
//    let websocket = try! WebsocketClient(
//        scheme: .wss,
//        host: "ws.postman-echo.com",
//        port: 443,
//        path: "/raw",
//        query: nil,
//        headers: [:],
//        origin: "localhost",
//        maxFrameSize: 10000,
//        connectionTimeoutSeconds: 5,
//        eventLoop: eventLoopGroup.next(),
//        onConnect: connectionPromise
//    )
    let websocketPromise = WebsocketClient.connect(
        scheme: .ws,
        host: "127.0.0.1",
        port: 10000,
        path: "/",
        query: nil,
        headers: [:],
        origin: "localhost",
        maxFrameSize: 100,
        maxMessageSize: 1000,
        permessageDeflate: true,
        connectionTimeoutSeconds: 5,
        eventLoop: eventLoopGroup.next(),
        onText: { ws, text in
            print("Received text")
            print(text)
        },
        onBinary: { ws, data in
            print("Received binary")
            print("\(data.count)")
        },
        onFragment: { client, data, a, b, c in
            print("Recv: \(data.count) bytes")
        },
        onPong: { ws, data in
            print("pong received")
            print("\(data.count)")
        },
        onClose: { reason in
            print("Close \(reason)")
        }
    )
    return websocketPromise.always { result in
        switch result {
            case .failure(let err):
            print(err)
            case .success(let websocket):
            print("Connection success")
            var longString = ""
            for _ in 0..<30 {
                longString += "\(UUID().uuidString)"
            }
            websocket.send(longString.data(using: .utf8)!, opcode: .text)
            websocket.send("HELLO!".data(using: .utf8)!, opcode: .text)
            websocket.send("HELLO!!".data(using: .utf8)!, opcode: .text)
            websocket.send("HELLO!!!".data(using: .utf8)!, opcode: .text)
            websocket.send("HELLO!!!!".data(using: .utf8)!, opcode: .text)
//            websocket.close(reason: .normal)
//            websocket.send("BINHELLO!".data(using: .utf8)!, opcode: .binary)
//            websocket.send("H".data(using: .utf8)!, opcode: .text, fin: false)
//            websocket.send("E".data(using: .utf8)!, opcode: .continuation, fin: false)
//            websocket.send("L".data(using: .utf8)!, opcode: .continuation, fin: false)
//            websocket.send("L".data(using: .utf8)!, opcode: .continuation, fin: false)
//            websocket.send("O".data(using: .utf8)!, opcode: .continuation, fin: false)
//            websocket.send("!".data(using: .utf8)!, opcode: .continuation, fin: true)
//            websocket.send(Data(), opcode: .ping)
        }
    }
}
eventLoopGroup.next().scheduleTask(in: .seconds(5), {
    createWebsocket().always { result in
        switch result {
        case .success(let ws):
            eventLoopGroup.next().scheduleTask(in: .seconds(5), {
                _ = ws.isClosed
            })
        default:
            break
        }
    }
})

RunLoop.main.run()
