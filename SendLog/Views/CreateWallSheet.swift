import PhotosUI
import SwiftUI
import UIKit
import CoreImage
import ImageIO

struct CreateWallSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var wallName = ""
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var previewImage: UIImage?
    @State private var processedPreviewImage: UIImage?
    @State private var processedImageData: Data?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var useBoardCorners = false
    @State private var boardCorners: [CGPoint] = []
    @State private var showingCornerPicker = false

    private let ciContext = CIContext(options: nil)

    var body: some View {
        NavigationStack {
            Form {
                Section("Wall") {
                    TextField("Wall name", text: $wallName)
                }

                Section("Photo") {
                    PhotosPicker(selection: $selectedItem, matching: .images, photoLibrary: .shared()) {
                        Label(previewImage == nil ? "Pick Wall Image" : "Change Wall Image", systemImage: "photo")
                    }

                    if previewImage != nil {
                        Toggle("Use 4-corner crop", isOn: $useBoardCorners)
                    }

                    if useBoardCorners, previewImage != nil {
                        Button(boardCorners.count == 4 ? "Adjust Board Corners" : "Set Board Corners") {
                            showingCornerPicker = true
                        }
                        .buttonStyle(.bordered)

                        Text("Tap corners in this order: top-left, top-right, bottom-right, bottom-left.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Text("\(boardCorners.count)/4 corners selected")
                            .font(.footnote)
                            .foregroundStyle(boardCorners.count == 4 ? .green : .secondary)
                    }

                    if let previewImage {
                        Image(uiImage: processedPreviewImage ?? previewImage)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .frame(maxHeight: 220)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("New Wall")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        saveWall()
                    }
                    .disabled(!canSave)
                }
            }
            .onChange(of: selectedItem) { _, item in
                guard let item else { return }
                Task {
                    await loadImage(from: item)
                }
            }
            .onChange(of: useBoardCorners) { _, isEnabled in
                if !isEnabled {
                    boardCorners = []
                    processedPreviewImage = nil
                    processedImageData = nil
                }
            }
            .sheet(isPresented: $showingCornerPicker) {
                if let image = previewImage {
                    CornerSelectionSheet(
                        image: image,
                        initialCorners: boardCorners
                    ) { corners in
                        boardCorners = corners
                        processedImageData = makeProcessedImageData(from: image, corners: corners)
                        processedPreviewImage = processedImageData.flatMap { UIImage(data: $0) }
                        if processedImageData == nil {
                            errorMessage = "Could not process the selected corners. Please try again."
                        } else {
                            errorMessage = nil
                        }
                    }
                }
            }
        }
    }

    private var canSave: Bool {
        !isSaving
            && !wallName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedImageData != nil
            && (!useBoardCorners || boardCorners.count == 4)
    }

    private func loadImage(from item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                errorMessage = "Could not load the selected image."
                return
            }
            selectedImageData = data
            previewImage = image
            processedPreviewImage = nil
            processedImageData = nil
            boardCorners = []
            useBoardCorners = false
            errorMessage = nil
        } catch {
            errorMessage = "Image import failed: \(error.localizedDescription)"
        }
    }

    private func saveWall() {
        guard let baseData = selectedImageData else {
            return
        }

        let data: Data
        if useBoardCorners {
            guard boardCorners.count == 4, let processedImageData else {
                errorMessage = "Please select all 4 board corners."
                return
            }
            data = processedImageData
        } else {
            data = baseData
        }

        isSaving = true

        Task {
            do {
                try await store.createWall(name: wallName, imageData: data)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func makeProcessedImageData(from image: UIImage, corners: [CGPoint]) -> Data? {
        guard corners.count == 4,
              let processed = preprocessWallImage(image, corners: corners),
              let jpeg = processed.jpegData(compressionQuality: 0.92) else {
            return nil
        }
        return jpeg
    }

    private func preprocessWallImage(_ image: UIImage, corners: [CGPoint]) -> UIImage? {
        guard let sourceCI = orientedCIImage(from: image) else {
            return nil
        }
        let sourceExtent = sourceCI.extent.integral
        let imageSize = sourceExtent.size

        let points = corners.map { corner in
            CGPoint(x: corner.x * imageSize.width, y: corner.y * imageSize.height)
        }
        guard points.count == 4 else {
            return nil
        }

        func toCoreImageSpace(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: imageSize.height - point.y)
        }

        var corrected = sourceCI.applyingFilter(
            "CIPerspectiveCorrection",
            parameters: [
                "inputTopLeft": CIVector(cgPoint: toCoreImageSpace(points[0])),
                "inputTopRight": CIVector(cgPoint: toCoreImageSpace(points[1])),
                "inputBottomRight": CIVector(cgPoint: toCoreImageSpace(points[2])),
                "inputBottomLeft": CIVector(cgPoint: toCoreImageSpace(points[3]))
            ]
        )

        let topWidth = hypot(points[1].x - points[0].x, points[1].y - points[0].y)
        let bottomWidth = hypot(points[2].x - points[3].x, points[2].y - points[3].y)
        let leftHeight = hypot(points[3].x - points[0].x, points[3].y - points[0].y)
        let rightHeight = hypot(points[2].x - points[1].x, points[2].y - points[1].y)
        let expectedLandscape = ((topWidth + bottomWidth) / 2) >= ((leftHeight + rightHeight) / 2)

        let correctedExtent = corrected.extent.integral
        let correctedLandscape = correctedExtent.width >= correctedExtent.height
        if correctedLandscape != expectedLandscape {
            corrected = corrected.oriented(.right)
        }

        let boardExtent = corrected.extent.integral
        guard boardExtent.width > 1, boardExtent.height > 1 else {
            return nil
        }

        let horizontalMargin = boardExtent.width * 0.05
        let bottomMargin = boardExtent.height * 0.05
        let topMargin = boardExtent.height * 0.20
        let canvasRect = CGRect(
            x: 0,
            y: 0,
            width: boardExtent.width + (horizontalMargin * 2),
            height: boardExtent.height + topMargin + bottomMargin
        )

        let translatedBoard = corrected.transformed(
            by: CGAffineTransform(
                translationX: horizontalMargin - boardExtent.minX,
                y: bottomMargin - boardExtent.minY
            )
        )
        let background = CIImage(
            color: CIColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        ).cropped(to: canvasRect)
        let composed = translatedBoard.composited(over: background).cropped(to: canvasRect)

        guard let output = ciContext.createCGImage(composed, from: canvasRect) else {
            return nil
        }
        return UIImage(cgImage: output, scale: image.scale, orientation: .up)
    }

    private func orientedCIImage(from image: UIImage) -> CIImage? {
        guard let baseCI = CIImage(image: image) else {
            return nil
        }

        let oriented = baseCI.oriented(forExifOrientation: exifOrientation(for: image.imageOrientation))
        let extent = oriented.extent.integral
        guard !extent.isNull else {
            return nil
        }

        return oriented.transformed(
            by: CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            )
        )
    }

    private func exifOrientation(for orientation: UIImage.Orientation) -> Int32 {
        switch orientation {
        case .up:
            return Int32(CGImagePropertyOrientation.up.rawValue)
        case .down:
            return Int32(CGImagePropertyOrientation.down.rawValue)
        case .left:
            return Int32(CGImagePropertyOrientation.left.rawValue)
        case .right:
            return Int32(CGImagePropertyOrientation.right.rawValue)
        case .upMirrored:
            return Int32(CGImagePropertyOrientation.upMirrored.rawValue)
        case .downMirrored:
            return Int32(CGImagePropertyOrientation.downMirrored.rawValue)
        case .leftMirrored:
            return Int32(CGImagePropertyOrientation.leftMirrored.rawValue)
        case .rightMirrored:
            return Int32(CGImagePropertyOrientation.rightMirrored.rawValue)
        @unknown default:
            return Int32(CGImagePropertyOrientation.up.rawValue)
        }
    }
}

