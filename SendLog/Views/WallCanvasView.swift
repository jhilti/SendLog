import SwiftUI
import UIKit

struct WallCanvasView: View {
    let image: UIImage
    let holds: [Hold]
    let selectedHoldIDs: Set<UUID>
    var onHoldTap: ((Hold) -> Void)?
    var onEmptyImageTap: ((CGPoint) -> Void)?
    var isZoomEnabled = false

    @State private var zoomScale: CGFloat = 1
    @State private var storedZoomScale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var storedZoomOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let imageFrame = aspectFitRect(for: image.size, in: geometry.size)
            let displayScale = isZoomEnabled ? zoomScale : 1
            let displayOffset = isZoomEnabled ? zoomOffset : .zero

            ZStack {
                Color(.secondarySystemBackground)

                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .position(x: imageFrame.midX, y: imageFrame.midY)

                    Canvas { context, _ in
                        for hold in holds {
                            let isSelected = selectedHoldIDs.contains(hold.id)
                            let strokeColor: Color = isSelected ? .blue : .orange
                            let path = holdPath(for: hold, in: imageFrame)

                            if isSelected {
                                context.fill(path, with: .color(strokeColor.opacity(0.22)))
                            }
                            context.stroke(path, with: .color(strokeColor), lineWidth: isSelected ? 3 : 2)
                        }
                    }
                }
                .scaleEffect(displayScale, anchor: .center)
                .offset(displayOffset)
            }
            .contentShape(Rectangle())
            .gesture(tapGesture(in: imageFrame))
            .simultaneousGesture(dragGesture(in: imageFrame))
            .simultaneousGesture(magnificationGesture(in: imageFrame))
            .onChange(of: isZoomEnabled) { _, enabled in
                if !enabled {
                    resetZoom()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func tapGesture(in imageFrame: CGRect) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let location = locationInUnscaledCanvas(from: value.location, imageFrame: imageFrame)
                guard imageFrame.contains(location) else {
                    return
                }

                if let hold = holds.reversed().first(where: { holdContains($0, point: location, imageFrame: imageFrame) }) {
                    onHoldTap?(hold)
                    return
                }

                let normalizedPoint = CGPoint(
                    x: (location.x - imageFrame.minX) / imageFrame.width,
                    y: (location.y - imageFrame.minY) / imageFrame.height
                )
                onEmptyImageTap?(normalizedPoint)
            }
    }

    private func dragGesture(in imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard isZoomEnabled, zoomScale > 1.01 else {
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
                guard zoomScale > 1.01 else {
                    resetZoom()
                    return
                }

                let proposed = CGSize(
                    width: storedZoomOffset.width + value.translation.width,
                    height: storedZoomOffset.height + value.translation.height
                )
                zoomOffset = clampedOffset(proposed, for: zoomScale, imageFrame: imageFrame)
                storedZoomOffset = zoomOffset
            }
    }

    private func magnificationGesture(in imageFrame: CGRect) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard isZoomEnabled else {
                    return
                }

                let proposedScale = clampedScale(storedZoomScale * value)
                zoomScale = proposedScale
                zoomOffset = clampedOffset(zoomOffset, for: proposedScale, imageFrame: imageFrame)
            }
            .onEnded { value in
                guard isZoomEnabled else {
                    return
                }

                zoomScale = clampedScale(storedZoomScale * value)
                zoomOffset = clampedOffset(zoomOffset, for: zoomScale, imageFrame: imageFrame)
                storedZoomScale = zoomScale
                storedZoomOffset = zoomOffset

                if zoomScale <= 1.01 {
                    resetZoom()
                }
            }
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
