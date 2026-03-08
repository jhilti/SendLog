import PhotosUI
import SwiftUI
import UIKit

struct WallDetailView: View {
    @EnvironmentObject private var store: AppStore

    let wallID: UUID

    @State private var isCreatingBoulder = false
    @State private var isDetectingHolds = false
    @State private var isEditingHolds = false
    @State private var isAddModeEnabled = false
    @State private var isContourDrawModeEnabled = false
    @State private var contourUndoRequestID = 0
    @State private var selectedEditableHoldID: UUID?
    @State private var isShowingDeleteAllHoldsConfirmation = false
    @State private var previewBoulder: Boulder?
    @State private var editingBoulder: Boulder?
    @State private var selectedMaskItem: PhotosPickerItem?
    @State private var isSavingWallMask = false
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
                                editableHoldID: selectedEditableHoldID,
                                onHoldTap: (isEditingHolds && isAddModeEnabled && !isContourDrawModeEnabled) ? { hold in
                                    handleEditableHoldTap(hold)
                                } : (isEditingHolds && !isAddModeEnabled) ? { hold in
                                    handleHoldTap(hold)
                                } : nil,
                                onHoldDoubleTap: (isEditingHolds && isAddModeEnabled && !isContourDrawModeEnabled) ? { hold in
                                    handleEditableHoldDoubleTap(hold)
                                } : nil,
                                onEmptyImageTap: (isEditingHolds && isAddModeEnabled && !isContourDrawModeEnabled) ? { _ in
                                    handleEditableEmptyTap()
                                } : nil,
                                onEmptyImageDoubleTap: (isEditingHolds && isAddModeEnabled && !isContourDrawModeEnabled) ? { point in
                                    handleEditableImageDoubleTap(point)
                                } : nil,
                                onHoldDragEnd: (isEditingHolds && isAddModeEnabled && !isContourDrawModeEnabled) ? { hold, point in
                                    handleEditableHoldMove(hold: hold, to: point)
                                } : nil,
                                onContourComplete: (isEditingHolds && isAddModeEnabled && isContourDrawModeEnabled) ? { points in
                                    handleContourDraw(points)
                                } : nil,
                                onContourUndo: (isEditingHolds && isAddModeEnabled && isContourDrawModeEnabled) ? {
                                    handleContourUndo()
                                } : nil,
                                contourUndoRequestID: contourUndoRequestID,
                                isZoomEnabled: true,
                                isContourDrawEnabled: isEditingHolds && isAddModeEnabled && isContourDrawModeEnabled,
                                nearestSelectionEnabled: !isAddModeEnabled && !isContourDrawModeEnabled,
                                showInlineContourUndoButton: false,
                                cornerRadius: 0
                            )

                            VStack(alignment: .leading, spacing: 16) {
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
                        .padding(.bottom, 12)
                    }
                    .navigationTitle(wall.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .contentMargins(.top, 0, for: .scrollContent)
                    .contentMargins(.top, 0, for: .scrollIndicators)
                    .ignoresSafeArea(edges: .top)
                    .overlay(alignment: .bottomTrailing) {
                        if isEditingHolds && isAddModeEnabled && isContourDrawModeEnabled {
                            Button {
                                contourUndoRequestID += 1
                            } label: {
                                Label("Undo", systemImage: "arrow.uturn.backward")
                                    .font(.headline.weight(.semibold))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                        }
                    }
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
                    .fullScreenCover(item: $previewBoulder) { boulder in
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
                        Text("This removes every detected and manual hold marker.")
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
                    .onChange(of: selectedMaskItem) { _, item in
                        guard let item else { return }
                        Task {
                            await loadWallMask(from: item)
                        }
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
                    Label(isDetectingHolds ? "Detecting..." : "Auto-Detect Holds", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDetectingHolds)

                Button(isEditingHolds ? "Done Editing" : "Edit Holds") {
                    withAnimation {
                        isEditingHolds.toggle()
                        if !isEditingHolds {
                            isAddModeEnabled = false
                            isContourDrawModeEnabled = false
                            selectedEditableHoldID = nil
                        }
                    }
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                PhotosPicker(selection: $selectedMaskItem, matching: .images, photoLibrary: .shared()) {
                    Label(
                        wall.maskFilename == nil ? "Set Wall Mask" : "Replace Wall Mask",
                        systemImage: "photo.badge.checkmark"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isSavingWallMask)

                if wall.maskFilename != nil {
                    Button(role: .destructive) {
                        clearWallMask()
                    } label: {
                        Label("Remove Mask", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSavingWallMask)
                }
            }

            Text(
                wall.maskFilename == nil
                    ? "Optional: import a black/white wall mask to restrict hold detection to the wall area."
                    : "Wall mask enabled. Auto-detect and tap-to-segment now run only inside the masked area."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            if isEditingHolds {
                Toggle(
                    "Add Hold Mode",
                    isOn: Binding(
                        get: { isAddModeEnabled },
                        set: { enabled in
                            isAddModeEnabled = enabled
                            if !enabled {
                                isContourDrawModeEnabled = false
                                selectedEditableHoldID = nil
                            }
                        }
                    )
                )

                if isAddModeEnabled {
                    Toggle(
                        "Draw Contour",
                        isOn: Binding(
                            get: { isContourDrawModeEnabled },
                            set: { enabled in
                                isContourDrawModeEnabled = enabled
                                if enabled {
                                    selectedEditableHoldID = nil
                                }
                            }
                        )
                    )
                    Text(
                        isContourDrawModeEnabled
                            ? "Draw around a hold with one finger. Double-tap to toggle Move mode, then drag to pan. Pinch to zoom. Release to save."
                            : "Double-tap to add/remove glowing markers. Tap a marker to select, tap empty space to deselect, then drag to move."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Tap a hold to remove it.")
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
                }
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
                if selectedEditableHoldID == hold.id {
                    selectedEditableHoldID = nil
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleEditableHoldTap(_ hold: Hold) {
        guard isEditingHolds, isAddModeEnabled, !isContourDrawModeEnabled else {
            return
        }
        selectedEditableHoldID = hold.id
    }

    private func handleEditableEmptyTap() {
        guard isEditingHolds, isAddModeEnabled, !isContourDrawModeEnabled else {
            return
        }
        selectedEditableHoldID = nil
    }

    private func handleEditableHoldDoubleTap(_ hold: Hold) {
        guard isEditingHolds, isAddModeEnabled, !isContourDrawModeEnabled else {
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

    private func handleEditableImageDoubleTap(_ point: CGPoint) {
        guard isEditingHolds, isAddModeEnabled, !isContourDrawModeEnabled else {
            return
        }

        Task {
            do {
                let newHoldID = try await store.addManualMarkerHold(wallID: wallID, at: point)
                selectedEditableHoldID = newHoldID
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleEditableHoldMove(hold: Hold, to point: CGPoint) {
        guard isEditingHolds, isAddModeEnabled, !isContourDrawModeEnabled else {
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

    private func handleContourDraw(_ points: [CGPoint]) {
        guard isEditingHolds, isAddModeEnabled, isContourDrawModeEnabled else {
            return
        }

        Task {
            do {
                try await store.addManualHoldContour(wallID: wallID, points: points)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleContourUndo() {
        guard isEditingHolds, isAddModeEnabled, isContourDrawModeEnabled else {
            return
        }

        Task {
            do {
                try await store.removeLastManualHold(wallID: wallID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteAllHolds() {
        Task {
            do {
                try await store.removeAllHolds(wallID: wallID)
                isContourDrawModeEnabled = false
                isAddModeEnabled = false
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

    private func clearWallMask() {
        isSavingWallMask = true
        Task {
            do {
                try await store.clearWallMask(wallID: wallID)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSavingWallMask = false
        }
    }

    private func loadWallMask(from item: PhotosPickerItem) async {
        isSavingWallMask = true
        defer {
            isSavingWallMask = false
            selectedMaskItem = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  UIImage(data: data) != nil else {
                errorMessage = "Could not load the selected mask image."
                return
            }

            try await store.setWallMask(wallID: wallID, imageData: data)
        } catch {
            errorMessage = "Mask import failed: \(error.localizedDescription)"
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
                Text("\(boulder.grade) • \(boulder.holdIDs.count) holds • \(boulder.tickCount) ticks")
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

private struct BoulderPreviewSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let wall: Wall
    let image: UIImage
    let boulder: Boulder
    @State private var tickCount: Int
    @State private var isUpdatingTick = false
    @State private var errorMessage: String?

    init(wall: Wall, image: UIImage, boulder: Boulder) {
        self.wall = wall
        self.image = image
        self.boulder = boulder
        _tickCount = State(initialValue: boulder.tickCount)
    }

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
                        Text("\(boulder.grade) • \(boulder.holdIDs.count) holds • \(tickCount) ticks")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button {
                                updateTick(increment: true)
                            } label: {
                                Label("Tick", systemImage: "checkmark.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isUpdatingTick)

                            Button {
                                updateTick(increment: false)
                            } label: {
                                Label("Undo Tick", systemImage: "arrow.uturn.backward.circle")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isUpdatingTick || tickCount == 0)
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

    private func updateTick(increment: Bool) {
        isUpdatingTick = true
        errorMessage = nil

        Task {
            do {
                if increment {
                    try await store.incrementBoulderTick(wallID: boulder.wallID, boulderID: boulder.id)
                    tickCount += 1
                } else {
                    try await store.decrementBoulderTick(wallID: boulder.wallID, boulderID: boulder.id)
                    tickCount = max(0, tickCount - 1)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isUpdatingTick = false
        }
    }
}
