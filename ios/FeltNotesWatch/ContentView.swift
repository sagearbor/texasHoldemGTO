import SwiftUI

/// One screen: big bpm, Start/Stop, and whether the iPhone is getting it.
struct ContentView: View {
    @EnvironmentObject private var pulse: PulseSession

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(pulse.bpm.map(String.init) ?? "--")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                    .opacity(pulse.running ? 1 : 0.35)
            }
            Text("bpm")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button(action: pulse.toggle) {
                Text(pulse.running || pulse.starting ? "Stop" : "Start")
                    .frame(maxWidth: .infinity)
            }
            .tint(pulse.running || pulse.starting ? .red : .green)

            Text(statusLine)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(pulse.error == nil ? Color.secondary : Color.orange)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 4)
    }

    private var statusLine: String {
        switch pulse.error {
        case "no_permission": return "No Health access. Allow it in the Health app."
        case "unavailable": return "Heart rate not available"
        case .some: return "Could not start, try again"
        case .none: break
        }
        return pulse.phoneReachable ? "Sending to your iPhone" : "iPhone not connected"
    }
}
