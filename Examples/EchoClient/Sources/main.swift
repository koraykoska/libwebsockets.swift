import libwebsockets
import Clibwebsockets
import NIOCore
import Foundation
import NIOConcurrencyHelpers
import NIOPosix

print("Running Echo Client")

/*
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
        maxFrameSize: 10000,
        permessageDeflate: true,
        connectionTimeoutSeconds: 5,
        eventLoop: eventLoopGroup.next(),
        onConnect: connectionPromise
    )
    websocket.onClose { reason in
        print("Close \(reason)")
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
            websocket.send("HELLO!".data(using: .utf8)!, opcode: .text)
            websocket.send("HELLO!!".data(using: .utf8)!, opcode: .text)
            websocket.send("HELLO!!!".data(using: .utf8)!, opcode: .text)
            websocket.send("HELLO!!!!".data(using: .utf8)!, opcode: .text)
//            websocket.close(reason: LWS_CLOSE_STATUS_NORMAL)
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
*/

let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

func updateReports(agent: String) {
    let promise = eventLoopGroup.next().makePromise(of: Void.self)
    let websocket = try! WebsocketClient(
        scheme: .ws,
        host: "127.0.0.1",
        port: 9001,
        path: "/updateReports?agent=\(agent)",
        query: nil,
        headers: [:],
        origin: "localhost",
        maxFrameSize: 10000,
        permessageDeflate: true,
        connectionTimeoutSeconds: 5,
        eventLoop: eventLoopGroup.next(),
        onConnect: promise
    )
    websocket.onText { websocket, text in
        print("Agent \(agent) done")
        websocket.close(reason: LWS_CLOSE_STATUS_NORMAL)
    }
}

func runCaseNumber(number: Int, upTo: Int, agent: String) {
    print("Running case number \(number) for agent \(agent)")

    let promise = eventLoopGroup.next().makePromise(of: Void.self)
    let websocket = try! WebsocketClient(
        scheme: .ws,
        host: "127.0.0.1",
        port: 9001,
        path: "/runCase?case=\(number)&agent=\(agent)",
        query: nil,
        headers: [:],
        origin: "localhost",
        maxFrameSize: 10000,
        permessageDeflate: true,
        connectionTimeoutSeconds: 5,
        eventLoop: eventLoopGroup.next(),
        onConnect: promise
    )
    @Sendable func runNext() {
        if number < upTo {
            runCaseNumber(number: number + 1, upTo: upTo, agent: agent)
        } else {
            updateReports(agent: agent)
        }

        // Reset retain
        websocket.onClose { _ in }
    }
    promise.futureResult.whenFailure { error in
        runNext()
    }
    websocket.onClose { status in
        runNext()

        // Retain
        _ = websocket.headers
    }

    let fragmentData = NIOLockedValueBox([(Data, Bool, Bool)]())
    websocket.onFragment { websocket, data, isText, isFirst, isFinal in
        print("Case \(number) incoming \(isText ? "text" : "binary") fragment")

        // Text validity
        var canContinue = true
        if isText {
            fragmentData.withLockedValue({ $0.append((data, isFirst, isFinal)) })
            let newData = fragmentData.withLockedValue({ $0.map({ $0.0 }).reduce(Data(), +) })
            if String(data: newData, encoding: .utf8) == nil {
                canContinue = false

                if isFinal {
                    fragmentData.withLockedValue({ $0 = [] })
                }
            }
        }

        let opcode: WebsocketOpcode
        if isFirst {
            opcode = isText ? .text : .binary
        } else {
            opcode = .continuation
        }

        if isText {
            if canContinue {
                let fragments = fragmentData.withLockedValue({
                    let data = $0
                    $0 = []
                    return data
                })
                if fragments.count > 0 {
                    let newData = fragments.map({ $0.0 }).reduce(Data(), +)
                    websocket.send(newData, opcode: fragments[0].1 ? .text : .continuation, fin: fragments[fragments.count - 1].2)
                }
            }
        } else {
            websocket.send(data, opcode: opcode, fin: isFinal)
        }
    }

//    websocket.onText { websocket, text in
//        print("Case \(number) closed with text")
//        let donePromise = eventLoopGroup.next().makePromise(of: Void.self)
//        websocket.send(text.data(using: .utf8)!, opcode: .text, promise: donePromise)
//        donePromise.futureResult.whenSuccess {
////            websocket.close(reason: LWS_CLOSE_STATUS_NORMAL)
//        }
//    }
//    websocket.onBinary { websocket, data in
//        print("Case \(number) closed with binary")
//        let donePromise = eventLoopGroup.next().makePromise(of: Void.self)
//        websocket.send(data, opcode: .binary, promise: donePromise)
//        donePromise.futureResult.whenSuccess {
////            websocket.close(reason: LWS_CLOSE_STATUS_NORMAL)
//        }
//    }
}

let getCaseCountPromise = eventLoopGroup.next().makePromise(of: Void.self)
let getCaseCount = try! WebsocketClient(
    scheme: .ws,
    host: "127.0.0.1",
    port: 9001,
    path: "/getCaseCount",
    query: nil,
    headers: [:],
    origin: "localhost",
    maxFrameSize: 10000,
    permessageDeflate: true,
    connectionTimeoutSeconds: 5,
    eventLoop: eventLoopGroup.next(),
    onConnect: getCaseCountPromise
)
getCaseCount.onText { websocket, text in
    // We received the case count
    let caseCount = Int(text) ?? 0
    websocket.close(reason: LWS_CLOSE_STATUS_NORMAL)

    if caseCount <= 0 {
        print("Case Count too small \(caseCount)")
        return
    }

    // Now run cases
    runCaseNumber(number: 1, upTo: caseCount, agent: "libwebsocket-swift-client")
}
getCaseCountPromise.futureResult.whenSuccess {
}
getCaseCountPromise.futureResult.whenFailure { _ in
    print("getCaseCount failure")
}

RunLoop.main.run()
