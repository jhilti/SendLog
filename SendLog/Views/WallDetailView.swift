import SwiftUI
import UIKit
import AudioToolbox
import PhotosUI

struct WallDetailView: View {
    @EnvironmentObject private var store: AppStore

    let wallID: UUID

    @State private var isCreatingBoulder = false
    @State private var isDetectingHolds = false
    @State private var isFittingHold = false
    @State private var isEditingHolds = false
    @State private var isEditingWallArea = false
    @State private var selectedEditableHoldID: UUID?
    @State private var draftWallAreaPoints: [NormalizedPoint] = []
    @State private var pendingHoldDetectionPoint: CGPoint?
    @State private var isShowingDeleteAllHoldsConfirmation = false
    @State private var isShowingBoulderImport = false
    @State private var isShowingCreateSet = false
    @State private var previewBoulder: Boulder?
    @State private var editingBoulder: Boulder?
    @State private var errorMessage: String?
    @State private var wallCanvasZoomScale: CGFloat = 1
    @State private var draftWallName = ""
    @State private var isShowingWallTools = false
    @FocusState private var isWallNameFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if let wall = store.wall(withID: wallID), let image = store.image(for: wall) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            WallCanvasView(
                                image: image,
                                holds: wall.holds,
                                selectedHoldIDs: [],
                                wallEdges: isEditingWallArea ? [] : wall.wallEdges,
                                draftWallArea: isEditingWallArea ? draftWallAreaPoints : [],
                                showsInactiveHolds: isEditingWallArea ? false : (isEditingHolds || !wall.holds.isEmpty),
                                editableHoldID: selectedEditableHoldID,
                                onHoldTap: isEditingHolds && !isEditingWallArea ? { hold in
                                    handleEditableHoldTap(hold)
                                } : nil,
                                onHoldDelete: isEditingHolds && !isEditingWallArea ? { hold in
                                    handleHoldTap(hold)
                                } : nil,
                                onEmptyImageTap: isEditingHolds && !isFittingHold && !isEditingWallArea ? { point in
                                    handleEditableImageTap(point)
                                } : nil,
                                onEmptyImageDoubleTap: isEditingHolds && !isFittingHold && !isEditingWallArea ? { point in
                                    handleEditableImageTap(point)
                                } : nil,
                                onHoldDragEnd: isEditingHolds && !isEditingWallArea ? { hold, point in
                                    handleEditableHoldMove(hold: hold, to: point)
                                } : nil,
                                onHoldResizeEnd: isEditingHolds && !isEditingWallArea ? { hold, rect in
                                    handleEditableHoldResize(hold: hold, to: rect)
                                } : nil,
                                onWallAreaTap: isEditingWallArea ? { point in
                                    appendWallAreaPoint(point)
                                } : nil,
                                isZoomEnabled: true,
                                isContourDrawEnabled: false,
                                nearestSelectionEnabled: !isEditingHolds,
                                showInlineContourUndoButton: false,
                                cornerRadius: 0,
                                pendingHoldDetectionPoint: pendingHoldDetectionPoint,
                                onZoomScaleChange: { scale in
                                    wallCanvasZoomScale = scale
                                }
                            )

                            wallToolsToggle
                                .padding(.horizontal)

                            if isShowingWallTools {
                                controlPanel(for: wall)
                                    .padding(.horizontal)
                            }

