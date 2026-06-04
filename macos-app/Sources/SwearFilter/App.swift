import AppKit
import SwiftUI

@main
struct SwearFilterApp: App {
    @StateObject private var controller = FilterController()

    var body: some Scene {
        MenuBarExtra {
            ControlsView(controller: controller)
        } label: {
            Image(systemName: controller.isOn ? "person.wave.2.fill" : "person.wave.2")
        }
        .menuBarExtraStyle(.window)
    }
}

struct ControlsView: View {
    @ObservedObject var controller: FilterController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(get: { controller.isOn }, set: { _ in controller.toggle() })) {
                Text("Censor system audio").font(.headline)
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

            paramSlider("Sensitivity", value: $controller.sensitivity, range: 0...1,
                        format: { "\(Int($0 * 100))%" },
                        help: "Higher catches more (incl. under music), but more false hits.",
                        onRelease: { controller.restartForStructuralChange() })
            paramSlider("Output delay", value: $controller.delayMs, range: 400...1500,
                        help: "Higher = catches longer words fully, more lag.",
                        onRelease: { controller.restartForStructuralChange() })
            paramSlider("Word length / letter", value: $controller.msPerChar, range: 40...140,
                        help: "Speech-rate estimate. Raise if word starts bleed.")
            paramSlider("Latency reach-back", value: $controller.latencyMarginMs, range: 100...600,
                        help: "Detector lag before the word. Lower if tails get cut.")
            paramSlider("Trailing tail", value: $controller.postrollMs, range: 0...500,
                        help: "Extra silence kept after the word.")

            Divider()

            HStack {
                Button("Reset") { controller.reset() }
                Spacer()
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
