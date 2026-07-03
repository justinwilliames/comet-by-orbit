import AppKit
import Combine
import SwiftUI

/// Presents a floating overlay that mirrors the pipeline state.
@MainActor
final class OverlayPanelManager {
    private var panel: NSPanel?
    private var phaseCancellable: AnyCancellable?
    private var stopHandler: (() -> Void)?
    private var cancelHandler: (() -> Void)?

    func bind(
        to pipeline: DictationPipeline,
        onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        stopHandler = onStop
        cancelHandler = onCancel

        phaseCancellable = pipeline.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }

                switch phase {
                case .idle:
                    self.hide()
                case .requestingMicrophonePermission,
                        .starting,
                        .recording,
                        .normalizingAudio,
                        .transcribing,
                        .cleaningTranscript,
                        .pasting,
                        .done,
                        .error:
                    self.show(pipeline: pipeline)
                }
            }
    }

    private func show(pipeline: DictationPipeline) {
        if panel == nil {
            createPanel(pipeline: pipeline)
        }

        // The hosting view is built ONCE in `createPanel`, and its
        // RecordingOverlay observes `pipeline` directly, so it repaints itself
        // on every phase / audioLevel change. Do NOT re-assign `contentView`
        // here: `show()` fires for every non-idle phase tick, and re-hosting a
        // fresh NSHostingView each time throws away the live SwiftUI tree and
        // restarts in-flight animations mid-transition (a visible stutter while
        // the user is watching the overlay). Just position and front it.
        positionPanel()
        panel?.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func createPanel(pipeline: DictationPipeline) {
        let hostingView = NSHostingView(
            rootView: RecordingOverlay(
                pipeline: pipeline,
                onStop: { [weak self] in self?.stopHandler?() },
                onCancel: { [weak self] in self?.cancelHandler?() }
            )
            .frame(width: 430)
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.contentView = hostingView

        self.panel = panel
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }

        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let x = visibleFrame.midX - (panelSize.width / 2)
        let y = visibleFrame.maxY - panelSize.height - 18
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
