import SwiftUI
import SwiftSTEP

/// The array `STEP.readBodies` returns, as a list: one row per body, with a visibility checkbox and the
/// part's colour. Selecting a row highlights the body in the canvas.
struct BodyListView: View {
    @ObservedObject var viewer: Viewer

    var body: some View {
        VStack(spacing: 0) {
            if let document = viewer.document {
                List(selection: $viewer.selectedBody) {
                    ForEach(document.assembly.bodies) { item in
                        HStack(spacing: 8) {
                            Toggle("Visible", isOn: visibility(of: item.id))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                            Circle()
                                .fill(BodyPalette.swiftUI(document.colorIndex[item.id] ?? 0))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.displayName).lineLimit(1)
                                Text(detail(of: item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(item.id)
                    }
                }
                Divider()
                HStack {
                    Text("\(document.assembly.bodies.count) bodies").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show all") { viewer.hiddenBodies = [] }
                        .disabled(viewer.hiddenBodies.isEmpty)
                }
                .padding(8)
            } else {
                Text("No file loaded").foregroundStyle(.secondary).frame(maxHeight: .infinity)
            }
        }
    }

    private func visibility(of id: STEP.BodyID) -> Binding<Bool> {
        Binding(get: { !viewer.hiddenBodies.contains(id) },
                set: { if $0 { viewer.hiddenBodies.remove(id) } else { viewer.hiddenBodies.insert(id) } })
    }

    private func detail(of body: STEP.Body) -> String {
        var parts: [String] = []
        if let size = body.bounds?.size {
            parts.append(String(format: "%.1f × %.1f × %.1f mm", size.x, size.y, size.z))
        }
        parts.append("\(body.edges.count) edges")
        if let mesh = body.mesh { parts.append("\(mesh.triangleCount) tri") }
        return parts.joined(separator: ", ")
    }
}
