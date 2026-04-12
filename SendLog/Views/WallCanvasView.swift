import SwiftUI
import UIKit

struct WallCanvasView: View {
    let image: UIImage
    let holds: [Hold]
    let selectedHoldIDs: Set<UUID>
    var secondarySelectedHoldIDs: Set<UUID> = []
    var showsInactiveHolds = true
    var editableHoldID: UUID? = nil
    var onHoldTap: ((Hold) -> Void)?
    var onHoldDoubleTap: ((Hold) -> Void)? = nil
    var onHoldDelete: ((Hold) -> Void)? = nil
    var onEmptyImageTap: ((CGPoint) -> Void)?
    var onEmptyImageDoubleTap: ((CGPoint) -> Void)? = nil
    var onHoldDragEnd: ((Hold, CGPoint) -> Void)? = nil
    var onHoldResizeEnd: ((Hold, NormalizedRect) -> Void)? = nil
    var onContourComplete: (([CGPoint]) -> Void)?
    var onContourUndo: (() -> Void)? = nil
    var contourUndoRequestID: Int = 0
    var isZoomEnabled = true
    var isContourDrawEnabled = false
    var nearestSelectionEnabled = true
    var showInlineContourUndoButton = true
    var cornerRadius: CGFloat = 14
    var onZoomScaleChange: ((CGFloat) -> Void)? = nil

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
    @State private var activeHoldResizeID: UUID? = nil
    @State private var resizedHoldRect: NormalizedRect? = nil

