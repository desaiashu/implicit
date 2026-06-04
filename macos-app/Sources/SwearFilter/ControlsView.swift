import AppKit
import SwiftUI

/// The popover contents: on/off, mode, the tuning sliders, reset, quit.
struct ControlsView: View {
    @ObservedObject var controller: FilterController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "ear")
                Text("Censor Audio").font(.headline)
            }

            Divider()

            Toggle(isOn: Binding(get: { controller.isOn }, set: { _ in controller.toggle() })) {
                Text("Censor system audio")
            }
            .toggleStyle(.switch)

            if let msg = controller.statusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Picker("On detection", selection: $controller.bleep) {
                Text("Mute").tag(false)
                Text("Bleep").tag(true)
            }
            .pickerStyle(.segmented)

            paramSlider("Output delay", value: $controller.delayMs, range: 1500...5000,
                        format: { $0 >= 1000 ? String(format: "%.1f s", $0 / 1000) : "\(Int($0)) ms" },
                        help: "Whisper needs lead time; more delay catches more, with more lag.",
                        onRelease: { controller.restartForStructuralChange() })
            paramSlider("Trailing tail", value: $controller.postrollMs, range: 0...500,
                        help: "Extra silence kept after the word.")

            Divider()

            Button("Edit Words…") { controller.openEditor?() }

            HStack {
                Button("Reset") { controller.reset() }
                Spacer()
                Button("Info") {
                    if let url = URL(string: "https://censor.audio") { NSWorkspace.shared.open(url) }
                }
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func paramSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                             format: @escaping (Double) -> String = { "\(Int($0)) ms" },
                             help: String, onRelease: @escaping () -> Void = {}) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, onEditingChanged: { editing in if !editing { onRelease() } })
            Text(help).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