private struct CornerSelectionSheet: View {
    let image: UIImage
    let onApply: ([CGPoint]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var corners: [CGPoint]

    init(image: UIImage, initialCorners: [CGPoint], onApply: @escaping ([CGPoint]) -> Void) {
        self.image = image
        self.onApply = onApply
        _corners = State(initialValue: initialCorners)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(currentInstruction)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                GeometryReader { proxy in
                    let frame = aspectFitFrame(in: proxy.size, imageSize: image.size)
                    ZStack {
                        Color(.systemBackground)
                            .ignoresSafeArea()

                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)

                        Path { path in
                            guard corners.count >= 2 else { return }
                            let mapped = corners.map { normalized in
                                CGPoint(
                                    x: frame.minX + (normalized.x * frame.width),
                                    y: frame.minY + (normalized.y * frame.height)
                                )
                            }
                            path.move(to: mapped[0])
                            for point in mapped.dropFirst() {
                                path.addLine(to: point)
                            }
                            if mapped.count == 4 {
                                path.closeSubpath()
                            }
                        }
                        .stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))

                        ForEach(Array(corners.enumerated()), id: \.offset) { index, corner in
                            let x = frame.minX + (corner.x * frame.width)
                            let y = frame.minY + (corner.y * frame.height)

                            ZStack {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 28, height: 28)
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                            .position(x: x, y: y)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                let location = value.location
                                guard frame.contains(location) else {
                                    return
                                }

                                let normalized = CGPoint(
                                    x: (location.x - frame.minX) / frame.width,
                                    y: (location.y - frame.minY) / frame.height
                                )

                                if corners.count < 4 {
                                    corners.append(normalized)
                                } else if let nearestIndex = nearestCorner(to: normalized, in: corners) {
                                    corners[nearestIndex] = normalized
                                }
                            }
                    )
                }
                .frame(minHeight: 300)

                HStack {
                    Button("Undo") {
                        if !corners.isEmpty {
                            corners.removeLast()
                        }
                    }
                    .disabled(corners.isEmpty)

                    Spacer()

                    Button("Reset") {
                        corners = []
                    }
                    .disabled(corners.isEmpty)
                }
                .padding(.horizontal)
            }
            .navigationTitle("Select Board Corners")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(corners)
                        dismiss()
                    }
                    .disabled(corners.count != 4)
                }
            }
        }
    }

    private var currentInstruction: String {
        let labels = ["top-left", "top-right", "bottom-right", "bottom-left"]
        if corners.count < labels.count {
            return "Tap corner \(corners.count + 1): \(labels[corners.count])."
        }
        return "Tap near a marker to adjust it if needed."
    }

    private func aspectFitFrame(in container: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }

        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let x = (container.width - width) / 2
        let y = (container.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func nearestCorner(to point: CGPoint, in corners: [CGPoint]) -> Int? {
        guard !corners.isEmpty else { return nil }
        return corners.enumerated().min { lhs, rhs in
            let lhsDistance = hypot(lhs.element.x - point.x, lhs.element.y - point.y)
            let rhsDistance = hypot(rhs.element.x - point.x, rhs.element.y - point.y)
            return lhsDistance < rhsDistance
        }?.offset
    }
}
