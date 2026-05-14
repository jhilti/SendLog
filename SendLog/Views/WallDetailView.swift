import SwiftUI
import UIKit
import AudioToolbox

struct WallDetailView: View {
    @EnvironmentObject private var store: AppStore

    let wallID: UUID

    @State private var isCreatingBoulder = false
    @State private var isDetectingHolds = false
    @State private var isFittingHold = false
    @State private var isEditingHolds = false
    @State private var selectedEditableHoldID: UUID?
    @State private var pendingHoldDetectionPoint: CGPoint?
    @State private var isShowingDeleteAllHoldsConfirmation = false
    @State private var isShowingBoulderImport = false
    @State private var previewBoulder: Boulder?
    @State private var editingBoulder: Boulder?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if let wall = store.wall(withID: wallID), let image = store.image(for: wall) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            WallCanvasView(
                                image: image,
                                holds: wall.holds,
                                selectedHoldIDs: [],
                                showsInactiveHolds: isEditingHolds || !wall.holds.isEmpty,
                                editableHoldID: selectedEditableHoldID,
                                onHoldTap: isEditingHolds ? { hold in
                                    handleEditableHoldTap(hold)
                                } : nil,
                                onHoldDelete: isEditingHolds ? { hold in
                                    handleHoldTap(hold)
                                } : nil,
                                onEmptyImageTap: isEditingHolds && !isFittingHold ? { point in
                                    handleEditableImageTap(point)
                                } : nil,
                                onEmptyImageDoubleTap: isEditingHolds && !isFittingHold ? { point in
                                    handleEditableImageTap(point)
                                } : nil,
                                onHoldDragEnd: isEditingHolds ? { hold, point in
                                    handleEditableHoldMove(hold: hold, to: point)
                                } : nil,
                                onHoldResizeEnd: isEditingHolds ? { hold, rect in
                                    handleEditableHoldResize(hold: hold, to: rect)
                                } : nil,
                                isZoomEnabled: true,
                                isContourDrawEnabled: false,
                                nearestSelectionEnabled: !isEditingHolds,
                                showInlineContourUndoButton: false,
                                cornerRadius: 0,
                                pendingHoldDetectionPoint: pendingHoldDetectionPoint
                            )

                            controlPanel(for: wall)
                                .padding(.horizontal)

                            VStack(alignment: .leading, spacing: 16) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Problems")
                                        .font(.title3.weight(.semibold))

                                    Spacer()

