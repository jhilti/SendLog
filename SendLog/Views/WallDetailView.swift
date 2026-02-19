import SwiftUI
import UIKit

struct WallDetailView: View {
    @EnvironmentObject private var store: AppStore

    let wallID: UUID

    @State private var isCreatingBoulder = false
    @State private var isDetectingHolds = false
    @State private var isEditingHolds = false
    @State private var isAddModeEnabled = false
    @State private var previewBoulder: Boulder?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let wall = store.wall(withID: wallID), let image = store.image(for: wall) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        WallCanvasView(
                            image: image,
                            holds: wall.holds,
                            selectedHoldIDs: [],
                            onHoldTap: { hold in
                                handleHoldTap(hold)
                            },
                            onEmptyImageTap: { point in
                                handleImageTap(point)
                            },
                            isZoomEnabled: isEditingHolds && isAddModeEnabled
                        )

                        controlPanel(for: wall)

                        Text("Problems")
                            .font(.title3.weight(.semibold))
                        Text("Tap a problem to preview its selected holds.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if wall.boulders.isEmpty {
                            Text("No saved problems yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(wall.boulders) { boulder in
                                    BoulderRow(
                                        boulder: boulder,
                                        onSelect: {
                                            previewBoulder = boulder
                                        },
                                        onDelete: {
                                            deleteBoulder(boulderID: boulder.id)
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .padding()
                }
                .navigationTitle(wall.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isCreatingBoulder = true
                        } label: {
                            Label("New Problem", systemImage: "plus")
                        }
                        .disabled(wall.holds.isEmpty)
                    }
                }
                .sheet(isPresented: $isCreatingBoulder) {
                    BoulderComposerView(wallID: wallID)
                }
                .sheet(item: $previewBoulder) { boulder in
                    if let wall = store.wall(withID: wallID),
                       let image = store.image(for: wall) {
                        BoulderPreviewSheet(wall: wall, image: image, boulder: boulder)
                    } else {
                        ContentUnavailableView(
                            "Wall Not Available",
                            systemImage: "exclamationmark.triangle",
                            description: Text("Could not load this wall.")
                        )
                    }
                }
                .alert("Error", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { newValue in
                        if !newValue { errorMessage = nil }
                    }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "Unknown error")
                }
            } else {
                ContentUnavailableView(
                    "Wall Not Found",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This wall no longer exists or the image could not be loaded.")
                )
            }
        }
    }

    @ViewBuilder
    private func controlPanel(for wall: Wall) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    detectHolds()
                } label: {
                    Label(isDetectingHolds ? "Detecting..." : "Auto-Detect Holds", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDetectingHolds)

                Button(isEditingHolds ? "Done Editing" : "Edit Holds") {
                    withAnimation {
                        isEditingHolds.toggle()
                        if !isEditingHolds {
                            isAddModeEnabled = false
                        }
                    }
                }
                .buttonStyle(.bordered)
            }

            if isEditingHolds {
                Toggle("Add Hold Mode", isOn: $isAddModeEnabled)
                Text("Tap a hold to remove it. In Add Hold Mode, pinch to zoom, pan, and tap empty wall space to add a hold.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("\(wall.holds.count) holds detected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func detectHolds() {
        isDetectingHolds = true
        Task {
            do {
                try await store.detectHolds(for: wallID)
            } catch {
                errorMessage = error.localizedDescription
            }
            isDetectingHolds = false
        }
    }

    private func handleHoldTap(_ hold: Hold) {
        guard isEditingHolds else {
            return
        }

        Task {
            do {
                try await store.removeHold(wallID: wallID, holdID: hold.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleImageTap(_ point: CGPoint) {
        guard isEditingHolds, isAddModeEnabled else {
            return
        }

        Task {
            do {
                try await store.addManualHold(wallID: wallID, at: point)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteBoulder(boulderID: UUID) {
        Task {
            do {
                try await store.deleteBoulder(wallID: wallID, boulderID: boulderID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct BoulderRow: View {
    let boulder: Boulder
    let onSelect: () -> Void
    let onDelete: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(boulder.name)
                    .font(.headline)
                Text("\(boulder.grade) • \(boulder.holdIDs.count) holds")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !boulder.notes.isEmpty {
                    Text(boulder.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(boulder.createdAt, formatter: Self.dateFormatter)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

private struct BoulderPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let wall: Wall
    let image: UIImage
    let boulder: Boulder

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WallCanvasView(
                        image: image,
                        holds: wall.holds,
                        selectedHoldIDs: Set(boulder.holdIDs),
                        onHoldTap: nil,
                        onEmptyImageTap: nil
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text(boulder.name)
                            .font(.title3.weight(.semibold))
                        Text("\(boulder.grade) • \(boulder.holdIDs.count) holds")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if !boulder.notes.isEmpty {
                            Text(boulder.notes)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Problem Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
