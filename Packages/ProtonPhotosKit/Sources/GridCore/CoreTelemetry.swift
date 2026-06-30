/// Platform-neutral telemetry event emitted by reusable Core code. Core targets only provide the event name
/// and string fields; platform adapters decide whether this is logged, sampled, uploaded, or ignored.
package struct CoreTelemetryEvent: Equatable, Sendable {
    package let name: String
    package let fields: [String: String]

    package init(name: String, fields: [String: String] = [:]) {
        self.name = name
        self.fields = fields
    }
}

package typealias CoreTelemetrySink = (CoreTelemetryEvent) -> Void
