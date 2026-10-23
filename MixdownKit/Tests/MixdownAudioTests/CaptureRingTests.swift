import Foundation
import Testing

@testable import MixdownAudio

struct CaptureRingTests {
    @Test func readsCyclesInOrder() {
        let ring = CaptureRing(capacity: 1024)
        #expect(Self.write([1, 2, 3], generation: 0, to: ring))
        #expect(Self.write([4, 5], generation: 1, hostTime: 99, to: ring))

        #expect(
            Self.readAll(from: ring) == [
                Read(values: [1, 2, 3], generation: 0, hostTime: nil),
                Read(values: [4, 5], generation: 1, hostTime: 99),
            ]
        )
        #expect(!ring.read { _, _ in Issue.record("The ring should be empty") })
    }

    @Test func dropsCyclesThatDontFitAndCountsThem() {
        let ring = CaptureRing(capacity: 512)
        var written = 0
        while Self.write([Float(written)], generation: written, to: ring) { written += 1 }
        #expect(written > 1)
        #expect(ring.droppedCycles == 1)
        #expect(!Self.write([0], generation: 0, to: ring))
        #expect(ring.droppedCycles == 2)

        // Reading frees the room again, and nothing written before the drops is lost.
        #expect(Self.readAll(from: ring).map(\.generation) == Array(0..<written))
        #expect(Self.write([0], generation: 0, to: ring))
        #expect(ring.droppedCycles == 2)
    }

    @Test func dropsACycleBiggerThanTheRing() {
        let ring = CaptureRing(capacity: 256)
        #expect(!Self.write([Float](repeating: 0, count: 64), generation: 0, to: ring))
        #expect(ring.droppedCycles == 1)
        #expect(Self.readAll(from: ring).isEmpty)
    }

    /// Records of many sizes land at every offset in a small ring, so records that would cross
    /// the end, with room for a wrap marker at the end and without, all come back whole. None is
    /// over half the ring, which always fits an empty one.
    @Test func recordsNeverSplitAcrossTheEnd() {
        let ring = CaptureRing(capacity: 512)
        var next: Float = 0
        for round in 0..<500 {
            let count = round % 37 + 1
            let values = (0..<count).map { _ in
                next += 1
                return next
            }
            #expect(Self.write(values, generation: round, to: ring))
            #expect(Self.readAll(from: ring) == [Read(values: values, generation: round, hostTime: nil)])
        }
        #expect(ring.droppedCycles == 0)
    }

    @Test func handsCyclesAcrossThreadsInOrder() async {
        let ring = CaptureRing(capacity: 4096)
        let total = 20_000
        let producer = Thread {
            for index in 0..<total {
                let values = [Float](repeating: Float(index), count: index % 50 + 1)
                Self.write(values, generation: index, to: ring)
            }
        }
        producer.start()

        var received: [Int] = []
        let deadline = Date.now.addingTimeInterval(30)
        while received.count + ring.droppedCycles < total, Date.now < deadline {
            ring.readAll { cycle, bytes in
                let values = Array(bytes.bindMemory(to: Float.self))
                #expect(values.count == cycle.formatGeneration % 50 + 1)
                #expect(values.allSatisfy { $0 == Float(cycle.formatGeneration) })
                received.append(cycle.formatGeneration)
            }
            await Task.yield()
        }

        #expect(received.count + ring.droppedCycles == total)
        #expect(received == received.sorted())
        #expect(Set(received).count == received.count)
    }

    // MARK: - Helpers

    private struct Read: Equatable {
        var values: [Float]
        var generation: Int
        var hostTime: UInt64?
    }

    @discardableResult
    private static func write(_ values: [Float], generation: Int, hostTime: UInt64? = nil, to ring: CaptureRing) -> Bool
    {
        let cycle = CapturedCycle(channelCount: 1, formatGeneration: generation, hostTime: hostTime, arrivalHostTime: 0)
        return values.withUnsafeBytes { ring.write(cycle, bytes: $0) }
    }

    private static func readAll(from ring: CaptureRing) -> [Read] {
        var reads: [Read] = []
        ring.readAll { cycle, bytes in
            let values = Array(bytes.bindMemory(to: Float.self))
            reads.append(Read(values: values, generation: cycle.formatGeneration, hostTime: cycle.hostTime))
        }
        return reads
    }
}
