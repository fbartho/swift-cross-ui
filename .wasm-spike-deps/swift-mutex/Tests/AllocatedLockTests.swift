//
//  AllocatedLockTests.swift
//  swift-mutex
//
//  Created by Simon Whitty on 10/04/2023.
//  Copyright 2023 Simon Whitty
//
//  Distributed under the permissive MIT license
//  Get the latest version from here:
//
//  https://github.com/swhitty/swift-mutex
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

#if canImport(Testing)
@testable import Mutex
import Testing

struct AllocatedLockTests {

    @Test
    func lockState_IsProtected() async {
        let state = AllocatedLock<Int>(initialState: 0)

        let total = await withTaskGroup(of: Void.self) { group in
            for i in 1...1000 {
                group.addTask {
                    state.withLock { $0 += i }
                }
            }
            await group.waitForAll()
            return state.withLock { $0 }
        }

        #expect(total == 500500)
    }

    @Test
    func lock_ReturnsValue() async {
        let lock = AllocatedLock()
        let value = lock.withLock { true }
        #expect(value)
    }

    @Test
    func lock_Blocks() async {
        let lock = AllocatedLock()
        await MainActor.run {
            lock.unsafeLock()
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000)
            lock.unsafeUnlock()
        }

        let results = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000)
                return true
            }
            group.addTask {
                lock.unsafeLock()
                lock.unsafeUnlock()
                return false
            }
            let first = await group.next()!
            let second = await group.next()!
            return [first, second]
        }
        #expect(results == [true, false])
    }

    @Test
    func tryLock() {
        let lock = AllocatedLock()
        let value = lock.withLock { true }
        #expect(value)
    }

    @Test
    func ifAvailable() {
        let lock = AllocatedLock(uncheckedState: 5)
        #expect(
            lock.withLock { _ in "fish" } == "fish"
        )

        lock.unsafeLock()
        #expect(
            lock.withLockIfAvailable { _ in "fish" } == nil
        )

        lock.unsafeUnlock()
        #expect(
            lock.withLockIfAvailable { _ in "fish" } == "fish"
        )
    }

    @Test
    func ifAvailableUnchecked() {
        let lock = AllocatedLock(uncheckedState: NonSendable("fish"))
        #expect(
            lock.withLockUnchecked { $0 }.name == "fish"
        )

        lock.unsafeLock()
        #expect(
            lock.withLockIfAvailableUnchecked { $0 }?.name == nil
        )

        lock.unsafeUnlock()
        #expect(
            lock.withLockIfAvailableUnchecked { $0 }?.name == "fish"
        )
    }

    @Test
    func voidIfAvailable() {
        let lock = AllocatedLock()
        #expect(
            lock.withLock { "fish" } == "fish"
        )

        lock.unsafeLock()
        #expect(
            lock.withLockIfAvailable { "fish" } == nil
        )

        lock.unsafeUnlock()
        #expect(
            lock.withLockIfAvailable { "fish" } == "fish"
        )
    }

    @Test
    func voidIfAvailableUnchecked() {
        let lock = AllocatedLock()
        #expect(
            lock.withLockUnchecked { NonSendable("fish") }.name == "fish"
        )

        lock.lock()
        #expect(
            lock.withLockIfAvailableUnchecked { NonSendable("fish") } == nil
        )

        lock.unlock()
        #expect(
            lock.withLockIfAvailableUnchecked { NonSendable("chips") }?.name == "chips"
        )
    }

    @Test
    func voidLock() {
        let lock = AllocatedLock()
        lock.lock()
        #expect(lock.lockIfAvailable() == false)
        lock.unlock()
        #expect(lock.lockIfAvailable())
        lock.unlock()
    }
}

public final class NonSendable {

    let name: String

    init(_ name: String) {
        self.name = name
    }
}
#endif
