import SwiftUI
import UIKit

struct WallCanvasView: View {
    let image: UIImage
    let holds: [Hold]
    let selectedHoldIDs: Set<UUID>
    var onHoldTap: ((Hold) -> Void)?
    var onEmptyImageTap: ((CGPoint) -> Void)?
    var onContourComplete: (([CGPoint]) -> Void)?
    var onContourUndo: (() -> Void)? = nil
    var contourUndoRequestID: Int = 0
    var isZoomEnabled = true
    var isContourDrawEnabled = false
    var nearestSelectionEnabled = true
    var showInlineContourUndoButton = true

    @State private var zoomScale: CGFloat = 1
    @State private var storedZoomScale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var storedZoomOffset: CGSize = .zero
    @State private var draftContourPoints: [CGPoint] = []
    @State private var isMagnifying = false
    @State private var lastTransformEndedAt: Date = .distantPast
    @State private var isContourPanMode = false

    var body: some View {
        GeometryReader { geometry in
            let imageSize = layoutImageSize
            let imageFrame = aspectFitRect(for: imageSize, in: geometry.size)
            let displayScale = isZoomEnabled ? zoomScale : 1
            let displayOffset = isZoomEnabled ? zoomOffset : .zero
            let baseCanvas = ZStack {
                Color.black

                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .position(x: imageFrame.midX, y: imageFrame.midY)

                    Canvas { context, _ in
                        for hold in holds {
                            let isSelected = selectedHoldIDs.contains(hold.id)
                            let isManualMarker = hold.source == .manual
                                && hold.confidence <= 0.3
                                && (hold.contour?.count ?? 0) >= 10
                            let strokeColor: Color
                            if isSelected {
                                strokeColor = .blue
                            } else if isManualMarker {
                                strokeColor = .orange.opacity(0.38)
                            } else {
                                strokeColor = .orange
                            }
                            let path = holdPath(for: hold, in: imageFrame)

                            if isSelected && !isManualMarker {
                                context.fill(path, with: .color(strokeColor.opacity(0.35)))
                            }
                            context.stroke(
                                path,
                                with: .color(strokeColor),
                                lineWidth: isSelected ? 4 : (isManualMarker ? 2.6 : 2)
                            )
                        }

                        if draftContourPoints.count >= 2 {
                            var draftPath = Path()
                            let first = pointFromNormalized(draftContourPoints[0], in: imageFrame)
                            draftPath.move(to: first)
                            for point in draftContourPoints.dropFirst() {
                                draftPath.addLine(to: pointFromNormalized(point, in: imageFrame))
                            }
                            context.stroke(draftPath, with: .color(.orange.opacity(0.85)), lineWidth: 2.5)
                        }

                        if let lastPoint = draftContourPoints.last {
                            let markerCenter = pointFromNormalized(lastPoint, in: imageFrame)
                            let markerRect = CGRect(
                                x: markerCenter.x - 4,
                                y: markerCenter.y - 4,
                                width: 8,
                                height: 8
                            )
                            context.fill(Path(ellipseIn: markerRect), with: .color(.orange.opacity(0.9)))
                        }
                    }
                }
                .scaleEffect(displayScale, anchor: .center)
                .offset(displayOffset)
            }
            .contentShape(Rectangle())

            Group {
                if isContourDrawEnabled {
                    if isContourPanMode {
                        if zoomScale > 1.01 {
                            baseCanvas
                                .simultaneousGesture(dragGesture(in: imageFrame))
                                .simultaneousGesture(magnificationGesture(in: imageFrame))
                                .simultaneousGesture(contourModeToggleGesture)
                        } else {
                            baseCanvas
                                .simultaneousGesture(magnificationGesture(in: imageFrame))
                                .simultaneousGesture(contourModeToggleGesture)
                        }
                    } else {
                        baseCanvas
                            .highPriorityGesture(contourDrawGesture(in: imageFrame))
                            .simultaneousGesture(magnificationGesture(in: imageFrame))
                            .simultaneousGesture(contourModeToggleGesture)
                    }
                } else if isZoomEnabled {
                    if zoomScale > 1.01 {
                        baseCanvas
                            .highPriorityGesture(tapGesture(in: imageFrame))
                            .simultaneousGesture(dragGesture(in: imageFrame))
                            .simultaneousGesture(magnificationGesture(in: imageFrame))
                    } else {
                        baseCanvas
                            .highPriorityGesture(tapGesture(in: imageFrame))
                            .simultaneousGesture(magnificationGesture(in: imageFrame))
                    }
                } else if hasTapHandlers {
                    baseCanvas
                        .highPriorityGesture(tapGesture(in: imageFrame))
                } else {
                    baseCanvas
                }
            }
            .onChange(of: isZoomEnabled) { _, enabled in
                if !enabled {
                    resetZoom()
                }
                if !enabled {
                    isContourPanMode = false
                }
            }
            .onChange(of: isContourDrawEnabled) { _, enabled in
                if !enabled {
                    draftContourPoints = []
                    isContourPanMode = false
                }
            }
            .onChange(of: contourUndoRequestID) { _, _ in
                guard isContourDrawEnabled else {
                    return
                }
                undoLastContourStep()
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(layoutImageSize.width / max(layoutImageSize.height, 1), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topLeading) {
            if isContourDrawEnabled && showInlineContourUndoButton {
                Button {
                    undoLastContourStep()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isContourDrawEnabled {
                Text(isContourPanMode ? "Move" : "Draw")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
        }
    }

    private var hasTapHandlers: Bool {
        onHoldTap != nil || onEmptyImageTap != nil
    }

    private var layoutImageSize: CGSize {
        switch image.imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: image.size.height, height: image.size.width)
        default:
            return image.size
        }
    }

    private func tapGesture(in imageFrame: CGRect) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let location = locationInUnscaledCanvas(from: value.location, imageFrame: imageFrame)
                guard imageFrame.contains(location) else {
                    return
                }

                if let onHoldTap {
                    if let hold = holds.reversed().first(where: { holdContains($0, point: location, imageFrame: imageFrame) }) {
                        onHoldTap(hold)
                        return
                    }

                    if nearestSelectionEnabled, let nearest = nearestHold(to: location, in: imageFrame) {
                        onHoldTap(nearest)
                        return
                    }
                }

                let normalizedPoint = CGPoint(
                    x: (location.x - imageFrame.minX) / imageFrame.width,
                    y: (location.y - imageFrame.minY) / imageFrame.height
                )
                onEmptyImageTap?(normalizedPoint)
            }
    }