                                    Button {
                                        isShowingBoulderImport = true
                                    } label: {
                                        Label("Import From Other Walls", systemImage: "square.and.arrow.down")
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .buttonStyle(.bordered)
                                    .disabled(wall.holds.isEmpty)
                                }

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
                                                onEdit: {
                                                    editingBoulder = boulder
                                                },
                                                onDelete: {
                                                    deleteBoulder(boulderID: boulder.id)
                                                }
                                            )
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 40)
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
                    .fullScreenCover(isPresented: $isCreatingBoulder) {
                        BoulderComposerView(wallID: wallID)
                    }
                    .fullScreenCover(item: $editingBoulder) { boulder in
                        BoulderComposerView(wallID: wallID, editingBoulder: boulder)
                    }
                    .sheet(isPresented: $isShowingBoulderImport) {
                        BoulderImportSheet(wallID: wallID)
                            .environmentObject(store)
                    }
                    .fullScreenCover(item: $previewBoulder) { boulder in
                        if let wall = store.wall(withID: wallID),
                           let image = store.image(for: wall) {
                            BoulderPreviewSheet(
                                wallID: wallID,
                                image: image,
                                initialBoulderID: boulder.id
                            )
                        } else {
                            ContentUnavailableView(
                                "Wall Not Available",
                                systemImage: "exclamationmark.triangle",
                                description: Text("Could not load this wall.")
                            )
                        }
                    }
                    .confirmationDialog(
                        "Delete all holds on this wall?",
                        isPresented: $isShowingDeleteAllHoldsConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Delete All Holds", role: .destructive) {
                            deleteAllHolds()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes every hold box on this wall.")
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
    }

    @ViewBuilder
    private func controlPanel(for wall: Wall) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    detectHolds()
                } label: {
                    Label(isDetectingHolds ? "Detecting..." : "Detect Holds", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDetectingHolds || isFittingHold)

                Button(isEditingHolds ? "Done Editing" : "Edit Holds") {
                    withAnimation {
                        isEditingHolds.toggle()
                        if !isEditingHolds {
                            selectedEditableHoldID = nil
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isDetectingHolds || isFittingHold)
            }

            if isEditingHolds {
                if isFittingHold {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Fitting hold...")
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Text("Tap an unmarked hold to auto-fit a box. Tap a marked box to select it. Use the corner controls to delete, move, or resize.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !wall.holds.isEmpty {
                    Button(role: .destructive) {
                        isShowingDeleteAllHoldsConfirmation = true
                    } label: {
                        Label("Delete All Holds", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isFittingHold)
                }
            }

            Text("\(wall.holds.count) holds marked")
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
                if selectedEditableHoldID == hold.id {
                    selectedEditableHoldID = nil
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleEditableHoldTap(_ hold: Hold) {
        guard isEditingHolds else {
            return
        }
        selectedEditableHoldID = hold.id
    }

    private func handleEditableImageTap(_ point: CGPoint) {
        guard isEditingHolds, !isFittingHold else {
            return
        }

        if selectedEditableHoldID != nil {
            selectedEditableHoldID = nil
            return
        }

        isFittingHold = true
        pendingHoldDetectionPoint = point
        Task {
            do {
                let newHoldID = try await store.addSmartMarkerHold(wallID: wallID, at: point)
                await MainActor.run {
                    selectedEditableHoldID = newHoldID
                    isFittingHold = false
                    pendingHoldDetectionPoint = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isFittingHold = false
                    pendingHoldDetectionPoint = nil
                }
            }
        }
    }

    private func handleEditableHoldMove(hold: Hold, to point: CGPoint) {
        guard isEditingHolds else {
            return
        }

        Task {
            do {
                try await store.moveHold(wallID: wallID, holdID: hold.id, to: point)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleEditableHoldResize(hold: Hold, to rect: NormalizedRect) {
        guard isEditingHolds else {
            return
        }

        Task {
            do {
                try await store.resizeHold(wallID: wallID, holdID: hold.id, to: rect)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteAllHolds() {
        Task {
            do {
                try await store.removeAllHolds(wallID: wallID)
                selectedEditableHoldID = nil
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
    let onEdit: () -> Void
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
                Text("\(boulder.grade) • \(boulder.holdIDs.count) holds • \(boulder.attemptCount) attempts • \(boulder.tickCount) ticks")
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

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)

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

private struct BoulderImportSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let wallID: UUID

    @State private var selectedCandidateIDs = Set<String>()
    @State private var initializedSelection = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var editedMatchedHoldIDsByCandidateID: [String: [UUID]] = [:]
    @State private var compareCandidate: BoulderImportCandidate?

    var body: some View {
        NavigationStack {
            let candidates = store.boulderImportCandidates(for: wallID)
            let effectiveCandidates = candidates.map(effectiveCandidate)

            Group {
                if effectiveCandidates.isEmpty {
                    ContentUnavailableView(
                        "No Importable Problems",
                        systemImage: "square.and.arrow.down",
                        description: Text("Mark holds on this wall and keep older walls with saved problems to import from.")
                    )
                } else {
                    List {
                        Section {
                            Text(summaryText(for: effectiveCandidates))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(groups(from: effectiveCandidates)) { group in
                            Section {
                                ForEach(group.candidates) { candidate in
                                    BoulderImportCandidateRow(
                                        candidate: candidate,
                                        isSelected: selectedCandidateIDs.contains(candidate.id),
                                        showsCompareButton: !candidate.isComplete || editedMatchedHoldIDsByCandidateID[candidate.id] != nil
                                    ) {
                                        toggle(candidate)
                                    } onCompare: {
                                        compareCandidate = candidate
                                    }
                                }
                            } header: {
                                Text(group.title)
                            } footer: {
                                Text(group.footer)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Import Problems")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(importButtonTitle) {
                        importSelected(from: effectiveCandidates)
                    }
                    .disabled(selectedCandidateIDs.isEmpty || isImporting)
                }
            }
            .onAppear {
                initializeSelectionIfNeeded(effectiveCandidates)
            }
            .onChange(of: candidates) { _, updatedCandidates in
                let updatedEffectiveCandidates = updatedCandidates.map(effectiveCandidate)
                initializeSelectionIfNeeded(updatedEffectiveCandidates)
                selectedCandidateIDs.formIntersection(Set(updatedEffectiveCandidates.map(\.id)))
                editedMatchedHoldIDsByCandidateID = editedMatchedHoldIDsByCandidateID.filter { candidateID, _ in
                    updatedEffectiveCandidates.contains { $0.id == candidateID }
                }
            }
            .sheet(item: $compareCandidate) { candidate in
                BoulderImportCompareEditSheet(
                    wallID: wallID,
                    candidate: effectiveCandidate(candidate)
                ) { holdIDs in
                    update(candidate, with: holdIDs)
                }
                .environmentObject(store)
            }
            .alert("Import Failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { newValue in
                    if !newValue { errorMessage = nil }
                }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
        .sessionTimerOverlay()
    }

    private var importButtonTitle: String {
        if isImporting {
            return "Importing..."
        }
        let count = selectedCandidateIDs.count
        return count == 1 ? "Import 1" : "Import \(count)"
    }

    private func initializeSelectionIfNeeded(_ candidates: [BoulderImportCandidate]) {
        guard !initializedSelection else {
            return
        }
        selectedCandidateIDs = Set(candidates.filter(\.isComplete).map(\.id))
        initializedSelection = true
    }

    private func effectiveCandidate(_ candidate: BoulderImportCandidate) -> BoulderImportCandidate {
        guard let editedHoldIDs = editedMatchedHoldIDsByCandidateID[candidate.id] else {
            return candidate
        }

        let uniqueHoldIDs = Array(NSOrderedSet(array: editedHoldIDs).compactMap { $0 as? UUID })
        return BoulderImportCandidate(
            id: candidate.id,
            sourceWallID: candidate.sourceWallID,
            sourceWallName: candidate.sourceWallName,
            sourceBoulder: candidate.sourceBoulder,
            matchedHoldIDs: uniqueHoldIDs,
            missingHoldCount: max(0, candidate.totalHoldCount - uniqueHoldIDs.count),
            totalHoldCount: candidate.totalHoldCount
        )
    }

    private func toggle(_ candidate: BoulderImportCandidate) {
        guard candidate.matchedHoldCount > 0 else {
            return
        }
        if selectedCandidateIDs.contains(candidate.id) {
            selectedCandidateIDs.remove(candidate.id)
        } else {
            selectedCandidateIDs.insert(candidate.id)
        }
    }

    private func update(_ candidate: BoulderImportCandidate, with holdIDs: [UUID]) {
        editedMatchedHoldIDsByCandidateID[candidate.id] = holdIDs
        if holdIDs.isEmpty {
            selectedCandidateIDs.remove(candidate.id)
        } else {
            selectedCandidateIDs.insert(candidate.id)
        }
        compareCandidate = nil
    }

    private func importSelected(from candidates: [BoulderImportCandidate]) {
        let selected = candidates.filter { selectedCandidateIDs.contains($0.id) }
        guard !selected.isEmpty else {
            return
        }

        isImporting = true
        Task {
            do {
                _ = try await store.importBoulders(selected, into: wallID)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isImporting = false
            }
        }
    }

    private func summaryText(for candidates: [BoulderImportCandidate]) -> String {
        let completeCount = candidates.filter(\.isComplete).count
        let partialCount = candidates.count - completeCount
        let completeText = completeCount == 1 ? "1 problem can be imported completely" : "\(completeCount) problems can be imported completely"
        let partialText = partialCount == 1 ? "1 problem has missing or changed holds" : "\(partialCount) problems have missing or changed holds"
        return "\(completeText). \(partialText). Partial imports keep only the matched holds."
    }

    private func groups(from candidates: [BoulderImportCandidate]) -> [BoulderImportGroup] {
        let grouped = Dictionary(grouping: candidates, by: \.sourceWallID)
        return grouped.values
            .compactMap { candidates in
                guard let first = candidates.first else {
                    return nil
                }
                let sorted = candidates.sorted { lhs, rhs in
                    if lhs.isComplete != rhs.isComplete {
                        return lhs.isComplete
                    }
                    if lhs.missingHoldCount != rhs.missingHoldCount {
                        return lhs.missingHoldCount < rhs.missingHoldCount
                    }
                    return lhs.sourceBoulder.name.localizedCaseInsensitiveCompare(rhs.sourceBoulder.name) == .orderedAscending
                }
                let completeCount = sorted.filter(\.isComplete).count
                let partialCount = sorted.count - completeCount
                return BoulderImportGroup(
                    sourceWallID: first.sourceWallID,
                    title: first.sourceWallName,
                    footer: "\(completeCount) complete, \(partialCount) missing or changed.",
                    candidates: sorted
                )
            }
            .sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }
}

private struct BoulderImportGroup: Identifiable {
    let sourceWallID: UUID
    let title: String
    let footer: String
    let candidates: [BoulderImportCandidate]

    var id: UUID {
        sourceWallID
    }
}

private struct BoulderImportCandidateRow: View {
    let candidate: BoulderImportCandidate
    let isSelected: Bool
    let showsCompareButton: Bool
    let onToggle: () -> Void
    let onCompare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? .green : .secondary)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(candidate.sourceBoulder.name)
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Text(candidate.sourceBoulder.grade)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.secondary.opacity(0.18), in: Capsule())
                        }

                        Text(statusText)
                            .font(.subheadline)
                            .foregroundStyle(candidate.isComplete ? .green : .orange)

                        if !candidate.sourceBoulder.notes.isEmpty {
                            Text(candidate.sourceBoulder.notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsCompareButton {
                Button(action: onCompare) {
                    Label("Compare & Edit", systemImage: "rectangle.split.2x1")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var statusText: String {
        if candidate.isComplete {
            return "All \(candidate.totalHoldCount) holds present"
        }
        let missing = candidate.missingHoldCount == 1 ? "1 missing/changed hold" : "\(candidate.missingHoldCount) missing/changed holds"
        return "\(candidate.matchedHoldCount)/\(candidate.totalHoldCount) holds matched, \(missing)"
    }
}

private struct BoulderImportCompareEditSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let wallID: UUID
    let candidate: BoulderImportCandidate
    let onSave: ([UUID]) -> Void

    @State private var selectedTargetHoldIDs: Set<UUID>

    init(wallID: UUID, candidate: BoulderImportCandidate, onSave: @escaping ([UUID]) -> Void) {
        self.wallID = wallID
        self.candidate = candidate
        self.onSave = onSave
        _selectedTargetHoldIDs = State(initialValue: Set(candidate.matchedHoldIDs))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let sourceWall,
                   let targetWall,
                   let sourceImage = store.image(for: sourceWall),
                   let targetImage = store.image(for: targetWall) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            header

                            VStack(alignment: .leading, spacing: 8) {
                                Label("Original problem", systemImage: "1.circle")
                                    .font(.headline)
                                WallCanvasView(
                                    image: sourceImage,
                                    holds: sourceWall.holds,
                                    selectedHoldIDs: Set(candidate.sourceBoulder.holdIDs),
                                    showsInactiveHolds: false,
                                    onHoldTap: nil,
                                    onEmptyImageTap: nil,
                                    isZoomEnabled: true,
                                    cornerRadius: 10
                                )
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Label("Current wall", systemImage: "2.circle")
                                    .font(.headline)
                                Text("Tap holds to add or remove them from this imported problem.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)

                                WallCanvasView(
                                    image: targetImage,
                                    holds: targetWall.holds,
                                    selectedHoldIDs: selectedTargetHoldIDs,
                                    showsInactiveHolds: true,
                                    onHoldTap: { hold in
                                        toggle(hold)
                                    },
                                    onEmptyImageTap: nil,
                                    isZoomEnabled: true,
                                    cornerRadius: 10
                                )
                            }

                            HStack(spacing: 10) {
                                Button {
                                    selectedTargetHoldIDs = Set(candidate.matchedHoldIDs)
                                } label: {
                                    Label("Reset Auto", systemImage: "arrow.counterclockwise")
                                }
                                .buttonStyle(.bordered)

                                Button(role: .destructive) {
                                    selectedTargetHoldIDs = []
                                } label: {
                                    Label("Clear", systemImage: "xmark.circle")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "Walls Not Available",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Could not load one of the wall images for comparison.")
                    )
                }
            }
            .navigationTitle("Compare & Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use \(selectedTargetHoldIDs.count)") {
                        onSave(Array(selectedTargetHoldIDs))
                        dismiss()
                    }
                    .disabled(selectedTargetHoldIDs.isEmpty)
                }
            }
        }
        .sessionTimerOverlay()
    }

    private var sourceWall: Wall? {
        store.wall(withID: candidate.sourceWallID)
    }

    private var targetWall: Wall? {
        store.wall(withID: wallID)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(candidate.sourceBoulder.name)
                    .font(.title3.weight(.semibold))
                Text(candidate.sourceBoulder.grade)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.18), in: Capsule())
            }

            Text("\(selectedTargetHoldIDs.count)/\(candidate.totalHoldCount) holds selected for import")
                .font(.subheadline)
                .foregroundStyle(selectedTargetHoldIDs.count >= candidate.totalHoldCount ? .green : .orange)
        }
    }

    private func toggle(_ hold: Hold) {
        if selectedTargetHoldIDs.contains(hold.id) {
            selectedTargetHoldIDs.remove(hold.id)
        } else {
            selectedTargetHoldIDs.insert(hold.id)
        }
    }
}

struct BoulderPreviewSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let wallID: UUID
    let image: UIImage
    @State private var currentBoulderID: UUID
    @State private var wallCanvasZoomScale: CGFloat = 1
    @State private var editingBoulder: Boulder?
    @State private var isUpdatingLog = false
    @State private var restTimerRemaining: TimeInterval = 4 * 60
    @State private var isRestTimerRunning = false
    @State private var restTimerLastTick: Date?
    @State private var didPingForRestCompletion = false
    @State private var errorMessage: String?

    private let restTimerTicker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    init(wallID: UUID, image: UIImage, initialBoulderID: UUID) {
        self.wallID = wallID
        self.image = image
        _currentBoulderID = State(initialValue: initialBoulderID)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let wall = currentWall, let boulder = currentBoulder {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            WallCanvasView(
                                image: image,
                                holds: wall.holds,
                                selectedHoldIDs: Set(boulder.holdIDs),
                                showsInactiveHolds: false,
                                onHoldTap: nil,
                                onEmptyImageTap: nil,
                                onZoomScaleChange: { scale in
                                    wallCanvasZoomScale = scale
                                }
                            )

                            VStack(alignment: .leading, spacing: 6) {
                                Text(boulder.name)
                                    .font(.title3.weight(.semibold))
                                Text("\(boulder.grade) • \(boulder.holdIDs.count) holds • \(boulder.attemptCount) attempts • \(boulder.tickCount) ticks")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("Swipe left or right to switch problems.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 10) {
                                    Button {
                                        updateLog(.attempt)
                                    } label: {
                                        Label("Attempt", systemImage: "plus.circle")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isUpdatingLog)

                                    Button {
                                        updateLog(.tick)
                                    } label: {
                                        Label("Tick", systemImage: "checkmark.circle.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(isUpdatingLog)
                                }

                                HStack(spacing: 10) {
                                    Button {
                                        updateLog(.undoAttempt)
                                    } label: {
                                        Label("Undo Attempt", systemImage: "arrow.uturn.backward")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isUpdatingLog || !hasUndoableAttemptOnlyLog)

                                    Button {
                                        updateLog(.undoTick)
                                    } label: {
                                        Label("Undo Tick", systemImage: "arrow.uturn.backward.circle")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isUpdatingLog || boulder.tickCount == 0)
                                }
                                if !boulder.notes.isEmpty {
                                    Text(boulder.notes)
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                }
                                if let errorMessage {
                                    Text(errorMessage)
                                        .font(.footnote)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        .padding()
                    }
                    .simultaneousGesture(problemSwipeGesture)
                    .onReceive(restTimerTicker) { now in
                        guard isRestTimerRunning else {
                            return
                        }

                        let referenceDate = restTimerLastTick ?? now
                        restTimerLastTick = now
                        restTimerRemaining = max(0, restTimerRemaining - now.timeIntervalSince(referenceDate))

                        guard restTimerRemaining <= 0 else {
                            return
                        }

                        restTimerRemaining = 0
                        isRestTimerRunning = false
                        restTimerLastTick = nil

                        guard !didPingForRestCompletion else {
                            return
                        }

                        didPingForRestCompletion = true
                        AudioServicesPlaySystemSound(1005)
                    }
                } else {
                    ContentUnavailableView(
                        "Problem Not Available",
                        systemImage: "exclamationmark.triangle",
                        description: Text("This problem no longer exists on the wall.")
                    )
                }
            }
            .navigationTitle("Problem Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let boulder = currentBoulder {
                        Button("Edit") {
                            editingBoulder = boulder
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .fullScreenCover(item: $editingBoulder) { boulder in
            BoulderComposerView(wallID: wallID, editingBoulder: boulder)
        }
        .overlay {
            GeometryReader { _ in
                restTimerBadge
                    .padding(.top, overlayTopPadding)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .sessionTimerOverlay()
    }

    private var currentWall: Wall? {
        store.wall(withID: wallID)
    }

    private var orderedBoulders: [Boulder] {
        currentWall?.boulders ?? []
    }

    private var currentBoulder: Boulder? {
        orderedBoulders.first { $0.id == currentBoulderID }
    }

    private var hasUndoableAttemptOnlyLog: Bool {
        currentBoulder?.logEntries.contains(where: { $0.attempts > 0 && $0.ticks == 0 }) ?? false
    }

    private var restTimerGesture: some Gesture {
        ExclusiveGesture(
            TapGesture(count: 2),
            TapGesture(count: 1)
        )
        .onEnded { result in
            switch result {
            case .first:
                resetRestTimer()
            case .second:
                toggleRestTimer()
            }
        }
    }

    @ViewBuilder
    private var restTimerBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: restTimerIconName)
                .font(.caption.weight(.bold))
                .foregroundStyle(restTimerTint)

            Text(formattedRestTimer)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(restTimerTint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
        .contentShape(Capsule())
        .gesture(restTimerGesture)
        .accessibilityLabel("Rest Timer")
        .accessibilityValue(formattedRestTimer)
        .accessibilityHint("Tap to start or pause. Double tap quickly to reset to four minutes.")
    }

    private var restTimerIconName: String {
        if isRestTimerRunning {
            return "pause.fill"
        }

        if restTimerRemaining <= 0 {
            return "bell.fill"
        }

        return "timer"
    }

    private var restTimerTint: Color {
        if restTimerRemaining <= 0 {
            return .red
        }

        return isRestTimerRunning ? .green : .primary
    }

    private var formattedRestTimer: String {
        let totalSeconds = max(0, Int(restTimerRemaining.rounded(.up)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var overlayTopPadding: CGFloat {
        let windowTopInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0

        return windowTopInset + 18
    }

    private var currentBoulderIndex: Int? {
        orderedBoulders.firstIndex { $0.id == currentBoulderID }
    }

    private var problemSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 28, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                let isZoomed = wallCanvasZoomScale > 1.01
                let directionRatio: CGFloat = isZoomed ? 2.4 : 1.35
                let distanceThreshold: CGFloat = isZoomed ? 180 : 90
                let predictedHorizontal = value.predictedEndTranslation.width
                let predictedThreshold: CGFloat = isZoomed ? 240 : 120

                guard abs(horizontal) > abs(vertical) * directionRatio,
                      abs(horizontal) > distanceThreshold,
                      abs(predictedHorizontal) > predictedThreshold else {
                    return
                }

                if horizontal < 0 {
                    showAdjacentBoulder(step: 1)
                } else {
                    showAdjacentBoulder(step: -1)
                }
            }
    }

    private enum BoulderLogAction {
        case attempt
        case tick
        case undoAttempt
        case undoTick
    }

    private func updateLog(_ action: BoulderLogAction) {
        guard let boulder = currentBoulder else {
            return
        }

        isUpdatingLog = true
        errorMessage = nil

        Task {
            do {
                switch action {
                case .attempt:
                    try await store.incrementBoulderAttempt(wallID: boulder.wallID, boulderID: boulder.id)
                case .tick:
                    try await store.incrementBoulderTick(wallID: boulder.wallID, boulderID: boulder.id)
                case .undoAttempt:
                    try await store.decrementBoulderAttempt(wallID: boulder.wallID, boulderID: boulder.id)
                case .undoTick:
                    try await store.decrementBoulderTick(wallID: boulder.wallID, boulderID: boulder.id)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isUpdatingLog = false
        }
    }

    private func toggleRestTimer() {
        if isRestTimerRunning {
            isRestTimerRunning = false
            restTimerLastTick = nil
            return
        }

        if restTimerRemaining <= 0 {
            restTimerRemaining = 4 * 60
        }

        didPingForRestCompletion = false
        restTimerLastTick = Date()
        isRestTimerRunning = true
    }

    private func resetRestTimer() {
        isRestTimerRunning = false
        restTimerLastTick = nil
        restTimerRemaining = 4 * 60
        didPingForRestCompletion = false
    }

    private func showAdjacentBoulder(step: Int) {
        guard let currentBoulderIndex else {
            return
        }

        let nextIndex = currentBoulderIndex + step
        guard orderedBoulders.indices.contains(nextIndex) else {
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            currentBoulderID = orderedBoulders[nextIndex].id
            errorMessage = nil
        }
    }
}
