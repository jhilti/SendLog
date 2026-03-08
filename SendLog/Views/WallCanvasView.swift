import SwiftUI
import UIKit

struct WallCanvasView: View {
    let image: UIImage
    let holds: [Hold]
    let selectedHoldIDs: Set<UUID>
    var secondarySelectedHoldIDs: Set<UUID> = []
    var editableHoldID: UUID? = nil
    var onHoldTap: ((Hold) -> Void)?
    var onHoldDoubleTap: ((Hold) -> Void)? = nil
    var onEmptyImageTap: ((CGPoint) -> Void)?
    var onEmptyImageDoubleTap: ((CGPoint) -> Void)? = nil
    var onHoldDragEnd: ((Hold, CGPoint) -> Void)? = nil
    var onContourComplete: (([CGPoint]) -> Void)?
    var onContourUndo: (() -> Void)? = nil
    var contourUndoRequestID: Int = 0
    var isZoomEnabled = true
    var isContourDrawEnabled = false
    var nearestSelectionEnabled = true
    var showInlineContourUndoButton = true
    var cornerRadius: CGFloat = 14

    @State private var zoomScale: CGFloat = 1
    @State private var storedZoomScale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var storedZoomOffset: CGSize = .zero
    @State private var draftContourPoints: [CGPoint] = []
    @State private var isMagnifying = false
    @State private var lastTransformEndedAt: Date = .distantPast
    @State private var isContourPanMode = false
    @State private var activeHoldDragID: UUID? = nil
    @State private var draggedHoldCenter: CGPoint? = nil
    @State private var activeHoldDragTouchOffset: CGSize = .zero

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
                            let rendered = renderedHold(for: hold)
                            let isPrimarySelected = selectedHoldIDs.contains(hold.id)
                            let isSecondarySelected = secondarySelectedHoldIDs.contains(hold.id)
                            let isSelected = isPrimarySelected || isSecondarySelected
                            let selectionColor: Color = isSecondarySelected ? .red : .blue
                            let isManualMarker = isManualMarker(rendered)
                            let path = holdPath(for: rendered, in: imageFrame)
                            let lineWidth: CGFloat = isSelected ? 2.0 : (isManualMarker ? 1.6 : 1.35)

                            if isManualMarker {
                                drawGlowingMarker(
                                    in: &context,
                                    for: rendered,
                                    in: imageFrame,
                                    color: isSelected ? selectionColor : .orange,
                                    glowBoost: isSelected ? 1.9 : 1.0
                                )
                            } else if isSelected {
                                context.fill(path, with: .color(selectionColor.opacity(0.18)))

                                context.drawLayer { layerContext in
                                    layerContext.addFilter(.shadow(color: selectionColor.opacity(0.95), radius: 8, x: 0, y: 0))
                                    layerContext.stroke(path, with: .color(selectionColor.opacity(0.98)), lineWidth: lineWidth)
                                }

                                let accentColor: Color = isSecondarySelected ? .orange : .cyan
                                context.stroke(path, with: .color(accentColor.opacity(0.85)), lineWidth: max(0.7, lineWidth * 0.5))
                            } else {
                                let strokeColor: Color = rendered.source == .detected
                                    ? .orange.opacity(0.62)
                                    : .orange.opacity(0.58)
                                context.stroke(path, with: .color(strokeColor), lineWidth: lineWidth)
                            }

