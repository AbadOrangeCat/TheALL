import Foundation
import XCTest
@testable import TheAll

/// Uses only local Python children and synthetic image bytes; no CLI/API/network.
final class AIChatProcessPhotoTests: XCTestCase {
    private func configuration(_ script: String) -> AILaunchConfiguration {
        AILaunchConfiguration(command: "unused", environment: [:], executable: "/usr/bin/python3", arguments: ["-c", script])
    }

    func testLargePhotoLineDoesNotBlockMainQueueAndArrivesIntact() throws {
        let pipe = AIChatProcess()
        defer { pipe.stop() }
        let received = expectation(description: "four intact photos")
        let written = expectation(description: "write completion")
        let responsive = expectation(description: "main queue remains responsive")
        var completions = 0
        let image = Data(repeating: 0xa5, count: 2 * 1_024 * 1_024).base64EncodedString()
        pipe.onMessage = { value in
            XCTAssertEqual(value["lengths"] as? [Int], Array(repeating: 2 * 1_024 * 1_024, count: 4))
            XCTAssertEqual(value["intact"] as? Bool, true)
            XCTAssertEqual(value["text"] as? String, "照片 🐈")
            received.fulfill()
        }
        try pipe.start(configuration("""
        import base64,json,sys,time
        time.sleep(1.5)
        message=json.loads(sys.stdin.buffer.readline())
        images=[base64.b64decode(item['source']['data']) for item in message['content']]
        print(json.dumps({'lengths':[len(image) for image in images],
          'intact':all(image == bytes([165]) * (2*1024*1024) for image in images),
          'text':message['text']}),flush=True)
        """), directory: "/tmp")
        let start = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
            responsive.fulfill()
        }
        try pipe.send(["text": "照片 🐈", "content": (0..<4).map { _ in ["type": "image", "source": ["data": image]] }]) { result in
            XCTAssertTrue(Thread.isMainThread)
            if case .failure(let error) = result { XCTFail("Unexpected write failure: \(error)") }
            completions += 1
            written.fulfill()
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        wait(for: [responsive, written, received], timeout: 8)
        XCTAssertEqual(completions, 1)
    }

    func testQueuedAndLegacySendsRemainWholeAndOrdered() throws {
        let pipe = AIChatProcess()
        defer { pipe.stop() }
        let received = expectation(description: "ordered JSON lines")
        let written = expectation(description: "ordered completions")
        written.expectedFulfillmentCount = 6
        var order: [Int] = []
        pipe.onMessage = { value in
            XCTAssertEqual(value["order"] as? [Int], Array(0..<7))
            XCTAssertEqual(value["lengths"] as? [Int], Array(repeating: 262_144, count: 7))
            received.fulfill()
        }
        try pipe.start(configuration("""
        import json,sys,time
        time.sleep(.2)
        messages=[json.loads(sys.stdin.buffer.readline()) for _ in range(7)]
        print(json.dumps({'order':[m['index'] for m in messages],'lengths':[len(m['text']) for m in messages]}),flush=True)
        """), directory: "/tmp")
        let text = String(repeating: "x", count: 262_144)
        for index in 0..<7 {
            if index == 3 { try pipe.send(["index": index, "text": text]); continue }
            try pipe.send(["index": index, "text": text]) { result in
                if case .failure(let error) = result { XCTFail("Unexpected write failure: \(error)") }
                order.append(index); written.fulfill()
            }
        }
        wait(for: [written, received], timeout: 5)
        XCTAssertEqual(order, [0, 1, 2, 4, 5, 6])
    }

    func testStopSettlesAllQueuedWritesOnceAndRestartIsIndependent() throws {
        let pipe = AIChatProcess()
        defer { pipe.stop() }
        let cancelled = expectation(description: "old writes cancelled")
        cancelled.expectedFulfillmentCount = 3
        let replied = expectation(description: "new process reply")
        let written = expectation(description: "new process write")
        var counts = [0, 0, 0]
        var exits = 0
        pipe.onExit = { _ in exits += 1 }
        try pipe.start(configuration("import time; time.sleep(5)"), directory: "/tmp")
        for index in 0..<3 {
            try pipe.send(["index": index, "photo": String(repeating: "A", count: 4 * 1_024 * 1_024)]) { result in
                XCTAssertTrue(Thread.isMainThread)
                if case .success = result { XCTFail("Stopped write unexpectedly completed") }
                counts[index] += 1; cancelled.fulfill()
            }
        }
        let start = Date()
        pipe.stop()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        pipe.onMessage = { message in
            XCTAssertEqual(message["new"] as? Bool, true)
            replied.fulfill()
        }
        try pipe.start(configuration("import sys,time; print(sys.stdin.readline(),end='',flush=True); time.sleep(2)"), directory: "/tmp")
        try pipe.send(["new": true]) { result in
            if case .failure(let error) = result { XCTFail("Restart failed: \(error)") }
            written.fulfill()
        }
        wait(for: [cancelled, written, replied], timeout: 5)
        XCTAssertEqual(counts, [1, 1, 1])
        XCTAssertEqual(exits, 0, "Old process callbacks must not exit the new process")
    }

