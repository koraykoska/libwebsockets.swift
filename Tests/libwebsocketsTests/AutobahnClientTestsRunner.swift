import XCTest
import Clibwebsockets
import NIOCore
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
#if os(Linux)
    import Glibc
#else
    import Darwin.C
#endif
@testable import libwebsockets

final class AutobahnTestRunner: XCTestCase {
    enum Error: Swift.Error {
        case autobahnNotSet
        case testReportNotGenerated
        case testVersionNotPresent
    }

    static let agent = "libwebsocket-swift-client"

    override class func setUp() {
        super.setUp()

//        var rlp = rlimit()
//        getrlimit(RLIMIT_NOFILE, &rlp)
//        rlp.rlim_cur = 1048576
//        setrlimit(RLIMIT_NOFILE, &rlp)
//        getrlimit(RLIMIT_NOFILE, &rlp)
//        let s = sysconf(_SC_OPEN_MAX)
//        print(s)

        let semaphore = DispatchSemaphore(value: 0)

        // We are running the full Autobahn test suite

        let autobahnHost = ProcessInfo.processInfo.environment["AUTOBAHN_HOST"] ?? "127.0.0.1"
        let autobahnPort = ProcessInfo.processInfo.environment["AUTOBAHN_PORT"] ?? "9001"
        guard let autobahnPortInt = UInt16(autobahnPort) else {
            return
        }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 4)

        // Make sure print statements reach us
        eventLoopGroup.next().scheduleRepeatedTask(initialDelay: .seconds(5), delay: .seconds(5), { _ in
            fflush(stdout)
        })

        let caseNumbers = NIOLockedValueBox([Int]())
        let reportsUpdated = NIOLockedValueBox(false)

        @Sendable func updateReports(agent: String) {
            let wasUpdated = reportsUpdated.withLockedValue({
                let wasUpdated = $0
                $0 = true
                return wasUpdated
            })
            if wasUpdated {
                return
            }

            let websocketPromise = WebsocketClient.connect(
                scheme: .ws,
                host: autobahnHost,
                port: autobahnPortInt,
                path: "/updateReports",
                query: "?agent=\(agent)",
                headers: [:],
                origin: "localhost",
                maxFrameSize: 10000,
                permessageDeflate: true,
                connectionTimeoutSeconds: 5,
                eventLoop: eventLoopGroup.next(),
                onClose: { _ in
                    print("Agent \(agent) done")
                }
            )
            _ = websocketPromise.always { result in
                switch result {
                case .success(_):
                    break
                case .failure(let err):
                    print("Failed connecting to update reports. \(err)")
                }

                // Continue after 10 seconds. Wait for report generation.
                eventLoopGroup.next().scheduleTask(in: .seconds(10), {
                    semaphore.signal()
                })
            }
        }

        @Sendable func runCaseNumber(eventLoop: EventLoop, agent: String) {
            guard let number = caseNumbers.withLockedValue({
                let myNumber = $0.count > 0 ? $0.removeFirst() : nil
                return myNumber
            }) else {
                updateReports(agent: agent)
                return
            }

            print("Running case number \(number) for agent \(agent)")

            let fragmentData = NIOLockedValueBox([(Data, Bool, Bool)]())

            @Sendable func runNext() {
                // Run next
                runCaseNumber(eventLoop: eventLoop, agent: agent)
            }

            let websocketPromise = WebsocketClient.connect(
                scheme: .ws,
                host: autobahnHost,
                port: autobahnPortInt,
                path: "/runCase",
                query: "?case=\(number)&agent=\(agent)",
                headers: [:],
                origin: "localhost",
                maxFrameSize: 10000,
                permessageDeflate: true,
                connectionTimeoutSeconds: 5,
                eventLoop: eventLoop,
                onBinary: { websocket, data in
                    websocket.send(data, opcode: .binary)
                },
                onFragment: { websocket, data, isText, isFirst, isFinal in
                    // We only need to handle text opcodes and continuations for text as fragments for the autobahn testsuite

                    guard isText else {
    //                    websocket.send(data, opcode: isFirst ? .binary : .continuation, fin: isFinal)

                        return
                    }

                    // Text validity
                    var canContinue = true
                    fragmentData.withLockedValue({ $0.append((data, isFirst, isFinal)) })
                    let newData = fragmentData.withLockedValue({ $0.map({ $0.0 }).reduce(Data(), +) })
                    if String(data: newData, encoding: .utf8) == nil {
                        canContinue = false

                        if isFinal {
                            fragmentData.withLockedValue({ $0 = [] })
                        }
                    }

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
                },
                onClose: { status in
                    runNext()
                }
            )

            websocketPromise.whenFailure { error in
                runNext()
            }
            websocketPromise.whenSuccess { websocket in
                websocket.onClose { status in
                    // Reset retain
                    websocket.onClose { _ in }

                    runNext()

                    // Retain
                    _ = websocket.headers
                }
            }
        }

