import Cocoa
import Foundation
import os

private let logger = Logger(subsystem: "team.yourorbit.OrbitDictation", category: "HotkeyManager")
private let trackedModifierKeyCodes: Set<UInt16> = [
    54, 55,       // Right Cmd, Left Cmd
    56, 60,       // Left Shift, Right Shift
    58, 61,       // Left Option, Right Option
    59, 62,       // Left Control, Right Control
    63,           // Fn / Globe key
]

/// Global hotkey detection using CGEventTap with NSEvent monitor fallback.
///
/// `ObservableObject` conformance: required so SwiftUI views observing
/// `AppState` re-render when `isAccessibilityGranted` flips. Without this
/// the @Published on the property fires HotkeyManager's own publisher but
/// AppState's `objectWillChange` never sees the event, and the Setup card's
/// "Missing"/"Granted" badge would lag the actual state until something else
/// on AppState changes. AppState subscribes to this object's
/// `objectWillChange` in its initialiser and re-emits.
@MainActor
final class HotkeyManager: ObservableObject {

    enum Event: Sendable {
        case holdActivated
        case holdDeactivated
        case toggleActivated
        case toggleDeactivated
        case cancelRequested
    }

    nonisolated(unsafe) var onEvent: ((Event) -> Void)?
    nonisolated(unsafe) var holdBinding: ShortcutBinding = .fnKey
    nonisolated(unsafe) var toggleBinding: ShortcutBinding? = nil
    nonisolated(unsafe) var cancelWatchEnabled = false

    /// Delay before a bare-modifier hold binding (e.g. Fn alone) activates.
    /// Short taps within this window are ignored so macOS can handle its own
    /// Fn behaviors (emoji picker, dictation) without racing our overlay.
    /// Chorded bindings with an explicit keyCode activate immediately.
    nonisolated(unsafe) var holdArmThreshold: TimeInterval = 0.18

    @Published private(set) var isAccessibilityGranted = false
    @Published private(set) var isMonitoring = false
    @Published private(set) var eventCount = 0
    @Published private(set) var lastEventDescription = ""

    // Tracked key state — protected by `stateLock` so concurrent reads from the
    // CGEvent tap callback and NSEvent monitors can't tear the sets.
    private struct SharedState {
        var pressedModifierKeyCodes: Set<UInt16> = []
        var pressedKeyCodes: Set<UInt16> = []
        var holdActive = false
        var holdArming = false
        var toggleActive = false
    }
    private let stateLock = OSAllocatedUnfairLock<SharedState>(initialState: SharedState())

    private nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private nonisolated(unsafe) var holdArmTimer: DispatchWorkItem?
    private var localFlagsMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var localKeyUpMonitor: Any?
    /// Dedicated ESC watcher that runs in parallel with the CGEvent tap.
    /// Some focused-input contexts (secure input, certain IMEs, other taps
    /// ahead of ours) can swallow keyDown events before our tap sees them.
    /// Global monitors can't *consume* events, but they reliably *observe*,
    /// so they let us still fire cancel even when the tap path misses.
    private var globalEscMonitor: Any?
    private var accessibilityTimer: Timer?

    // MARK: - Lifecycle

    func start() {
        checkAccessibilityAndInstall()
        scheduleAccessibilityPollIfNeeded()
        installGlobalEscMonitor()
    }

    /// Re-check Accessibility trust + reinstall the CGEvent tap if it just
    /// went from denied to granted. Cheap to call — `AXIsProcessTrusted()` is
    /// a synchronous syscall — and idempotent, so AppState wires it into the
    /// `didBecomeActive` permission-snapshot path so a user who grants the
    /// permission in System Settings and switches back gets immediate
    /// pickup, rather than waiting for the polling fallback.
    func refreshAccessibilityStatus() {
        checkAccessibilityAndInstall()
    }

