import libwebsockets
import Clibwebsockets
import NIOCore
import Foundation
import NIOConcurrencyHelpers
import NIOPosix

print("Running Echo Client")

let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
func createWebsocket() -> WebsocketClient {
    let connectionPromise = eventLoopGroup.next().makePromise(of: Void.self)

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
    let websocket = try! WebsocketClient(
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
        onConnect: connectionPromise
    )
    websocket.onClose { reason in
        print("Close \(reason)")
    }
    websocket.onFragment { client, data, a, b, c in
        print("Recv: \(data.count) bytes")
    }
    websocket.onBinary { ws, data in
        print("Received binary")
        print("\(data.count)")
    }
    websocket.onText { ws, text in
        print("Received text")
        print(text)
    }
    websocket.onPong { ws, data in
        print("pong received")
        print("\(data.count)")
    }

    _ = connectionPromise.futureResult.always { [weak websocket] result in
        guard let websocket else {
            return
        }

        switch result {
            case .failure(let err):
            print(err)
            case .success:
            print("Connection success")
            var longString = ""
            for _ in 0..<10 {
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

    return websocket
}
eventLoopGroup.next().scheduleTask(in: .seconds(5), {
    let ws = createWebsocket()
    eventLoopGroup.next().scheduleTask(in: .seconds(5), {
        _ = ws.isClosed
    })
})

RunLoop.main.run()
