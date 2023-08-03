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

        let semaphore = DispatchSemaphore(value: 0)

        // We are running the full Autobahn test suite

        guard let autobahnHost = ProcessInfo.processInfo.environment["AUTOBAHN_HOST"],
              let autobahnPort = ProcessInfo.processInfo.environment["AUTOBAHN_PORT"],
              let autobahnPortInt = UInt16(autobahnPort)
        else {
            return
        }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        // Make sure print statements reach us
        eventLoopGroup.next().scheduleRepeatedTask(initialDelay: .seconds(5), delay: .seconds(5), { _ in
            fflush(stdout)
        })

        @Sendable func updateReports(agent: String) {
            let promise = eventLoopGroup.next().makePromise(of: Void.self)
            let websocket = try! WebsocketClient(
                scheme: .ws,
                host: autobahnHost,
                port: autobahnPortInt,
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
            websocket.onClose { _ in
                print("Agent \(agent) done")
            }

            // Continue after 10 seconds. Wait for report generation.
            eventLoopGroup.next().scheduleTask(in: .seconds(10), {
                semaphore.signal()
            })
        }

        @Sendable func runCaseNumber(number: Int, upTo: Int, agent: String) {
            print("Running case number \(number) for agent \(agent)")

            let promise = eventLoopGroup.next().makePromise(of: Void.self)
            let websocket = try! WebsocketClient(
                scheme: .ws,
                host: autobahnHost,
                port: autobahnPortInt,
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
                // We only need to handle text opcodes and continuations for text as fragments for the autobahn testsuite

                guard isText else {
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
            }

            websocket.onBinary { websocket, data in
                websocket.send(data, opcode: .binary)
            }
        }

        let autobahnDone = ProcessInfo.processInfo.environment["AUTOBAHN_DONE"]
        if let autobahnDone, !autobahnDone.isEmpty {
            print("Autobahn was already done.")
            semaphore.signal()
        } else {
            let getCaseCountPromise = eventLoopGroup.next().makePromise(of: Void.self)
            let getCaseCount = try! WebsocketClient(
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
                print("Running \(caseCount) Autobahn test cases")
                runCaseNumber(number: 1, upTo: caseCount, agent: AutobahnTestRunner.agent)
            }
            getCaseCountPromise.futureResult.whenSuccess {
            }
            getCaseCountPromise.futureResult.whenFailure { _ in
                print("getCaseCount failure")
            }
        }

        print("Now waiting for Autobahn test suite finalization.")
        semaphore.wait()
        print("Semaphore signaled. Autobahn test suite results ready.")
    }

    override class var defaultTestSuite: XCTestSuite {
        let suite = XCTestSuite(forTestCaseClass: AutobahnTestRunner.self)

        let reportData = try! Data(contentsOf: URL(fileURLWithPath: "./autobahn/reports/clients/index.json"))
        let report = try! JSONDecoder().decode(AutobahnReport.self, from: reportData)

        guard let agentReport = report.agentReports[AutobahnTestRunner.agent] else {
            XCTAssert(false, "test report not set")
            fatalError("autobahn report non-existent")
        }

        for (key, _) in agentReport.versionReport {
            // Generate a test for our specific selector
            let test = AutobahnTestRunner(selector: #selector(autobahnWithVersion))

            // Each test will take the size argument and use the instance variable in the test
            test.currentVersion = key

            // Add it to the suite, and the defaults handle the rest
            suite.addTest(test)
        }

        return suite
    }

    var currentVersion: String!

    @objc func autobahnWithVersion() throws {
        let skips = ["2.10", "7.5.1"]
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
            XCTAssert(false, "test version not present \(currentVersion!)")
            throw Error.testVersionNotPresent
        }

        let okCodes = ["OK", "NON-STRICT", "INFORMATIONAL"]

        XCTAssert(
            okCodes.contains(versionReport.behavior),
            "Autobahn test \(currentVersion!) failed with \(versionReport.behavior)"
        )

        XCTAssert(
            okCodes.contains(versionReport.behaviorClose),
            "Autobahn test \(currentVersion!) CLOSE failed with \(versionReport.behaviorClose)"
        )
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