    /// Poll for Accessibility permission changes only until it's granted and
    /// the CGEvent tap is installed. Tight interval (1s) so the user gets
    /// near-instant pickup if they grant from System Settings without ever
    /// re-activating the app — the foreground-activation path covers the
    /// common case immediately, this catches the user who toggles the grant
    /// while never giving the menu-bar app focus. Once monitoring is up, the
    /// timer stops; nothing else flips the grant state at runtime in a way
    /// that matters here.
    private func scheduleAccessibilityPollIfNeeded() {
        guard accessibilityTimer == nil else { return }
        guard eventTap == nil else { return }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.checkAccessibilityAndInstall()
                if self.eventTap != nil {
                    self.accessibilityTimer?.invalidate()
                    self.accessibilityTimer = nil
                }
            }
        }
        // Add to common modes so the timer fires even while a menu or modal
        // is being tracked. `Timer.scheduledTimer` defaults to `.default`
        // mode, which suspends during menu tracking — exactly when a
        // menu-bar app's user is most likely to be granting permissions.
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTimer = timer
    }

    func stop() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        teardownEventTap()
        teardownLocalMonitors()
        teardownGlobalEscMonitor()
        holdArmTimer?.cancel()
        holdArmTimer = nil
        stateLock.withLock { state in
            state.pressedModifierKeyCodes.removeAll()
            state.pressedKeyCodes.removeAll()
            state.holdActive = false
            state.holdArming = false
            state.toggleActive = false
        }
        isMonitoring = false
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // Re-arm the poll so we notice the grant quickly once the user responds.
        scheduleAccessibilityPollIfNeeded()
    }

    // MARK: - Setup

    private func checkAccessibilityAndInstall() {
        let trusted = AXIsProcessTrusted()
        // Logged so users + maintainers can trace what macOS actually thinks
        // by running:
        //   log stream --predicate 'subsystem == "team.yourorbit.OrbitDictation" AND category == "HotkeyManager"' --info
        // If this stays false even after the user grants Accessibility in
        // System Settings, the issue is at the OS level (TCC not honouring
        // the grant for our binary identity), not the in-app polling or
        // SwiftUI propagation.
        // `privacy: .public` — Swift's Logger redacts dynamic values to
        // `<private>` by default. We want this log line to be human-readable
        // in Console.app and via the in-app Live Logs viewer for diagnostic
        // purposes; the AXIsProcessTrusted result and bundle path are not
        // sensitive.
        logger.info("AXIsProcessTrusted() = \(trusted ? "true" : "false", privacy: .public) · bundlePath=\(Bundle.main.bundleURL.path, privacy: .public)")
        isAccessibilityGranted = trusted

        if trusted && eventTap == nil {
            installEventTap()
            teardownLocalMonitors()
        } else if !trusted && eventTap == nil && localFlagsMonitor == nil {
            installLocalMonitors()
        }
    }

    // MARK: - CGEventTap (primary)

    private func installEventTap() {
        let eventMask: CGEventMask = (
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        )

        let unmanagedSelf = Unmanaged.passUnretained(self)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                return manager.handleEventTap(type: type, event: event)
            },
            userInfo: unmanagedSelf.toOpaque()
        ) else {
            logger.error("CGEvent.tapCreate failed — Accessibility granted but tap creation failed")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.isMonitoring = true

        logger.info("CGEventTap installed — monitoring for \(self.holdBinding.displayName)")
    }

    private func teardownEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - NSEvent Monitors (fallback when CGEventTap unavailable)

    private func installLocalMonitors() {
        // Global monitors detect events from ALL apps (but can't consume them)
        // This is what we need for a menu bar app that's never focused
        localFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            _ = self?.handleFlagsChanged(event)
        }
        localKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handleKeyDown(event)
        }
        localKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyUp(event)
        }
        isMonitoring = true
        logger.info("Global NSEvent monitors installed (fallback — no Accessibility)")
    }

    private func teardownLocalMonitors() {
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m); localFlagsMonitor = nil }
        if let m = localKeyDownMonitor { NSEvent.removeMonitor(m); localKeyDownMonitor = nil }
        if let m = localKeyUpMonitor { NSEvent.removeMonitor(m); localKeyUpMonitor = nil }
    }

    // MARK: - Global ESC watcher (parallel to CGEvent tap)

    private func installGlobalEscMonitor() {
        guard globalEscMonitor == nil else { return }
        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            guard let self, self.cancelWatchEnabled else { return }
            logger.info("ESC observed by global monitor — firing cancel")
            self.onEvent?(.cancelRequested)
        }
    }

    private func teardownGlobalEscMonitor() {
        if let m = globalEscMonitor {
            NSEvent.removeMonitor(m)
            globalEscMonitor = nil
        }
    }

    // MARK: - CGEventTap Handler

    private nonisolated func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enable the tap if macOS disabled it
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .flagsChanged, .keyDown, .keyUp:
            guard let nsEvent = NSEvent(cgEvent: event) else {
                return Unmanaged.passUnretained(event)
            }

            let shouldConsume: Bool
            switch type {
            case .flagsChanged:
                shouldConsume = handleFlagsChanged(nsEvent)
            case .keyDown:
                shouldConsume = handleKeyDown(nsEvent)
            case .keyUp:
                handleKeyUp(nsEvent)
                shouldConsume = false
            default:
                shouldConsume = false
            }

            return shouldConsume ? nil : Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Event Handlers (shared between tap and local monitors)

    /// Handle modifier key changes. Returns true if the event should be consumed.
    @discardableResult
    private nonisolated func handleFlagsChanged(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode

        // This runs inside the CGEvent tap callback — the most latency-sensitive
        // path in the app (a slow callback risks macOS disabling the tap via
        // tapDisabledByTimeout). So bail on modifiers we don't track BEFORE any
        // logging or main-thread dispatch, and keep per-event logging at .debug
        // (info-level persists and adds overhead on every modifier change made
        // anywhere on the machine, not just Comet's binding).
        guard trackedModifierKeyCodes.contains(keyCode) else { return false }
        logger.debug("flagsChanged: keyCode=\(keyCode) mods=\(event.modifierFlags.rawValue)")

        // Toggle presence: if already pressed → now released, if not pressed → now pressed
        let wasReleased = stateLock.withLock { state -> Bool in
            if state.pressedModifierKeyCodes.contains(keyCode) {
                state.pressedModifierKeyCodes.remove(keyCode)
                return true
            } else {
                state.pressedModifierKeyCodes.insert(keyCode)
                return false
            }
        }
        logger.debug("Modifier \(wasReleased ? "released" : "pressed"): keyCode=\(keyCode)")

        DispatchQueue.main.async {
            self.eventCount += 1
            self.lastEventDescription = "flags keyCode=\(keyCode)"
        }

        evaluateBindings()
        return false
    }

    private nonisolated func handleKeyDown(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        stateLock.withLock { state in
            _ = state.pressedKeyCodes.insert(keyCode)
        }
        // Escape while recording → cancel (consume the event so the focused app doesn't see it).
        if keyCode == 53 {
            logger.info("ESC keyDown via tap — cancelWatchEnabled=\(self.cancelWatchEnabled)")
            if cancelWatchEnabled {
                onEvent?(.cancelRequested)
                return true
            }
        }
        evaluateBindings()
        return false
    }

    private nonisolated func handleKeyUp(_ event: NSEvent) {
        let keyCode = event.keyCode
        stateLock.withLock { state in
            _ = state.pressedKeyCodes.remove(keyCode)
        }
        evaluateBindings()
    }

    // MARK: - Binding Evaluation

    /// Check all bindings against current key state and fire events.
    private nonisolated func evaluateBindings() {
        let useThreshold = holdBinding.keyCode == nil && holdArmThreshold > 0

        enum HoldAction { case none, arm, cancelArm }

        let (transitions, holdAction) = stateLock.withLock { state -> ([Event], HoldAction) in
            let holdNowMatches = Self.bindingIsActive(holdBinding, state: state)
            let toggleNowActive = toggleBinding.map { Self.bindingIsActive($0, state: state) } ?? false

            var events: [Event] = []
            var action: HoldAction = .none

            if useThreshold {
                if holdNowMatches {
                    if !state.holdActive && !state.holdArming {
                        state.holdArming = true
                        action = .arm
                    }
                } else {
                    if state.holdArming {
                        state.holdArming = false
                        action = .cancelArm
                    }
                    if state.holdActive {
                        state.holdActive = false
                        events.append(.holdDeactivated)
                    }
                }
            } else {
                if holdNowMatches && !state.holdActive {
                    state.holdActive = true
                    events.append(.holdActivated)
                } else if !holdNowMatches && state.holdActive {
                    state.holdActive = false
                    events.append(.holdDeactivated)
                }
            }

            if toggleNowActive && !state.toggleActive {
                state.toggleActive = true
                events.append(.toggleActivated)
            }
            if !toggleNowActive && state.toggleActive {
                state.toggleActive = false
                events.append(.toggleDeactivated)
            }

            return (events, action)
        }

        switch holdAction {
        case .arm:
            scheduleHoldArmTimer()
        case .cancelArm:
            holdArmTimer?.cancel()
            holdArmTimer = nil
        case .none:
            break
        }

        for event in transitions {
            switch event {
            case .holdActivated: logger.info("Hold activated")
            case .holdDeactivated: logger.info("Hold deactivated")
            default: break
            }
            onEvent?(event)
        }
    }

    /// Schedule a deferred activation for bare-modifier holds so brief taps
    /// don't trigger recording (and don't conflict with macOS Fn behaviors).
    private nonisolated func scheduleHoldArmTimer() {
        holdArmTimer?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.holdArmTimer = nil

            let shouldFire = self.stateLock.withLock { state -> Bool in
                guard state.holdArming else { return false }
                state.holdArming = false
                // Re-check that the binding is still held when the timer fires.
                guard Self.bindingIsActive(self.holdBinding, state: state) else {
                    return false
                }
                state.holdActive = true
                return true
            }

            if shouldFire {
                logger.info("Hold activated (after threshold)")
                self.onEvent?(.holdActivated)
            }
        }

        holdArmTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdArmThreshold, execute: work)
    }

    /// Check if a binding matches the supplied pressed-key snapshot. Pure;
    /// expected to be called from inside `stateLock.withLock`.
    private nonisolated static func bindingIsActive(_ binding: ShortcutBinding, state: SharedState) -> Bool {
        let activeModifiers = currentModifiers(state: state)
        guard activeModifiers.isSuperset(of: binding.modifiers) else {
            return false
        }

        if binding.keyCode == nil {
            return true
        }

        if let keyCode = binding.keyCode {
            // Modifier keycodes (Right Option, Right Command, etc.) flow
            // through `flagsChanged` and live in `pressedModifierKeyCodes`,
            // never in `pressedKeyCodes`. A binding whose own keyCode is a
            // modifier (e.g. `kVK_RightOption = 61`) would otherwise never
            // match. Check the modifier set first, then fall back to the
            // regular pressed-keys set for non-modifier bindings.
            if trackedModifierKeyCodes.contains(keyCode) {
                return state.pressedModifierKeyCodes.contains(keyCode)
            }
            return state.pressedKeyCodes.contains(keyCode)
        }

        return false
    }

    private nonisolated static func currentModifiers(state: SharedState) -> ShortcutModifiers {
        var mods = ShortcutModifiers()
        let codes = state.pressedModifierKeyCodes
        if codes.contains(63) { mods.insert(.function) }
        if codes.contains(55) || codes.contains(54) { mods.insert(.command) }
        if codes.contains(56) || codes.contains(60) { mods.insert(.shift) }
        if codes.contains(58) || codes.contains(61) { mods.insert(.option) }
        if codes.contains(59) || codes.contains(62) { mods.insert(.control) }
        return mods
    }
}