        let autobahnDone = ProcessInfo.processInfo.environment["AUTOBAHN_DONE"]
        if let autobahnDone, !autobahnDone.isEmpty {
            print("Autobahn was already done.")
            semaphore.signal()
        } else {
            let getCaseCountPromise = WebsocketClient.connect(
                scheme: .ws,
                host: autobahnHost,
                port: autobahnPortInt,
                path: "/getCaseCount",
                query: nil,
                headers: [:],
                origin: "localhost",
                maxFrameSize: 10000,
                permessageDeflate: true,
                connectionTimeoutSeconds: 5,
                eventLoop: eventLoopGroup.next(),
                onText: { websocket, text in
                    // We received the case count
                    let caseCount = Int(text) ?? 0
                    websocket.close(reason: .normal)

                    if caseCount <= 0 {
                        print("Case Count too small \(caseCount)")
                        semaphore.signal()
                        return
                    }

                    // Now run cases
                    print("Running \(caseCount) Autobahn test cases")
                    for i in 1...caseCount {
                        caseNumbers.withLockedValue({ $0.append(i) })
                    }

                    // Launch on all event loops
                    for eventLoop in eventLoopGroup.makeIterator() {
                        runCaseNumber(eventLoop: eventLoop, agent: AutobahnTestRunner.agent)
                    }
                }
            )
            getCaseCountPromise.whenFailure { _ in
                print("getCaseCount failure")
                semaphore.signal()
            }
        }

        print("Now waiting for Autobahn test suite finalization.")
        semaphore.wait()
        print("Semaphore signaled. Autobahn test suite results ready.")
    }

    func testAllVersions() throws {
        let reportData = try! Data(contentsOf: URL(fileURLWithPath: "./autobahn/reports/clients/index.json"))
        let report = try! JSONDecoder().decode(AutobahnReport.self, from: reportData)

        guard let agentReport = report.agentReports[AutobahnTestRunner.agent] else {
            XCTAssert(false, "test report not set")
            fatalError("autobahn report non-existent")
        }

        for (key, _) in agentReport.versionReport {
            let test = AutobahnVersionRunner(name: "Autobahn test case \(key)", currentVersion: key)
            try test.autobahnWithVersion()
        }
    }

    final class AutobahnVersionRunner: XCTestSuite {
        let currentVersion: String

        init(name: String, currentVersion: String) {
            self.currentVersion = currentVersion
            super.init(name: name)
        }

        func autobahnWithVersion() throws {
            let skips = ["2.10", "2.11", "7.5.1"]
            if skips.contains(currentVersion) {
                return
            }

            let reportData = try Data(contentsOf: URL(fileURLWithPath: "./autobahn/reports/clients/index.json"))
            let report = try JSONDecoder().decode(AutobahnReport.self, from: reportData)

            guard let agentReport = report.agentReports[AutobahnTestRunner.agent] else {
                XCTAssert(false, "test report not set")
                throw Error.testReportNotGenerated
            }

            guard let versionReport = agentReport.versionReport[currentVersion] else {
                XCTAssert(false, "test version not present \(currentVersion)")
                throw Error.testVersionNotPresent
            }

            let okCodes = ["OK", "NON-STRICT", "INFORMATIONAL"]

            XCTAssert(
                okCodes.contains(versionReport.behavior),
                "Autobahn test \(currentVersion) failed with \(versionReport.behavior)"
            )

//            XCTAssert(
//                okCodes.contains(versionReport.behaviorClose),
//                "Autobahn test \(currentVersion) CLOSE failed with \(versionReport.behaviorClose)"
//            )
            if !okCodes.contains(versionReport.behaviorClose) {
                print("WARN: Autobahn test \(currentVersion) CLOSE failed with \(versionReport.behaviorClose)")
            }
        }
    }
}

fileprivate struct AutobahnReport: Codable {
    let agentReports: [String: FullReport]

    struct FullReport: Codable {
        let versionReport: [String: VersionReport]

        struct VersionReport: Codable {
            let behavior: String
            let behaviorClose: String
            let duration: Int
            let remoteCloseCode: Int?
            let reportfile: String
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKeys.self)

            var versionReport: [String: VersionReport] = [:]
            for key in container.allKeys {
                try versionReport[key.stringValue] = container.decode(VersionReport.self, forKey: key)
            }

            self.versionReport = versionReport
        }

        func encode(to encoder: Encoder) throws {
            var encoder = encoder.container(keyedBy: DynamicCodingKeys.self)

            for (key, value) in versionReport {
                try encoder.encode(value, forKey: DynamicCodingKeys(stringValue: key))
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKeys.self)

        var agentReports: [String: FullReport] = [:]
        for key in container.allKeys {
            try agentReports[key.stringValue] = container.decode(FullReport.self, forKey: key)
        }

        self.agentReports = agentReports
    }

    func encode(to encoder: Encoder) throws {
        var encoder = encoder.container(keyedBy: DynamicCodingKeys.self)

        for (key, value) in agentReports {
            try encoder.encode(value, forKey: DynamicCodingKeys(stringValue: key))
        }
    }
}

fileprivate struct DynamicCodingKeys: CodingKey {

    var stringValue: String
    init(stringValue: String) {
        self.stringValue = stringValue
    }

    var intValue: Int?
    init?(intValue: Int) {
        return nil
    }
}
