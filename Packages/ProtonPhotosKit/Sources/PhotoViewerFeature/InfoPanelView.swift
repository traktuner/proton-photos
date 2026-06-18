import SwiftUI
import MapKit
import PhotosCore
import DesignSystem

/// Liquid-Glass info panel that slides in from the right edge of the viewer, listing all available
/// file metadata for the current photo/video plus a native map when GPS is present.
struct InfoPanelView: View {
    let item: PhotoItem
    let metadata: PhotoMetadata?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    captureSection
                    if let m = metadata, m.hasLocation { mapSection(m) }
                    fileSection
                }
                .padding(20)
            }
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .glassEffect(in: RoundedRectangle(cornerRadius: 0))
        .background(.black.opacity(0.2))
    }

    private var header: some View {
        HStack {
            Text("Info")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    // MARK: Sections

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.captureTime, format: .dateTime.weekday(.wide).day().month(.wide).year())
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(item.captureTime, format: .dateTime.hour().minute())
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
            if let device = metadata?.device, !device.isEmpty {
                Label(device, systemImage: "camera")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder private func mapSection(_ m: PhotoMetadata) -> some View {
        let coord = CLLocationCoordinate2D(latitude: m.latitude!, longitude: m.longitude!)
        Map(initialPosition: .region(MKCoordinateRegion(
            center: coord,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))) {
            Marker("", coordinate: coord)
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false)
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let name = metadata?.filename, !name.isEmpty {
                row("Name", name)
            }
            if let w = metadata?.pixelWidth, let h = metadata?.pixelHeight {
                row("Dimensions", "\(w) × \(h)  (\(megapixels(w, h)) MP)")
            }
            if let size = metadata?.fileSize {
                row("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
            if let d = metadata?.durationSeconds, d > 0 {
                row("Duration", durationString(d))
            }
            if let mime = metadata?.mimeType, !mime.isEmpty {
                row("Type", mime)
            }
            if metadata == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .textSelection(.enabled)
        }
    }

    private func megapixels(_ w: Int, _ h: Int) -> String {
        String(format: "%.1f", Double(w * h) / 1_000_000)
    }

    private func durationString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
