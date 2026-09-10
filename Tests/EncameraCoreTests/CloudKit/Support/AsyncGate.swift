//
//  AsyncGate.swift
//  EncameraCoreTests
//
//  A rendezvous point for tests that need one operation to land at an exact
//  moment inside another.
//
//  The alternative is a sleep, which only makes an ordering *likely*. That is
//  fatal for a test whose whole subject is a lost update: the bug reproduces when
//  a write lands between another operation's read and its write-back, so a test
//  that misses the window reports "no bug" — and the same test then passes just as
//  happily against unfixed code.
//

import Foundation

/// Blocks whoever calls `enter()` until the test calls `release()`, and lets the
/// test wait for `enter()` to be reached via `waitUntilEntered()`.
actor AsyncGate {

    private var isEntered = false
    private var isReleased = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called from inside the code under test. Announces arrival, then suspends
    /// until released. Returns immediately if the gate was already released, so a
    /// second call (a retry loop, a second page) does not deadlock.
    func enter() async {
        isEntered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters = []
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    /// Called from the test. Returns once the code under test has reached `enter()`.
    func waitUntilEntered() async {
        guard !isEntered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    /// Called from the test. Lets the blocked caller — and every later one — proceed.
    func release() {
        isReleased = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters = []
    }
}