                            if editableHoldID == hold.id {
                                let highlightRect = holdHighlightRect(for: rendered, in: imageFrame)
                                context.drawLayer { layerContext in
                                    layerContext.addFilter(.shadow(color: .white.opacity(0.8), radius: 4, x: 0, y: 0))
                                    layerContext.stroke(
                                        Path(roundedRect: highlightRect, cornerRadius: 4),
                                        with: .color(.white.opacity(0.96)),
                                        lineWidth: 1.4
                                    )
                                }
                            }
                        }

                        if draftContourPoints.count >= 2 {
                            var draftPath = Path()
                            let first = pointFromNormalized(draftContourPoints[0], in: imageFrame)
                            draftPath.move(to: first)
                            for point in draftContourPoints.dropFirst() {
                                draftPath.addLine(to: pointFromNormalized(point, in: imageFrame))
                            }
                            context.stroke(draftPath, with: .color(.orange.opacity(0.35)), lineWidth: 1.25)
                        }

                        if let lastPoint = draftContourPoints.last {
                            let markerCenter = pointFromNormalized(lastPoint, in: imageFrame)
                            let markerRect = CGRect(
                                x: markerCenter.x - 4,
                                y: markerCenter.y - 4,
                                width: 8,
                                height: 8
                            )
                            context.fill(Path(ellipseIn: markerRect), with: .color(.orange.opacity(0.45)))
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
                    if zoomScale > 1.01 || hasEditableHoldDrag {
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
                    if hasEditableHoldDrag {
                        baseCanvas
                            .highPriorityGesture(tapGesture(in: imageFrame))
                            .simultaneousGesture(dragGesture(in: imageFrame))
                    } else {
                        baseCanvas
                            .highPriorityGesture(tapGesture(in: imageFrame))
                    }
                } else if hasEditableHoldDrag {
                    baseCanvas
                        .simultaneousGesture(dragGesture(in: imageFrame))
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
                if !enabled {
                    activeHoldDragID = nil
                    draggedHoldCenter = nil
                    activeHoldDragTouchOffset = .zero
                }
            }
            .onChange(of: isContourDrawEnabled) { _, enabled in
                if !enabled {
                    draftContourPoints = []
                    isContourPanMode = false
                }
                activeHoldDragID = nil
                draggedHoldCenter = nil
                activeHoldDragTouchOffset = .zero
            }
            .onChange(of: contourUndoRequestID) { _, _ in
                guard isContourDrawEnabled else {
                    return
                }
                undoLastContourStep()
            }
            .onChange(of: editableHoldID) { _, _ in
                activeHoldDragID = nil
                draggedHoldCenter = nil
                activeHoldDragTouchOffset = .zero
            }
            .onChange(of: holds) { _, updatedHolds in
                if let activeHoldDragID, !updatedHolds.contains(where: { $0.id == activeHoldDragID }) {
                    self.activeHoldDragID = nil
                    draggedHoldCenter = nil
                    activeHoldDragTouchOffset = .zero
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(layoutImageSize.width / max(layoutImageSize.height, 1), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
        onHoldTap != nil || onEmptyImageTap != nil || onHoldDoubleTap != nil || onEmptyImageDoubleTap != nil
    }

    private var hasEditableHoldDrag: Bool {
        editableHoldID != nil && onHoldDragEnd != nil
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
        SpatialTapGesture(count: 2)
            .exclusively(before: SpatialTapGesture())
            .onEnded { value in
                switch value {
                case .first(let result):
                    handleTap(at: result.location, in: imageFrame, isDoubleTap: true)
                case .second(let result):
                    handleTap(at: result.location, in: imageFrame, isDoubleTap: false)
                }
            }
    }

    private func handleTap(at location: CGPoint, in imageFrame: CGRect, isDoubleTap: Bool) {
        let unscaledLocation = locationInUnscaledCanvas(from: location, imageFrame: imageFrame)
        guard imageFrame.contains(unscaledLocation) else {
            return
        }

        if let hold = holds.reversed().first(where: { holdContains($0, point: unscaledLocation, imageFrame: imageFrame) }) {
            if isDoubleTap, let onHoldDoubleTap {
                onHoldDoubleTap(hold)
                return
            }
            if let onHoldTap {
                onHoldTap(hold)
                return
            }
            if !isDoubleTap, nearestSelectionEnabled, let nearest = nearestHold(to: unscaledLocation, in: imageFrame) {
                onHoldTap?(nearest)
                return
            }
        } else if !isDoubleTap, let onHoldTap, nearestSelectionEnabled,
                  let nearest = nearestHold(to: unscaledLocation, in: imageFrame) {
            onHoldTap(nearest)
            return
        }

        let normalizedPoint = normalizedPoint(from: unscaledLocation, in: imageFrame)
        if isDoubleTap, let onEmptyImageDoubleTap {
            onEmptyImageDoubleTap(normalizedPoint)
            return
        }
        onEmptyImageTap?(normalizedPoint)
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
        DragGesture(minimumDistance: hasEditableHoldDrag ? 0 : 8, coordinateSpace: .local)
            .onChanged { value in
                if handleEditableHoldDragChanged(value, in: imageFrame) {
                    return
                }
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
                if handleEditableHoldDragEnded(value, in: imageFrame) {
                    return
                }
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

    private func handleEditableHoldDragChanged(_ value: DragGesture.Value, in imageFrame: CGRect) -> Bool {
        guard hasEditableHoldDrag, let editableHoldID else {
            return false
        }
        let startLocation = locationInUnscaledCanvas(from: value.startLocation, imageFrame: imageFrame)
        guard let hold = holds.first(where: { $0.id == editableHoldID }),
              holdContains(hold, point: startLocation, imageFrame: imageFrame) else {
            return false
        }

        if activeHoldDragID == nil {
            let dragDistance = hypot(value.translation.width, value.translation.height)
            guard dragDistance >= 2 else {
                return false
            }
            activeHoldDragID = editableHoldID
            let holdCenter = holdCenterPoint(for: hold, in: imageFrame)
            activeHoldDragTouchOffset = CGSize(
                width: holdCenter.x - startLocation.x,
                height: holdCenter.y - startLocation.y
            )
        }

        let fingerLocation = locationInUnscaledCanvas(from: value.location, imageFrame: imageFrame)
        let adjustedCenter = CGPoint(
            x: fingerLocation.x + activeHoldDragTouchOffset.width,
            y: fingerLocation.y + activeHoldDragTouchOffset.height
        )
        let clampedCenter = clampedToImageFrame(adjustedCenter, imageFrame: imageFrame)
        draggedHoldCenter = normalizedPoint(from: clampedCenter, in: imageFrame)
        return true
    }

    private func handleEditableHoldDragEnded(_ value: DragGesture.Value, in imageFrame: CGRect) -> Bool {
        guard let activeHoldDragID else {
            return false
        }
        defer {
            self.activeHoldDragID = nil
            draggedHoldCenter = nil
            activeHoldDragTouchOffset = .zero
        }

        guard let hold = holds.first(where: { $0.id == activeHoldDragID }) else {
            return true
        }

        let finalCenter: CGPoint
        if let draggedHoldCenter {
            finalCenter = draggedHoldCenter
        } else {
            let fingerLocation = locationInUnscaledCanvas(from: value.location, imageFrame: imageFrame)
            let adjustedCenter = CGPoint(
                x: fingerLocation.x + activeHoldDragTouchOffset.width,
                y: fingerLocation.y + activeHoldDragTouchOffset.height
            )
            let clampedCenter = clampedToImageFrame(adjustedCenter, imageFrame: imageFrame)
            finalCenter = normalizedPoint(from: clampedCenter, in: imageFrame)
        }
        onHoldDragEnd?(hold, finalCenter)
        return true
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

    private func normalizedPoint(from point: CGPoint, in imageFrame: CGRect) -> CGPoint {
        CGPoint(
            x: (point.x - imageFrame.minX) / imageFrame.width,
            y: (point.y - imageFrame.minY) / imageFrame.height
        )
    }

    private func clampedToImageFrame(_ point: CGPoint, imageFrame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, imageFrame.minX), imageFrame.maxX),
            y: min(max(point.y, imageFrame.minY), imageFrame.maxY)
        )
    }

    private func renderedHold(for hold: Hold) -> Hold {
        guard hold.id == activeHoldDragID, let draggedHoldCenter else {
            return hold
        }
        return holdMoved(hold, to: draggedHoldCenter)
    }

    private func holdMoved(_ hold: Hold, to normalizedCenter: CGPoint) -> Hold {
        let clampedCenter = CGPoint(
            x: min(max(0, normalizedCenter.x), 1),
            y: min(max(0, normalizedCenter.y), 1)
        )
        let currentCenter = CGPoint(
            x: hold.rect.x + (hold.rect.width / 2),
            y: hold.rect.y + (hold.rect.height / 2)
        )
        let requestedDx = clampedCenter.x - currentCenter.x
        let requestedDy = clampedCenter.y - currentCenter.y

        var moved = hold
        moved.rect = NormalizedRect(
            x: hold.rect.x + requestedDx,
            y: hold.rect.y + requestedDy,
            width: hold.rect.width,
            height: hold.rect.height
        ).clamped()

        let updatedCenter = CGPoint(
            x: moved.rect.x + (moved.rect.width / 2),
            y: moved.rect.y + (moved.rect.height / 2)
        )
        let appliedDx = updatedCenter.x - currentCenter.x
        let appliedDy = updatedCenter.y - currentCenter.y

        if let contour = hold.contour {
            moved.contour = contour.map { point in
                NormalizedPoint(x: point.x + appliedDx, y: point.y + appliedDy).clamped()
            }
        }

        return moved
    }

    private func holdHighlightRect(for hold: Hold, in imageFrame: CGRect) -> CGRect {
        let baseRect: CGRect
        if isManualMarker(hold) {
            let holdRect = hold.rect.toCGRect(in: imageFrame)
            let center = CGPoint(x: holdRect.midX, y: holdRect.midY)
            let radius = max(5, min(holdRect.width, holdRect.height) * 0.16)
            baseRect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        } else {
            baseRect = hold.rect.toCGRect(in: imageFrame)
        }
        let padding = max(6, min(baseRect.width, baseRect.height) * 0.2)
        return baseRect.insetBy(dx: -padding, dy: -padding)
    }

    private func drawGlowingMarker(
        in context: inout GraphicsContext,
        for hold: Hold,
        in imageFrame: CGRect,
        color: Color,
        glowBoost: Double = 1.0
    ) {
        let rect = hold.rect.toCGRect(in: imageFrame)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let coreRadius = max(1.5, min(rect.width, rect.height) * 0.11)
        let glowLayers: [(scale: CGFloat, opacity: Double)] = [
            (2.8, 0.08),
            (2.2, 0.14),
            (1.6, 0.23),
            (1.2, 0.34)
        ]

        let clampedBoost = max(1.0, glowBoost)
        let shadowOpacity = min(1.0, 0.44 * clampedBoost)
        let shadowRadius = 5.0 * clampedBoost
        context.drawLayer { layerContext in
            if clampedBoost > 1.01 {
                layerContext.addFilter(
                    .shadow(
                        color: color.opacity(shadowOpacity),
                        radius: shadowRadius,
                        x: 0,
                        y: 0
                    )
                )
            }

            for layer in glowLayers {
                let radius = coreRadius * layer.scale
                let glowRect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                let opacity = min(0.95, layer.opacity * clampedBoost)
                layerContext.fill(Path(ellipseIn: glowRect), with: .color(color.opacity(opacity)))
            }

            let coreRect = CGRect(
                x: center.x - coreRadius,
                y: center.y - coreRadius,
                width: coreRadius * 2,
                height: coreRadius * 2
            )
            let coreOpacity = min(1.0, 0.95 * clampedBoost)
            layerContext.fill(Path(ellipseIn: coreRect), with: .color(color.opacity(coreOpacity)))
        }
    }

    private func isManualMarker(_ hold: Hold) -> Bool {
        hold.source == .manual
            && hold.confidence <= 0.3
            && (hold.contour?.count ?? 0) >= 10
    }

    private func holdCenterPoint(for hold: Hold, in imageFrame: CGRect) -> CGPoint {
        let rect = hold.rect.toCGRect(in: imageFrame)
        return CGPoint(x: rect.midX, y: rect.midY)
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
        if isManualMarker(hold) {
            let hitRect = holdHighlightRect(for: hold, in: imageFrame)
            return hitRect.contains(point)
        }
        if let contourPath = contourPath(for: hold, in: imageFrame),
           contourPath.contains(point, eoFill: true) {
            return true
        }
        if hold.source == .detected, hold.contour == nil {
            let markerRect = detectedMarkerRect(for: hold, in: imageFrame)
            return markerRect.contains(point)
        }
        return hold.rect.toCGRect(in: imageFrame).contains(point)
    }

    private func holdPath(for hold: Hold, in imageFrame: CGRect) -> Path {
        if let contourPath = contourPath(for: hold, in: imageFrame) {
            return contourPath
        }
        if hold.source == .detected {
            let markerRect = detectedMarkerRect(for: hold, in: imageFrame)
            return Path(ellipseIn: markerRect)
        }
        let rect = hold.rect.toCGRect(in: imageFrame)
        return Path(roundedRect: rect, cornerRadius: 4)
    }

    private func detectedMarkerRect(for hold: Hold, in imageFrame: CGRect) -> CGRect {
        let rect = hold.rect.toCGRect(in: imageFrame)
        let base = min(rect.width, rect.height)
        let diameter = max(8, base * 0.68)
        return CGRect(
            x: rect.midX - (diameter / 2),
            y: rect.midY - (diameter / 2),
            width: diameter,
            height: diameter
        )
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