                            if wall.sets.count > 1 {
                                setPicker(for: wall)
                                    .padding(.horizontal)
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Problems")
                                        .font(.title3.weight(.semibold))

                                    Spacer()
                                }

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
                    .scrollDisabled(wallCanvasZoomScale > 1.01)
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            wallNameField(for: wall)
                        }

                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Menu {
                                ForEach(wall.sets) { set in
                                    Button {
                                        activateSet(set.id)
                                    } label: {
                                        Label(set.name, systemImage: set.id == wall.activeSetID ? "checkmark" : "square")
                                    }
                                }

                                Divider()

                                Button {
                                    isShowingCreateSet = true
                                } label: {
                                    Label("New Reset", systemImage: "plus.rectangle.on.rectangle")
                                }
                            } label: {
                                Label("Sets", systemImage: "rectangle.stack")
                            }

                            Button {
                                isCreatingBoulder = true
                            } label: {
                                Label("New Problem", systemImage: "plus")
                            }
                            .disabled(wall.holds.isEmpty)
                        }
                    }
                    .onAppear {
                        draftWallName = wall.name
                    }
                    .onChange(of: wall.name) { _, newName in
                        if !isWallNameFocused {
                            draftWallName = newName
                        }
                    }
                    .fullScreenCover(isPresented: $isCreatingBoulder) {
                        BoulderComposerView(wallID: wallID)
                    }
                    .sheet(isPresented: $isShowingCreateSet) {
                        CreateWallSetSheet(wallID: wallID)
                            .environmentObject(store)
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

    private var wallToolsToggle: some View {
        HStack {
            Spacer()

            Button {
                toggleWallTools()
            } label: {
                Image(systemName: isShowingWallTools ? "xmark" : "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(isShowingWallTools ? "Hide wall tools" : "Show wall tools")
            .disabled(isDetectingHolds || isFittingHold)
        }
    }

    private func wallNameField(for wall: Wall) -> some View {
        TextField("Wall name", text: $draftWallName)
            .font(.headline.weight(.semibold))
            .multilineTextAlignment(.center)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .frame(width: 190)
            .focused($isWallNameFocused)
            .onSubmit {
                saveWallName(currentName: wall.name)
            }
            .onChange(of: isWallNameFocused) { _, isFocused in
                if isFocused {
                    draftWallName = wall.name
                } else {
                    saveWallName(currentName: wall.name)
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
                    Label(holdDetectionButtonTitle(for: wall), systemImage: "sparkles")
                }
                .buttonStyle(WallToolButtonStyle(tone: .primary))
                .disabled(isDetectingHolds || isFittingHold || isEditingWallArea)

                Button {
                    withAnimation {
                        isEditingHolds.toggle()
                        if !isEditingHolds {
                            selectedEditableHoldID = nil
                        }
                    }
                } label: {
                    Label(isEditingHolds ? "Done Editing" : "Edit Holds", systemImage: "pencil")
                }
                .buttonStyle(WallToolButtonStyle(tone: .neutral))
                .disabled(isDetectingHolds || isFittingHold || isEditingWallArea)
            }

            if isEditingWallArea {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        saveWallArea()
                    } label: {
                        Label("Save Wall Area", systemImage: "checkmark")
                    }
                    .buttonStyle(WallToolButtonStyle(tone: .primary))
                    .disabled(draftWallAreaPoints.count < 3)

                    HStack(spacing: 10) {
                        Button {
                            undoWallAreaPoint()
                        } label: {
                            Label("Undo Point", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(WallToolButtonStyle(tone: .neutral))
                        .disabled(draftWallAreaPoints.isEmpty)

                        Button {
                            cancelWallAreaEditing()
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                        .buttonStyle(WallToolButtonStyle(tone: .neutral))
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        startWallAreaEditing(from: wall)
                    } label: {
                        Label("Set Wall Area", systemImage: "crop")
                    }
                    .buttonStyle(WallToolButtonStyle(tone: .neutral))
                    .disabled(isDetectingHolds || isFittingHold || isEditingHolds)

                    if !wall.wallEdges.isEmpty {
                        Button(role: .destructive) {
                            clearWallArea()
                        } label: {
                            Label("Clear Wall Area", systemImage: "trash")
                        }
                        .buttonStyle(WallToolButtonStyle(tone: .destructive))
                        .disabled(isDetectingHolds || isFittingHold || isEditingHolds)
                    }
                }
            }

            if isEditingWallArea {
                Text("Tap directly on the wall edge corners in order. Boundary holds get a small detection margin.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.72))
            } else if !wall.wallEdges.isEmpty {
                Text("Wall area active: hold detection is filtered to the marked polygon.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.72))
            }

            if isEditingHolds {
                if isFittingHold {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Fitting hold...")
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(.white.opacity(0.72))
                } else {
                    Text("Tap an unmarked hold to auto-fit a box. Tap a marked box to select it. Use the corner controls to delete, move, or resize.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.72))
                }

                if !wall.holds.isEmpty {
                    Button(role: .destructive) {
                        isShowingDeleteAllHoldsConfirmation = true
                    } label: {
                        Label("Delete All Holds", systemImage: "trash")
                    }
                    .buttonStyle(WallToolButtonStyle(tone: .destructive))
                    .disabled(isFittingHold)
                }
            }

            Text("\(wall.holds.count) holds marked")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.76))

            Button {
                isShowingBoulderImport = true
            } label: {
                Label("Import From Other Walls", systemImage: "square.and.arrow.down")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(WallToolButtonStyle(tone: .neutral))
            .disabled(wall.holds.isEmpty)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func detectHolds() {
        guard !isEditingWallArea else {
            return
        }
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

    @ViewBuilder
    private func setPicker(for wall: Wall) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set")
                .font(.headline)

            Picker("Set", selection: Binding(
                get: { wall.activeSetID },
                set: { activateSet($0) }
            )) {
                ForEach(wall.sets) { set in
                    Text(set.name).tag(set.id)
                }
            }
            .pickerStyle(.menu)

            Text("\(wall.activeSetName) • \(wall.holds.count) holds • \(wall.boulders.count) problems")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func activateSet(_ setID: UUID) {
        Task {
            do {
                try await store.activateWallSet(wallID: wallID, setID: setID)
                selectedEditableHoldID = nil
                previewBoulder = nil
                editingBoulder = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func toggleWallTools() {
        withAnimation {
            if isShowingWallTools {
                if isEditingWallArea {
                    isEditingWallArea = false
                    draftWallAreaPoints = []
                }
                isEditingHolds = false
                selectedEditableHoldID = nil
            }

            isShowingWallTools.toggle()
        }
    }

    private func saveWallName(currentName: String) {
        let trimmedName = draftWallName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            draftWallName = currentName
            return
        }
        guard trimmedName != currentName else {
            draftWallName = trimmedName
            return
        }

        Task {
            do {
                try await store.updateWallName(wallID: wallID, name: trimmedName)
                await MainActor.run {
                    draftWallName = trimmedName
                }
            } catch {
                await MainActor.run {
                    draftWallName = currentName
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func holdDetectionButtonTitle(for wall: Wall) -> String {
        if isDetectingHolds {
            return "Detecting..."
        }
        return wall.holds.isEmpty ? "Detect Holds" : "Detect More Holds"
    }

    private func startWallAreaEditing(from wall: Wall) {
        withAnimation {
            isEditingWallArea = true
            isEditingHolds = false
            selectedEditableHoldID = nil
            draftWallAreaPoints = wall.wallEdges.first ?? []
        }
    }

    private func cancelWallAreaEditing() {
        withAnimation {
            isEditingWallArea = false
            draftWallAreaPoints = []
        }
    }

    private func appendWallAreaPoint(_ point: CGPoint) {
        let normalized = NormalizedPoint(x: point.x, y: point.y).clamped()
        draftWallAreaPoints.append(normalized)
    }

    private func undoWallAreaPoint() {
        guard !draftWallAreaPoints.isEmpty else {
            return
        }
        draftWallAreaPoints.removeLast()
    }

    private func saveWallArea() {
        guard draftWallAreaPoints.count >= 3 else {
            return
        }

        Task {
            do {
                try await store.updateWallArea(wallID: wallID, points: draftWallAreaPoints)
                await MainActor.run {
                    isEditingWallArea = false
                    draftWallAreaPoints = []
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func clearWallArea() {
        Task {
            do {
                try await store.clearWallArea(wallID: wallID)
            } catch {
                errorMessage = error.localizedDescription
            }
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

private struct WallToolButtonStyle: ButtonStyle {
    enum Tone {
        case primary
        case neutral
        case destructive
    }

    @Environment(\.isEnabled) private var isEnabled

    let tone: Tone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
            .shadow(color: shadowColor, radius: isEnabled ? 10 : 0, x: 0, y: 5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        guard isEnabled else {
            return .white.opacity(0.6)
        }

        switch tone {
        case .primary:
            return .white
        case .neutral:
            return .white.opacity(0.9)
        case .destructive:
            return Color(red: 1, green: 0.34, blue: 0.34)
        }
    }

    private var backgroundColor: Color {
        guard isEnabled else {
            return .white.opacity(0.095)
        }

        switch tone {
        case .primary:
            return Color(red: 0.20, green: 0.44, blue: 0.28)
        case .neutral:
            return .white.opacity(0.105)
        case .destructive:
            return Color(red: 0.22, green: 0.05, blue: 0.06)
        }
    }

    private var borderColor: Color {
        guard isEnabled else {
            return .white.opacity(0.1)
        }

        switch tone {
        case .primary:
            return Color(red: 0.45, green: 0.78, blue: 0.54).opacity(0.32)
        case .neutral:
            return .white.opacity(0.11)
        case .destructive:
            return Color(red: 1, green: 0.34, blue: 0.34).opacity(0.28)
        }
    }

    private var shadowColor: Color {
        guard isEnabled else {
            return .clear
        }

        switch tone {
        case .primary:
            return Color(red: 0.10, green: 0.35, blue: 0.18).opacity(0.35)
        case .neutral:
            return .black.opacity(0.16)
        case .destructive:
            return Color(red: 0.36, green: 0, blue: 0).opacity(0.28)
        }
    }
}

private struct CreateWallSetSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let wallID: UUID

    @State private var setName = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Set name", text: $setName)

                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label(selectedImageData == nil ? "Choose Wall Photo" : "Change Wall Photo", systemImage: "photo")
                    }
                } footer: {
                    Text("Create a new set when the same physical wall gets reset with different holds.")
                }

                if let selectedImageData, let image = UIImage(data: selectedImageData) {
                    Section {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Reset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .onChange(of: selectedPhotoItem) { _, item in
                loadPhoto(item)
            }
        }
    }

    private var canSave: Bool {
        !isSaving
            && !setName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedImageData != nil
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else {
            selectedImageData = nil
            return
        }

        Task {
            do {
                selectedImageData = try await item.loadTransferable(type: Data.self)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let selectedImageData else {
            return
        }

        isSaving = true
        Task {
            do {
                try await store.createWallSet(wallID: wallID, name: setName, imageData: selectedImageData)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
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
                        description: Text("Mark holds on this set, then import saved problems from another wall or set.")
                    )
                } else {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(workflowText(for: effectiveCandidates))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Text("Main actions: select good matches, compare and edit partial matches, then import.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ForEach(groups(from: effectiveCandidates)) { group in
                            Section {
                                ForEach(group.candidates) { candidate in
                                    BoulderImportCandidateRow(
                                        candidate: candidate,
                                        isSelected: selectedCandidateIDs.contains(candidate.id),
                                        showsCompareButton: true
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
            sourceWallSetID: candidate.sourceWallSetID,
            sourceWallName: candidate.sourceWallName,
            sourceSetName: candidate.sourceSetName,
            sourceBoulder: candidate.sourceBoulder,
            matchedHoldIDs: uniqueHoldIDs,
            matchedSecondaryHoldIDs: candidate.matchedSecondaryHoldIDs.filter { uniqueHoldIDs.contains($0) },
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

    private func workflowText(for candidates: [BoulderImportCandidate]) -> String {
        let completeCount = candidates.filter(\.isComplete).count
        let partialCount = candidates.count - completeCount
        let completeText = completeCount == 1 ? "1 full match" : "\(completeCount) full matches"
        let partialText = partialCount == 1 ? "1 partial match" : "\(partialCount) partial matches"
        return "SendLog matches each saved hold to the closest hold on this set using position and color. \(completeText); \(partialText). Partial imports keep the matched holds you approve."
    }

    private func groups(from candidates: [BoulderImportCandidate]) -> [BoulderImportGroup] {
        let grouped = Dictionary(grouping: candidates, by: { "\($0.sourceWallID.uuidString)-\($0.sourceWallSetID.uuidString)" })
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
                    sourceID: "\(first.sourceWallID.uuidString)-\(first.sourceWallSetID.uuidString)",
                    title: "\(first.sourceWallName) / \(first.sourceSetName)",
                    footer: "\(completeCount) full matches, \(partialCount) partial.",
                    candidates: sorted
                )
            }
            .sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }
}

private struct BoulderImportGroup: Identifiable {
    let sourceID: String
    let title: String
    let footer: String
    let candidates: [BoulderImportCandidate]

    var id: String {
        sourceID
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
            return "Full match: \(candidate.totalHoldCount)/\(candidate.totalHoldCount) holds"
        }
        let missing = candidate.missingHoldCount == 1 ? "1 missing/changed hold" : "\(candidate.missingHoldCount) missing/changed holds"
        return "Partial match: \(candidate.matchedHoldCount)/\(candidate.totalHoldCount) holds, \(missing)"
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
                if let sourceSet,
                   let targetWall,
                   let sourceImage = store.image(for: sourceSet),
                   let targetImage = store.image(for: targetWall) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            header

                            VStack(alignment: .leading, spacing: 8) {
                                Label("Original problem", systemImage: "1.circle")
                                    .font(.headline)
                                WallCanvasView(
                                    image: sourceImage,
                                    holds: sourceSet.holds,
                                    selectedHoldIDs: Set(candidate.sourceBoulder.holdIDs).subtracting(candidate.sourceBoulder.secondaryHoldIDs),
                                    wallEdges: sourceSet.wallEdges,
                                    secondarySelectedHoldIDs: Set(candidate.sourceBoulder.secondaryHoldIDs),
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
                                Text("Approve the matched holds, or tap holds to adjust this problem before importing.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)

                                WallCanvasView(
                                    image: targetImage,
                                    holds: targetWall.holds,
                                    selectedHoldIDs: selectedTargetHoldIDs,
                                    wallEdges: targetWall.wallEdges,
                                    secondarySelectedHoldIDs: Set(candidate.matchedSecondaryHoldIDs),
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

    private var sourceSet: WallSet? {
        sourceWall?.sets.first { $0.id == candidate.sourceWallSetID }
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
    let wallSetID: UUID?
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

    init(wallID: UUID, wallSetID: UUID? = nil, image: UIImage, initialBoulderID: UUID) {
        self.wallID = wallID
        self.wallSetID = wallSetID
        self.image = image
        _currentBoulderID = State(initialValue: initialBoulderID)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let wall = currentSet, let boulder = currentBoulder {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            WallCanvasView(
                                image: image,
                                holds: wall.holds,
                                selectedHoldIDs: Set(boulder.holdIDs).subtracting(boulder.secondaryHoldIDs),
                                wallEdges: wall.wallEdges,
                                secondarySelectedHoldIDs: Set(boulder.secondaryHoldIDs),
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

    private var currentSet: WallSet? {
        guard let wall = currentWall else {
            return nil
        }
        if let wallSetID {
            return wall.sets.first { $0.id == wallSetID }
        }
        return wall.activeSet
    }

    private var orderedBoulders: [Boulder] {
        currentSet?.boulders ?? []
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