    private func contourDrawGesture(in imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !isMagnifying else {
                    return
                }
                guard Date().timeIntervalSince(lastTransformEndedAt) > 0.08 else {
                    return
                }

                let location = locationInUnscaledCanvas(from: value.location, imageFrame: imageFrame)
                guard imageFrame.contains(location) else {
                    return
                }

                let normalizedPoint = CGPoint(
                    x: (location.x - imageFrame.minX) / imageFrame.width,
                    y: (location.y - imageFrame.minY) / imageFrame.height
                )
                appendContourPoint(normalizedPoint)
            }
            .onEnded { _ in
                guard !isMagnifying else {
                    return
                }
                guard Date().timeIntervalSince(lastTransformEndedAt) > 0.08 else {
                    draftContourPoints = []
                    return
                }
                completeContourIfPossible()
            }
    }

    private var contourModeToggleGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                guard isContourDrawEnabled else {
                    return
                }
                isContourPanMode.toggle()
                if isContourPanMode {
                    draftContourPoints = []
                }
            }
    }

    private func dragGesture(in imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard isZoomEnabled, zoomScale > 1.01 else {
                    return
                }
                guard !isContourDrawEnabled || isContourPanMode else {
                    return
                }
                guard canPanImage(for: value.translation, imageFrame: imageFrame) else {
                    return
                }

                let proposed = CGSize(
                    width: storedZoomOffset.width + value.translation.width,
                    height: storedZoomOffset.height + value.translation.height
                )
                zoomOffset = clampedOffset(proposed, for: zoomScale, imageFrame: imageFrame)
            }
            .onEnded { value in
                guard isZoomEnabled else {
                    return
                }
                guard !isContourDrawEnabled || isContourPanMode else {
                    return
                }
                guard zoomScale > 1.01 else {
                    resetZoom()
                    return
                }
                guard canPanImage(for: value.translation, imageFrame: imageFrame) else {
                    return
                }

                let proposed = CGSize(
                    width: storedZoomOffset.width + value.translation.width,
                    height: storedZoomOffset.height + value.translation.height
                )
                zoomOffset = clampedOffset(proposed, for: zoomScale, imageFrame: imageFrame)
                storedZoomOffset = zoomOffset
                lastTransformEndedAt = Date()
            }
    }

    private func magnificationGesture(in imageFrame: CGRect) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard isZoomEnabled else {
                    return
                }

                isMagnifying = true
                let proposedScale = clampedScale(storedZoomScale * value)
                zoomScale = proposedScale
                zoomOffset = clampedOffset(zoomOffset, for: proposedScale, imageFrame: imageFrame)
            }
            .onEnded { value in
                guard isZoomEnabled else {
                    return
                }

                isMagnifying = false
                zoomScale = clampedScale(storedZoomScale * value)
                zoomOffset = clampedOffset(zoomOffset, for: zoomScale, imageFrame: imageFrame)
                storedZoomScale = zoomScale
                storedZoomOffset = zoomOffset
                lastTransformEndedAt = Date()

                if zoomScale <= 1.01 {
                    resetZoom()
                }
            }
    }

    private func appendContourPoint(_ normalizedPoint: CGPoint) {
        let point = CGPoint(
            x: min(max(0, normalizedPoint.x), 1),
            y: min(max(0, normalizedPoint.y), 1)
        )

        if let last = draftContourPoints.last {
            let distance = hypot(last.x - point.x, last.y - point.y)
            guard distance >= 0.0035 else {
                return
            }
        }

        draftContourPoints.append(point)
    }

    private func completeContourIfPossible() {
        guard draftContourPoints.count >= 3 else {
            draftContourPoints = []
            return
        }

        onContourComplete?(draftContourPoints)
        draftContourPoints = []
    }

    private func undoLastContourStep() {
        if !draftContourPoints.isEmpty {
            let removeCount = min(12, draftContourPoints.count)
            draftContourPoints.removeLast(removeCount)
            return
        }

        onContourUndo?()
    }

    private func pointFromNormalized(_ point: CGPoint, in imageFrame: CGRect) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + (point.x * imageFrame.width),
            y: imageFrame.minY + (point.y * imageFrame.height)
        )
    }

    private func nearestHold(to location: CGPoint, in imageFrame: CGRect) -> Hold? {
        let maxDistance = max(20, min(imageFrame.width, imageFrame.height) * 0.03)
        let nearest = holds
            .map { hold -> (hold: Hold, distance: CGFloat) in
                let rect = hold.rect.toCGRect(in: imageFrame)
                let center = CGPoint(x: rect.midX, y: rect.midY)
                return (hold: hold, distance: hypot(location.x - center.x, location.y - center.y))
            }
            .min { left, right in
                left.distance < right.distance
            }

        guard let nearest, nearest.distance <= maxDistance else {
            return nil
        }
        return nearest.hold
    }

    private func locationInUnscaledCanvas(from location: CGPoint, imageFrame: CGRect) -> CGPoint {
        guard isZoomEnabled else {
            return location
        }

        let center = CGPoint(x: imageFrame.midX, y: imageFrame.midY)
        let translated = CGPoint(
            x: location.x - zoomOffset.width,
            y: location.y - zoomOffset.height
        )
        let safeScale = max(zoomScale, 0.0001)

        return CGPoint(
            x: center.x + ((translated.x - center.x) / safeScale),
            y: center.y + ((translated.y - center.y) / safeScale)
        )
    }

    private func holdContains(_ hold: Hold, point: CGPoint, imageFrame: CGRect) -> Bool {
        if let contourPath = contourPath(for: hold, in: imageFrame),
           contourPath.contains(point, eoFill: true) {
            return true
        }
        return hold.rect.toCGRect(in: imageFrame).contains(point)
    }

    private func holdPath(for hold: Hold, in imageFrame: CGRect) -> Path {
        if let contourPath = contourPath(for: hold, in: imageFrame) {
            return contourPath
        }
        let rect = hold.rect.toCGRect(in: imageFrame)
        return Path(roundedRect: rect, cornerRadius: 4)
    }

    private func contourPath(for hold: Hold, in imageFrame: CGRect) -> Path? {
        guard let contour = hold.contour, contour.count >= 3 else {
            return nil
        }

        var path = Path()
        path.move(to: contour[0].toCGPoint(in: imageFrame))
        for point in contour.dropFirst() {
            path.addLine(to: point.toCGPoint(in: imageFrame))
        }
        path.closeSubpath()
        return path
    }

    private func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, 1), 4)
    }

    private func canPanImage(for translation: CGSize, imageFrame: CGRect) -> Bool {
        guard zoomScale > 1.01 else {
            return false
        }

        let proposed = CGSize(
            width: storedZoomOffset.width + translation.width,
            height: storedZoomOffset.height + translation.height
        )
        let clamped = clampedOffset(proposed, for: zoomScale, imageFrame: imageFrame)

        let deltaX = abs(clamped.width - storedZoomOffset.width)
        let deltaY = abs(clamped.height - storedZoomOffset.height)
        let minMovement: CGFloat = 0.2
        let intentThreshold: CGFloat = 1.5

        if abs(translation.height) > abs(translation.width), abs(translation.height) > intentThreshold {
            return deltaY > minMovement
        }

        if abs(translation.width) > abs(translation.height), abs(translation.width) > intentThreshold {
            return deltaX > minMovement
        }

        return deltaX > minMovement || deltaY > minMovement
    }

    private func clampedOffset(_ offset: CGSize, for scale: CGFloat, imageFrame: CGRect) -> CGSize {
        guard scale > 1 else {
            return .zero
        }

        let maxX = ((imageFrame.width * scale) - imageFrame.width) / 2
        let maxY = ((imageFrame.height * scale) - imageFrame.height) / 2
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    private func resetZoom() {
        zoomScale = 1
        storedZoomScale = 1
        zoomOffset = .zero
        storedZoomOffset = .zero
    }

    private func aspectFitRect(for imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let imageRatio = imageSize.width / imageSize.height
        let containerRatio = containerSize.width / max(containerSize.height, 1)

        if imageRatio > containerRatio {
            let width = containerSize.width
            let height = width / imageRatio
            let y = (containerSize.height - height) / 2
            return CGRect(x: 0, y: y, width: width, height: height)
        }

        let height = containerSize.height
        let width = height * imageRatio
        let x = (containerSize.width - width) / 2
        return CGRect(x: x, y: 0, width: width, height: height)
    }
}
