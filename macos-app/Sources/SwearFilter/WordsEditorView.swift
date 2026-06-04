import SwiftUI

/// A simple word-list editor shown in its own window. One word per line; Apply
/// re-tokenizes the list with the model's BPE and reloads the engine.
struct WordsEditorView: View {
    @ObservedObject var controller: FilterController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Censored words").font(.headline)
            Text("One word per line. Add variants explicitly (fuck, fucking, fucked …) — the spotter matches each word as written. Lines starting with # are ignored.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $controller.wordsText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 300)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))

            HStack {
                if let status = controller.wordsStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Apply") { controller.applyWords() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 380, height: 460)
    }
}