    var body: some View {
        GeometryReader { geometry in
            let imageSize = layoutImageSize
            let imageFrame = aspectFitRect(for: imageSize, in: geometry.size)
            let displayScale = isZoomEnabled ? zoomScale : 1
            let displayOffset = isZoomEnabled ? zoomOffset : .zero
            let editableRenderedHold = editableHold.map { renderedHold(for: $0) }
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
                            guard showsInactiveHolds || isSelected || editableHoldID == hold.id else {
                                continue
                            }
                            let selectionColor: Color = isSecondarySelected ? .red : .blue
                            let rect = rendered.rect.toCGRect(in: imageFrame)
                            let path = Path(roundedRect: rect, cornerRadius: 4)
                            let lineWidth: CGFloat = isSelected ? 2.0 : 1.4

                            if isSelected {
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

                            let center = CGPoint(x: rect.midX, y: rect.midY)
                            let centerDotDiameter = max(7, min(rect.width, rect.height) * 0.16)
                            let centerRect = CGRect(
                                x: center.x - (centerDotDiameter / 2),
                                y: center.y - (centerDotDiameter / 2),
                                width: centerDotDiameter,
                                height: centerDotDiameter
                            )
                            context.fill(
                                Path(ellipseIn: centerRect),
                                with: .color(isSelected ? selectionColor.opacity(0.96) : .orange.opacity(0.92))
                            )

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

                    if let editableRenderedHold {
                        editorControls(for: editableRenderedHold, in: imageFrame)
                            .allowsHitTesting(false)
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
                    if zoomScale > 1.01 || hasEditableHoldInteraction {
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
                    if hasEditableHoldInteraction {
                        baseCanvas
                            .highPriorityGesture(tapGesture(in: imageFrame))
                            .simultaneousGesture(dragGesture(in: imageFrame))
                    } else {
                        baseCanvas
                            .highPriorityGesture(tapGesture(in: imageFrame))
                    }
                } else if hasEditableHoldInteraction {
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
                    activeHoldResizeID = nil
                    resizedHoldRect = nil
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
                activeHoldResizeID = nil
                resizedHoldRect = nil
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
                activeHoldResizeID = nil
                resizedHoldRect = nil
            }
            .onChange(of: holds) { _, updatedHolds in
                if let activeHoldDragID, !updatedHolds.contains(where: { $0.id == activeHoldDragID }) {
                    self.activeHoldDragID = nil
                    draggedHoldCenter = nil
                    activeHoldDragTouchOffset = .zero
                }
                if let activeHoldResizeID, !updatedHolds.contains(where: { $0.id == activeHoldResizeID }) {
                    self.activeHoldResizeID = nil
                    resizedHoldRect = nil
                }
            }
            .onAppear {
                onZoomScaleChange?(isZoomEnabled ? zoomScale : 1)
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
        onHoldTap != nil || onEmptyImageTap != nil || onHoldDoubleTap != nil || onEmptyImageDoubleTap != nil || onHoldDelete != nil
    }

    private var hasEditableHoldDrag: Bool {
        editableHoldID != nil && onHoldDragEnd != nil
    }

    private var hasEditableHoldResize: Bool {
        editableHoldID != nil && onHoldResizeEnd != nil
    }

    private var hasEditableHoldInteraction: Bool {
        hasEditableHoldDrag || hasEditableHoldResize
    }

    private var editableHold: Hold? {
        guard let editableHoldID else {
            return nil
        }
        return holds.first(where: { $0.id == editableHoldID })
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

        if !isDoubleTap,
           let editableHold,
           let onHoldDelete,
           deleteHandleRect(for: renderedHold(for: editableHold), in: imageFrame).contains(unscaledLocation) {
            onHoldDelete(editableHold)
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
        DragGesture(minimumDistance: hasEditableHoldInteraction ? 0 : 8, coordinateSpace: .local)
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
                onZoomScaleChange?(proposedScale)
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
                onZoomScaleChange?(zoomScale)

                if zoomScale <= 1.01 {
                    resetZoom()
                }
            }
    }

    private func handleEditableHoldDragChanged(_ value: DragGesture.Value, in imageFrame: CGRect) -> Bool {
        guard let editableHoldID,
              let hold = holds.first(where: { $0.id == editableHoldID }) else {
            return false
        }

        let startLocation = locationInUnscaledCanvas(from: value.startLocation, imageFrame: imageFrame)
        let rendered = renderedHold(for: hold)

        if hasEditableHoldResize || activeHoldResizeID != nil {
            if activeHoldResizeID == editableHoldID || resizeHandleRect(for: rendered, in: imageFrame).contains(startLocation) {
                if activeHoldResizeID == nil {
                    activeHoldResizeID = editableHoldID
                    resizedHoldRect = hold.rect
                }

                let fingerLocation = locationInUnscaledCanvas(from: value.location, imageFrame: imageFrame)
                resizedHoldRect = resizedRect(
                    for: hold,
                    draggingBottomRightTo: fingerLocation,
                    in: imageFrame
                )
                return true
            }
        }

        guard hasEditableHoldDrag || activeHoldDragID != nil else {
            return false
        }
        guard activeHoldDragID == editableHoldID || moveHandleRect(for: rendered, in: imageFrame).contains(startLocation) else {
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
        if let activeHoldResizeID {
            defer {
                self.activeHoldResizeID = nil
                resizedHoldRect = nil
            }

            guard let hold = holds.first(where: { $0.id == activeHoldResizeID }) else {
                return true
            }

            let finalRect = resizedHoldRect ?? resizedRect(
                for: hold,
                draggingBottomRightTo: locationInUnscaledCanvas(from: value.location, imageFrame: imageFrame),
                in: imageFrame
            )
            onHoldResizeEnd?(hold, finalRect)
            return true
        }

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
        if hold.id == activeHoldResizeID, let resizedHoldRect {
            var resized = hold
            resized.rect = resizedHoldRect.squareAnchoredTopLeading()
            resized.contour = nil
            return resized
        }
        if hold.id == activeHoldDragID, let draggedHoldCenter {
            var moved = holdMoved(hold, to: draggedHoldCenter)
            moved.rect = moved.rect.squareCentered()
            return moved
        }

        var rendered = hold
        rendered.rect = hold.rect.squareCentered()
        return rendered
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
        let baseRect = hold.rect.squareCentered().toCGRect(in: imageFrame)
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

    @ViewBuilder
    private func editorControls(for hold: Hold, in imageFrame: CGRect) -> some View {
        let deleteRect = deleteHandleRect(for: hold, in: imageFrame)
        let moveRect = moveHandleRect(for: hold, in: imageFrame)
        let resizeRect = resizeHandleRect(for: hold, in: imageFrame)

        holdControl(symbol: "xmark", frame: deleteRect, tint: .red)
        holdControl(symbol: "arrow.up.left.and.arrow.down.right", frame: resizeRect, tint: .orange)
        holdControl(symbol: "arrow.up.and.down.and.arrow.left.and.right", frame: moveRect, tint: .blue)
    }

    private func holdControl(symbol: String, frame: CGRect, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)
            Circle()
                .strokeBorder(tint.opacity(0.85), lineWidth: 1.2)
            Image(systemName: symbol)
                .font(.system(size: max(11, frame.width * 0.42), weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .shadow(color: .black.opacity(0.28), radius: 3, x: 0, y: 1)
    }

    private func deleteHandleRect(for hold: Hold, in imageFrame: CGRect) -> CGRect {
        holdControlRect(for: hold, corner: .topLeading, in: imageFrame)
    }

    private func moveHandleRect(for hold: Hold, in imageFrame: CGRect) -> CGRect {
        holdControlRect(for: hold, corner: .topTrailing, in: imageFrame)
    }

    private func resizeHandleRect(for hold: Hold, in imageFrame: CGRect) -> CGRect {
        holdControlRect(for: hold, corner: .bottomTrailing, in: imageFrame)
    }

    private enum HoldControlCorner {
        case topLeading
        case topTrailing
        case bottomTrailing
    }

    private func holdControlRect(for hold: Hold, corner: HoldControlCorner, in imageFrame: CGRect) -> CGRect {
        let rect = hold.rect.toCGRect(in: imageFrame)
        let size = holdControlSize(for: rect)
        let inset = size * 0.28

        let center: CGPoint
        switch corner {
        case .topLeading:
            center = CGPoint(x: rect.minX + inset, y: rect.minY + inset)
        case .topTrailing:
            center = CGPoint(x: rect.maxX - inset, y: rect.minY + inset)
        case .bottomTrailing:
            center = CGPoint(x: rect.maxX - inset, y: rect.maxY - inset)
        }

        return CGRect(
            x: center.x - (size / 2),
            y: center.y - (size / 2),
            width: size,
            height: size
        )
    }

    private func holdControlSize(for rect: CGRect) -> CGFloat {
        min(28, max(18, min(rect.width, rect.height) * 0.32))
    }

    private func resizedRect(for hold: Hold, draggingBottomRightTo location: CGPoint, in imageFrame: CGRect) -> NormalizedRect {
        let startRect = hold.rect.toCGRect(in: imageFrame)
        let minPixelSide = max(18, min(imageFrame.width, imageFrame.height) * 0.03)

        let clampedPoint = CGPoint(
            x: min(max(location.x, startRect.minX + minPixelSide), imageFrame.maxX),
            y: min(max(location.y, startRect.minY + minPixelSide), imageFrame.maxY)
        )

        let requestedWidth = clampedPoint.x - startRect.minX
        let requestedHeight = clampedPoint.y - startRect.minY
        let requestedSide = max(requestedWidth, requestedHeight)
        let maxSide = min(imageFrame.maxX - startRect.minX, imageFrame.maxY - startRect.minY)
        let side = min(max(requestedSide, minPixelSide), maxSide)

        return NormalizedRect(
            x: hold.rect.x,
            y: hold.rect.y,
            width: side / imageFrame.width,
            height: side / imageFrame.height
        ).squareAnchoredTopLeading()
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
        holdHighlightRect(for: hold, in: imageFrame).contains(point)
    }

    private func holdPath(for hold: Hold, in imageFrame: CGRect) -> Path {
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
        onZoomScaleChange?(1)
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
