import SwiftUI

struct BoulderComposerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let wallID: UUID

    @State private var selectedHoldIDs: Set<UUID> = []
    @State private var name = ""
    @State private var selectedGrade: ClimbingGrade = .sixA
    @State private var notes = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let wall = store.wall(withID: wallID), let image = store.image(for: wall) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            WallCanvasView(
                                image: image,
                                holds: wall.holds,
                                selectedHoldIDs: selectedHoldIDs,
                                onHoldTap: { hold in
                                    toggleSelection(for: hold.id)
                                },
                                onEmptyImageTap: { _ in }
                            )
                            .frame(maxHeight: 420)

                            Text("Selected holds: \(selectedHoldIDs.count)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 10) {
                                TextField("Problem name", text: $name)
                                    .textFieldStyle(.roundedBorder)

                                Picker("Grade", selection: $selectedGrade) {
                                    ForEach(ClimbingGrade.allCases) { grade in
                                        Text(grade.rawValue).tag(grade)
                                    }
                                }
                                .pickerStyle(.menu)

                                TextField("Notes", text: $notes, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(2...4)
                            }

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "Wall Not Available",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Could not load this wall.")
                    )
                }
            }
            .navigationTitle("New Problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !isSaving
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedHoldIDs.isEmpty
    }

    private func toggleSelection(for holdID: UUID) {
        if selectedHoldIDs.contains(holdID) {
            selectedHoldIDs.remove(holdID)
        } else {
            selectedHoldIDs.insert(holdID)
        }
    }

    private func save() {
        isSaving = true

        Task {
            do {
                let orderedIDs = selectedHoldIDs.sorted { $0.uuidString < $1.uuidString }
                try await store.saveBoulder(
                    wallID: wallID,
                    name: name,
                    grade: selectedGrade.rawValue,
                    notes: notes,
                    holdIDs: orderedIDs
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
