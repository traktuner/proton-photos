import SwiftUI
import PhotosCore

/// Live animation-tuning panel (opens as a 2nd window at launch). Drag a slider and the change takes
/// effect on the very next animation — no rebuild. Values are shown in milliseconds (springs show
/// their response in ms + a unitless damping).
struct TuningView: View {
    @State private var tuning = AnimationTuning.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Animation Tuning").font(.headline)
                    Spacer()
                    Button("Reset") { tuning.reset() }
                }
                Text("Change live — affects the next animation, no rebuild.")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(AnimationTuning.fields, id: \.0) { field in
                    let isDamping = field.0.contains("damping")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(field.0).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(isDamping ? String(format: "%.2f", tuning[keyPath: field.1])
                                           : "\(Int(tuning[keyPath: field.1] * 1000)) ms")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { tuning[keyPath: field.1] },
                                              set: { tuning[keyPath: field.1] = $0 }),
                               in: field.2)
                    }
                }
            }
            .padding(16)
        }
        .frame(minWidth: 320, minHeight: 420)
    }
}
