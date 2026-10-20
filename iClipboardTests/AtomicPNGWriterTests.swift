import Darwin
import Foundation
import XCTest
@testable import iClipboard

final class AtomicPNGWriterTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func filenames(in directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    func testSameSecondExportsUseSequentialSuffixesAndPreserveExactExistingBytes() async throws {
        let directory = try directory()
        let name = "iclipboard_240102_030405.png"
        let originalURL = directory.appendingPathComponent(name)
        let original = Data([1, 2, 3])
        let second = Data(repeating: 0xA5, count: 1_100_005)
        let third = Data([9, 8, 7])
        try original.write(to: originalURL)

        let secondURL = try await AtomicPNGWriter.write(second, directory: directory, filename: name)
        let thirdURL = try await AtomicPNGWriter.write(third, directory: directory, filename: name)
        XCTAssertEqual(secondURL.lastPathComponent, "iclipboard_240102_030405_2.png")
        XCTAssertEqual(thirdURL.lastPathComponent, "iclipboard_240102_030405_3.png")
        XCTAssertEqual(try Data(contentsOf: originalURL), original)
        XCTAssertEqual(try Data(contentsOf: secondURL), second)
        XCTAssertEqual(try Data(contentsOf: thirdURL), third)
        XCTAssertEqual(try filenames(in: directory), [name, secondURL.lastPathComponent, thirdURL.lastPathComponent])
    }

    func testDirectPublicationConsumesTemporaryNameWithoutCreatingHardLinks() async throws {
        let directory = try directory()
        let data = Data(repeating: 0xA5, count: 130_001)
        let receipt = try await AtomicPNGWriter.write(data, directory: directory, filename: "result.png", afterPublication: { url in
            XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: directory.path), ["result.png"])
            var metadata = stat()
            XCTAssertEqual(lstat(url.path, &metadata), 0)
            XCTAssertEqual(metadata.st_nlink, 1, "Direct exports must not require a second hard link")
        })
        XCTAssertEqual(try Data(contentsOf: receipt), data)
    }

    func testConcurrentExportsNeverOverwriteAndEachReceiptContainsItsOwnCompleteBytes() async throws {
        let directory = try directory()
        let name = "iclipboard_240102_030405.png"
        let existing = directory.appendingPathComponent(name)
        let existingSecond = directory.appendingPathComponent("iclipboard_240102_030405_2.png")
        let sentinel = Data("keep existing".utf8)
        try sentinel.write(to: existing)
        try sentinel.write(to: existingSecond)
        let count = 24
        let receipts = try await withThrowingTaskGroup(of: (URL, Data).self) { group in
            for index in 0..<count {
                group.addTask {
                    let data = Data(repeating: UInt8(index), count: 130_001 + index)
                    let url = try await AtomicPNGWriter.write(data, directory: directory, filename: name)
                    return (url, data)
                }
            }
            var result: [(URL, Data)] = []
            for try await receipt in group { result.append(receipt) }
            return result
        }
        XCTAssertEqual(Set(receipts.map { $0.0 }).count, count)
        let expectedNames = Set((3..<(3 + count)).map { "iclipboard_240102_030405_\($0).png" })
        XCTAssertEqual(Set(receipts.map { $0.0.lastPathComponent }), expectedNames)
        for (url, data) in receipts { XCTAssertEqual(try Data(contentsOf: url), data) }
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertEqual(try Data(contentsOf: existingSecond), sentinel)
        XCTAssertEqual(try filenames(in: directory).count, count + 2)
    }

    func testCancellationBeforePublicationRemovesOnlyItsOwnTemporaryFile() async throws {
        let directory = try directory()
        let existing = directory.appendingPathComponent("result.png")
        let unrelatedTemporary = directory.appendingPathComponent(".iclipboard-existing.tmp")
        let sentinel = Data("keep".utf8)
        try sentinel.write(to: existing)
        try sentinel.write(to: unrelatedTemporary)
        let data = Data(repeating: 0x42, count: 1_200_003)
        let ready = expectation(description: "complete temporary file before publication")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let task = Task {
            try await AtomicPNGWriter.write(data, directory: directory, filename: "result.png", beforePublication: { temporary in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(try Data(contentsOf: temporary), data)
                XCTAssertEqual(temporary.deletingLastPathComponent(), directory)
                ready.fulfill()
                guard release.wait(timeout: .now() + 10) == .success else {
                    throw CocoaError(.userCancelled)
                }
            })
        }
        await fulfillment(of: [ready], timeout: 5)
        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("A cancellation before publication must not publish an output")
        } catch is CancellationError {
        }
        XCTAssertEqual(try filenames(in: directory), ["result.png", ".iclipboard-existing.tmp"])
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertEqual(try Data(contentsOf: unrelatedTemporary), sentinel)
    }

    func testCancellationAfterPublicationReturnsReceiptAndKeepsPublishedFile() async throws {
        let directory = try directory()
        let data = Data([137, 80, 78, 71, 255])
        let published = expectation(description: "published file")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let task = Task {
            try await AtomicPNGWriter.write(data, directory: directory, filename: "result.png", afterPublication: { url in
                XCTAssertEqual(try? Data(contentsOf: url), data)
                published.fulfill()
                _ = release.wait(timeout: .now() + 10)
            })
        }
        await fulfillment(of: [published], timeout: 5)
        task.cancel()
        release.signal()
        let receipt = try await task.value
        XCTAssertEqual(receipt.lastPathComponent, "result.png")
        XCTAssertEqual(try Data(contentsOf: receipt), data)
        XCTAssertEqual(try filenames(in: directory), ["result.png"])
    }

    func testFailureBeforePublicationCleansTemporaryAndLeavesExistingFileUntouched() async throws {
        let directory = try directory()
        let existing = directory.appendingPathComponent("result.png")
        let sentinel = Data("original".utf8)
        try sentinel.write(to: existing)
        do {
            _ = try await AtomicPNGWriter.write(Data([4, 5, 6]), directory: directory, filename: "result.png", beforePublication: { _ in
                throw CocoaError(.fileWriteOutOfSpace)
            })
            XCTFail("The injected filesystem failure must propagate")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileWriteOutOfSpace)
        }
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertEqual(try filenames(in: directory), ["result.png"])
    }

    func testMissingDirectoryIsNotCreatedAndRegularFileIsNotReplaced() async throws {
        let root = try directory()
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        do {
            _ = try await AtomicPNGWriter.write(Data([1]), directory: missing, filename: "result.png")
            XCTFail("A missing configured directory must fail")
        } catch let error as ImageSaveDirectoryError {
            XCTAssertEqual(error, .unavailable(missing))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        let file = root.appendingPathComponent("not-directory")
        let original = Data([9])
        try original.write(to: file)
        do {
            _ = try await AtomicPNGWriter.write(Data([1]), directory: file, filename: "result.png")
            XCTFail("A regular file must not become a directory")
        } catch let error as ImageSaveDirectoryError {
            XCTAssertEqual(error, .notDirectory(file))
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try filenames(in: root), ["not-directory"])
    }

    func testReadOnlyDirectoryFailsWithoutOutputOrFallback() async throws {
        let directory = try directory()
        XCTAssertEqual(chmod(directory.path, 0o555), 0)
        defer { chmod(directory.path, 0o755) }
        do {
            _ = try await AtomicPNGWriter.write(Data([1, 2]), directory: directory, filename: "result.png")
            XCTFail("Read-only directory must fail")
        } catch let error as ImageSaveDirectoryError {
            XCTAssertEqual(error, .notWritable(directory))
        }
        XCTAssertEqual(try filenames(in: directory), [])
    }

    func testConfirmedPanelReplacementWritesCompleteBytesAndLeavesNoTemporary() async throws {
        let directory = try directory()
        let existing = directory.appendingPathComponent("confirmed.png")
        try Data("old".utf8).write(to: existing)
        let data = Data(repeating: 0xC3, count: 2_100_003)
        let receipt = try await AtomicPNGWriter.replace(data, at: existing)
        XCTAssertEqual(receipt, existing)
        XCTAssertEqual(try Data(contentsOf: existing), data)
        XCTAssertEqual(try filenames(in: directory), ["confirmed.png"])
    }
}