    func testClosedInputFailsPendingWritesWithoutSIGPIPEOrHanging() throws {
        let pipe = AIChatProcess()
        defer { pipe.stop() }
        let ready = expectation(description: "child closed input")
        let completed = expectation(description: "both writes settled")
        completed.expectedFulfillmentCount = 2
        let exited = expectation(description: "failed process exited")
        var order: [String] = []
        pipe.onMessage = { _ in ready.fulfill() }
        pipe.onExit = { _ in order.append("exit"); exited.fulfill() }
        try pipe.start(configuration("import os,time; os.close(0); print('{\"ready\":true}',flush=True); time.sleep(2)"), directory: "/tmp")
        wait(for: [ready], timeout: 3)
        // Queue both before the background writer can report failure to main.
        for index in 0..<2 {
            do {
                try pipe.send(["photo": String(repeating: "A", count: 1_024 * 1_024)]) { result in
                    if case .success = result { XCTFail("Closed input accepted a write") }
                    order.append("completion\(index)"); completed.fulfill()
                }
            } catch {
                // An already observed EPIPE is also a valid pre-admission rejection.
                order.append("rejected\(index)"); completed.fulfill()
            }
        }
        wait(for: [completed, exited], timeout: 5)
        XCTAssertEqual(order.last, "exit")
    }

    func testTimeoutCancelsWholeQueueBeforeExit() throws {
        let pipe = AIChatProcess(writeTimeout: 0.2)
        defer { pipe.stop() }
        let completed = expectation(description: "all timed out writes settled")
        completed.expectedFulfillmentCount = 2
        let exited = expectation(description: "timeout exits")
        var order: [String] = []
        pipe.onExit = { _ in order.append("exit"); exited.fulfill() }
        try pipe.start(configuration("import time; time.sleep(5)"), directory: "/tmp")
        for index in 0..<2 {
            try pipe.send(["photo": String(repeating: "A", count: 1_024 * 1_024)]) { result in
                if case .success = result { XCTFail("Non-reading child accepted a full photo") }
                order.append("completion\(index)"); completed.fulfill()
            }
        }
        wait(for: [completed, exited], timeout: 3)
        XCTAssertEqual(order, ["completion0", "completion1", "exit"])
    }

    func testNaturalExitSettlesPendingWritesBeforeExitCallback() throws {
        let pipe = AIChatProcess()
        defer { pipe.stop() }
        let completed = expectation(description: "all writes settled after child exit")
        completed.expectedFulfillmentCount = 2
        let exited = expectation(description: "child exited without reading")
        var order: [String] = []
        pipe.onExit = { _ in order.append("exit"); exited.fulfill() }
        try pipe.start(configuration("import time; time.sleep(.2)"), directory: "/tmp")
        for index in 0..<2 {
            try pipe.send(["photo": String(repeating: "A", count: 1_024 * 1_024)]) { result in
                if case .success = result { XCTFail("Child never read the photo") }
                order.append("completion\(index)"); completed.fulfill()
            }
        }
        wait(for: [completed, exited], timeout: 3)
        XCTAssertEqual(order, ["completion0", "completion1", "exit"])
    }

    func testPerMessageAndPendingLimitsRejectBeforeAdmission() throws {
        let pipe = AIChatProcess()
        defer { pipe.stop() }
        let cancelled = expectation(description: "admitted requests cancelled")
        cancelled.expectedFulfillmentCount = 2
        try pipe.start(configuration("import time; time.sleep(5)"), directory: "/tmp")
        var rejectedCallbacks = 0
        XCTAssertThrowsError(try pipe.send(["photo": String(repeating: "A", count: AIChatProcess.maximumMessageBytes)]) { _ in rejectedCallbacks += 1 })
        let message = ["photo": String(repeating: "B", count: 12 * 1_024 * 1_024)]
        for _ in 0..<2 {
            try pipe.send(message) { result in
                if case .success = result { XCTFail("Non-reading child accepted a full photo") }
                cancelled.fulfill()
            }
        }
        XCTAssertThrowsError(try pipe.send(message) { _ in rejectedCallbacks += 1 })
        XCTAssertThrowsError(try pipe.send(["invalid": Date()]) { _ in rejectedCallbacks += 1 })
        pipe.stop()
        wait(for: [cancelled], timeout: 3)
        XCTAssertEqual(rejectedCallbacks, 0)
    }

    func testFastEchoExitAlwaysFollowsSuccessfulWriteCompletion() throws {
        // Repetition exercises the output/termination/write queues racing.
        for iteration in 0..<12 {
            let pipe = AIChatProcess()
            let exited = expectation(description: "fast child \(iteration) exited")
            var events: [String] = []
            pipe.onExit = { _ in events.append("exit"); exited.fulfill() }
            try pipe.start(configuration("import sys; print(sys.stdin.readline(),end='',flush=True)"), directory: "/tmp")
            try pipe.send(["iteration": iteration, "text": String(repeating: "A", count: 128 * 1_024)]) { result in
                if case .failure(let error) = result { XCTFail("Completed child read failed: \(error)") }
                events.append("written")
            }
            wait(for: [exited], timeout: 4)
            XCTAssertEqual(events, ["written", "exit"])
            pipe.stop()
        }
    }
}
