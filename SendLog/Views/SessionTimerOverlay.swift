import SwiftUI

struct SessionTimerOverlayModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                SessionTimerFloatingBadge()
                    .padding(.top, 10)
                    .padding(.leading, 12)
            }
    }
}

extension View {
    func sessionTimerOverlay() -> some View {
        modifier(SessionTimerOverlayModifier())
    }
}

private struct SessionTimerFloatingBadge: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let hasStartedSession = store.isSessionRunning || store.currentSessionDuration() > 0

        Group {
            if hasStartedSession {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = store.currentSessionDuration(at: context.date)

                    HStack(spacing: 8) {
                        Image(systemName: store.isSessionRunning ? "play.fill" : "pause.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(store.isSessionRunning ? .green : .secondary)

                        Text(formatted(duration: elapsed))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func formatted(duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
