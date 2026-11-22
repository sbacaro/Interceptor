import Foundation
import InterceptorEngine
import Testing

@Suite("Lock-Free Triple Buffer")
struct LockFreeTripleBufferTests {
    struct SamplePayload: Sendable, Equatable {
        var generation: Int
        var checksum: Int
    }

    @Test("Delivers latest written snapshot immediately")
    func deliversLatestSnapshot() {
        let buffer = LockFreeTripleBuffer(initialValue: SamplePayload(generation: 0, checksum: 0))
        #expect(buffer.readLatest() == SamplePayload(generation: 0, checksum: 0))

        buffer.write(SamplePayload(generation: 1, checksum: 101))
        buffer.write(SamplePayload(generation: 2, checksum: 202))
        buffer.write(SamplePayload(generation: 3, checksum: 303))

        #expect(buffer.readLatest() == SamplePayload(generation: 3, checksum: 303))
        // Repeated reads with no intervening writes return the same committed state.
        #expect(buffer.readLatest() == SamplePayload(generation: 3, checksum: 303))
    }

    @Test("Maintains tear-free invariants under concurrent writer and real-time reader")
    func concurrentReadWriteIsTearFree() async {
        let buffer = LockFreeTripleBuffer(initialValue: SamplePayload(generation: 0, checksum: 0))
        let totalIterations = 25_000

        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for i in 1...totalIterations {
                    buffer.write(SamplePayload(generation: i, checksum: i * 17))
                }
                return true
            }

            group.addTask {
                var lastSeen = 0
                for _ in 0..<(totalIterations * 2) {
                    let value = buffer.readLatest()
                    // Must never observe a torn write (checksum must always match generation * 17)
                    if value.checksum != value.generation * 17 {
                        return false
                    }
                    // Must never regress backwards in time
                    if value.generation < lastSeen {
                        return false
                    }
                    lastSeen = value.generation
                }
                return true
            }

            for await passed in group {
                #expect(passed)
            }
        }

        let finalValue = buffer.readLatest()
        #expect(finalValue == SamplePayload(generation: totalIterations, checksum: totalIterations * 17))
    }
}
