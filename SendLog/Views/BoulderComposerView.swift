import SwiftUI

struct BoulderComposerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let wallID: UUID
    let editingBoulder: Boulder?

    @State private var primarySelectedHoldIDs: Set<UUID>
    @State private var secondarySelectedHoldIDs: Set<UUID>
    @State private var name: String
    @State private var selectedGrade: ClimbingGrade
    @State private var notes: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(wallID: UUID, editingBoulder: Boulder? = nil) {
        self.wallID = wallID
        self.editingBoulder = editingBoulder

        if let editingBoulder {
            _primarySelectedHoldIDs = State(initialValue: Set(editingBoulder.holdIDs))
            _secondarySelectedHoldIDs = State(initialValue: [])
            _name = State(initialValue: editingBoulder.name)
            _selectedGrade = State(initialValue: Self.grade(from: editingBoulder.grade))
            _notes = State(initialValue: editingBoulder.notes)
        } else {
            _primarySelectedHoldIDs = State(initialValue: [])
            _secondarySelectedHoldIDs = State(initialValue: [])
            _name = State(initialValue: "")
            _selectedGrade = State(initialValue: .sixA)
            _notes = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let wall = store.wall(withID: wallID), let image = store.image(for: wall) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            WallCanvasView(
                                image: image,
                                holds: wall.holds,
                                selectedHoldIDs: primarySelectedHoldIDs,
                                secondarySelectedHoldIDs: secondarySelectedHoldIDs,
                                showsInactiveHolds: false,
                                onHoldTap: { hold in
                                    cycleSelection(for: hold.id)
                                },
                                onEmptyImageTap: nil
                            )

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
            .navigationTitle(editingBoulder == nil ? "New Problem" : "Edit Problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveButtonTitle) {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private static func grade(from rawValue: String) -> ClimbingGrade {
        ClimbingGrade.allCases.first(where: { $0.rawValue == rawValue }) ?? .sixA
    }

    private var selectedHoldIDs: Set<UUID> {
        primarySelectedHoldIDs.union(secondarySelectedHoldIDs)
    }

    private var canSave: Bool {
        !isSaving
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedHoldIDs.isEmpty
    }

    private var saveButtonTitle: String {
        if isSaving {
            return editingBoulder == nil ? "Saving..." : "Updating..."
        }
        return editingBoulder == nil ? "Save" : "Update"
    }

    private func cycleSelection(for holdID: UUID) {
        if secondarySelectedHoldIDs.contains(holdID) {
            secondarySelectedHoldIDs.remove(holdID)
            return
        }
        if primarySelectedHoldIDs.contains(holdID) {
            primarySelectedHoldIDs.remove(holdID)
            secondarySelectedHoldIDs.insert(holdID)
            return
        }
        primarySelectedHoldIDs.insert(holdID)
    }

    private func save() {
        isSaving = true

        Task {
            do {
                let orderedIDs = selectedHoldIDs.sorted { $0.uuidString < $1.uuidString }
                if let editingBoulder {
                    try await store.updateBoulder(
                        wallID: wallID,
                        boulderID: editingBoulder.id,
                        name: name,
                        grade: selectedGrade.rawValue,
                        notes: notes,
                        holdIDs: orderedIDs
                    )
                } else {
                    try await store.saveBoulder(
                        wallID: wallID,
                        name: name,
                        grade: selectedGrade.rawValue,
                        notes: notes,
                        holdIDs: orderedIDs
                    )
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
