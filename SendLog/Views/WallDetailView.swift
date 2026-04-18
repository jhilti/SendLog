import PhotosUI
import SwiftUI
import UIKit
import AudioToolbox

struct WallDetailView: View {
    @EnvironmentObject private var store: AppStore

    let wallID: UUID

    @State private var isCreatingBoulder = false
    @State private var isDetectingHolds = false
    @State private var isEditingHolds = false
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
                                showsInactiveHolds: isEditingHolds,
                                editableHoldID: selectedEditableHoldID,
                                onHoldTap: isEditingHolds ? { hold in
                                    handleEditableHoldTap(hold)
                                } : nil,
                                onHoldDelete: isEditingHolds ? { hold in
                                    handleHoldTap(hold)
                                } : nil,
                                onEmptyImageTap: isEditingHolds ? { _ in
                                    handleEditableEmptyTap()
                                } : nil,
                                onEmptyImageDoubleTap: isEditingHolds ? { point in
                                    handleEditableImageDoubleTap(point)
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
                        Text("This removes every detected and manual hold box.")
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
                    : "Wall mask enabled. Auto-detect now runs only inside the masked area."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            if isEditingHolds {
                Text("Tap a hold to select it. Double-tap empty space to add a box. Use the corner controls to delete, move, or resize.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

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
        guard isEditingHolds else {
            return
        }
        selectedEditableHoldID = hold.id
    }

    private func handleEditableEmptyTap() {
        guard isEditingHolds else {
            return
        }
        selectedEditableHoldID = nil
    }

    private func handleEditableImageDoubleTap(_ point: CGPoint) {
        guard isEditingHolds else {
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
