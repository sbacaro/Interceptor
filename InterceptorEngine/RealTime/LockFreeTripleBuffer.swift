import Synchronization

/// Wait-free Single-Producer Single-Consumer (SPSC) triple buffer for lock-free
/// real-time audio configuration updates without allocations or mutexes on the audio thread.
public final class LockFreeTripleBuffer<Value: Sendable>: @unchecked Sendable {
    private let slots: UnsafeMutablePointer<Value>

    /// Index owned exclusively by the control-thread writer (`0`, `1`, or `2`).
    private var writerIndex: UInt8 = 0

    /// Index owned exclusively by the real-time audio-thread reader (`0`, `1`, or `2`).
    private var readerIndex: UInt8 = 1

    /// Encodes `(middleIndex & 0x03) | (hasFreshValue ? 0x04 : 0x00)`.
    private let middleState: Atomic<UInt8>

    /// Serializes concurrent control-thread writers without ever touching the audio thread.
    private let writerLock = Mutex<Void>(())

    public init(initialValue: Value) {
        self.slots = UnsafeMutablePointer<Value>.allocate(capacity: 3)
        self.slots.advanced(by: 0).initialize(to: initialValue)
        self.slots.advanced(by: 1).initialize(to: initialValue)
        self.slots.advanced(by: 2).initialize(to: initialValue)
        self.middleState = Atomic<UInt8>(2) // slot 2 starts as middle, dirty bit = 0
    }

    deinit {
        slots.deinitialize(count: 3)
        slots.deallocate()
    }

    /// Publishes a new snapshot from any non-real-time control thread.
    public func write(_ value: Value) {
        writerLock.withLock { _ in
            let writeIdx = Int(writerIndex)
            slots.advanced(by: writeIdx).pointee = value
            let nextMiddle = writerIndex | 0x04
            let previous = middleState.exchange(nextMiddle, ordering: .acquiringAndReleasing)
            writerIndex = previous & 0x03
        }
    }

    /// Wait-free real-time read returning a pointer to the latest committed snapshot.
    /// Must only be called from a single consumer thread (the Core Audio IOProc thread).
    @inline(__always)
    public func readLatestPointer() -> UnsafePointer<Value> {
        let currentMiddle = middleState.load(ordering: .relaxed)
        if (currentMiddle & 0x04) != 0 {
            let previous = middleState.exchange(readerIndex & 0x03, ordering: .acquiringAndReleasing)
            readerIndex = previous & 0x03
        }
        return UnsafePointer(slots.advanced(by: Int(readerIndex)))
    }

    /// Convenience read returning a copy of the latest snapshot.
    @inline(__always)
    public func readLatest() -> Value {
        readLatestPointer().pointee
    }
}
