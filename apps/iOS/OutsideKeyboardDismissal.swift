import SwiftUI
import UIKit

// CONTEXT MEMORY
// Updated: 2026-10-27
// Status: inferred
// Why: Product actions should share medium feedback without replacing native button styles.
// Debug Goal: Observe app-window taps and long presses without consuming input or scrolling.
// Search Tags: app medium haptics window gesture simultaneous touch feedback
// Invariants:
// - Observers never cancel or delay a control's touches and are detached with their host.
// - Continuous scrolling and keyboard typing do not emit repeated impacts.
// Failure Modes:
// - An exclusive window gesture breaks text selection or sidebar context menus.
// - A hold-to-talk press emits a second impact when the global long press begins.
@MainActor enum AppFeedback {
    private static let generator = UIImpactFeedbackGenerator(style: .medium)
    private static let soft = UIImpactFeedbackGenerator(style: .light)
    /// Touch-down confirmation for press-to-talk; deliberately not rate-limited with `medium`.
    static func light() {
        guard UIApplication.shared.applicationState == .active else { return }
        soft.impactOccurred(intensity: 0.7); soft.prepare()
    }
    private static var lastImpact = -Double.infinity
    static func medium(minimumInterval: Double = 0.08) {
        let now = ProcessInfo.processInfo.systemUptime
        guard UIApplication.shared.applicationState == .active, now - lastImpact >= minimumInterval else { return }
        lastImpact = now; generator.impactOccurred(); generator.prepare()
    }
}

struct AppInteractionFeedback: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> OutsideKeyboardDismissal.ProbeView {
        let view = OutsideKeyboardDismissal.ProbeView(); view.isUserInteractionEnabled = false
        view.moved = { [weak coordinator = context.coordinator] in coordinator?.attach(to: $0) }
        return view
    }
    func updateUIView(_ view: OutsideKeyboardDismissal.ProbeView, context: Context) { context.coordinator.attach(to: view.window) }
    static func dismantleUIView(_ view: OutsideKeyboardDismissal.ProbeView, coordinator: Coordinator) { coordinator.attach(to: nil) }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?
        private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        private lazy var adjustment = UIPanGestureRecognizer(target: self, action: #selector(adjusted(_:)))
        private lazy var press: UILongPressGestureRecognizer = {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            gesture.minimumPressDuration = 0.5; return gesture
        }()
        func attach(to value: UIWindow?) {
            guard window !== value else { return }
            for gesture in [tap, press, adjustment] {
                window?.removeGestureRecognizer(gesture)
                gesture.cancelsTouchesInView = false; gesture.delaysTouchesBegan = false; gesture.delaysTouchesEnded = false
                gesture.delegate = self; value?.addGestureRecognizer(gesture)
            }
            window = value
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard gestureRecognizer === adjustment else { return true }
            var view = touch.view
            while let current = view {
                if current is UISlider || current is UISwitch || current is UIPickerView || current is UIDatePicker { return true }
                view = current.superview
            }
            return false
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        @objc private func tapped() { AppFeedback.medium() }
        @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { AppFeedback.medium(minimumInterval: 0.65) }
        }
        @objc private func adjusted(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .ended { AppFeedback.medium() }
        }
    }
}

// CONTEXT MEMORY
// Updated: 2026-10-26
// Status: verified
// Why: Safe-area text input needs explicit native resignation on outside taps.
// Debug Goal: Outside taps dismiss input without consuming control actions.
// Search Tags: outside tap keyboard safeAreaBar cancelsTouchesInView
// Invariants:
// - The composer and editable controls are excluded from outside dismissal.
// - The window recognizer never cancels or delays the original touch.
// Failure Modes:
// - Sending a message unexpectedly closes the keyboard.
// - An ancestor SwiftUI gesture prevents header controls from firing.
struct OutsideKeyboardDismissal: UIViewRepresentable {
    var enabled: Bool
    var excluded: CGRect
    var dismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.moved = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
        return view
    }
    func updateUIView(_ uiView: ProbeView, context: Context) {
        if context.coordinator.enabled && !enabled { uiView.window?.endEditing(true) }
        context.coordinator.enabled = enabled
        context.coordinator.excluded = excluded
        context.coordinator.dismiss = dismiss
        context.coordinator.attach(to: uiView.window)
    }
    static func dismantleUIView(_ uiView: ProbeView, coordinator: Coordinator) { coordinator.attach(to: nil) }

    final class ProbeView: UIView {
        var moved: ((UIWindow?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); moved?(window) }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled = false
        var excluded = CGRect.zero
        var dismiss: () -> Void = {}
        private weak var window: UIWindow?
        private lazy var recognizer: UITapGestureRecognizer = {
            let gesture = UITapGestureRecognizer(target: self, action: #selector(tapped))
            gesture.cancelsTouchesInView = false
            gesture.delaysTouchesBegan = false; gesture.delaysTouchesEnded = false
            gesture.delegate = self
            return gesture
        }()
        func attach(to value: UIWindow?) {
            guard window !== value else { return }
            window?.removeGestureRecognizer(recognizer)
            window = value
            value?.addGestureRecognizer(recognizer)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard enabled, !excluded.contains(touch.location(in: window)) else { return false }
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView || current is UIControl { return false }
                view = current.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc private func tapped() { window?.endEditing(true); dismiss() }
    }
}
