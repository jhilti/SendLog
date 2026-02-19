import SwiftUI
import UIKit

struct WallCanvasView: View {
    let image: UIImage
    let holds: [Hold]
    let selectedHoldIDs: Set<UUID>
    var onHoldTap: ((Hold) -> Void)?
    var onEmptyImageTap: ((CGPoint) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let imageFrame = aspectFitRect(for: image.size, in: geometry.size)

            ZStack {
                Color(.secondarySystemBackground)

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)

                Canvas { context, _ in
                    for hold in holds {
                        let rect = hold.rect.toCGRect(in: imageFrame)
                        let isSelected = selectedHoldIDs.contains(hold.id)
                        let strokeColor: Color = isSelected ? .green : .orange
                        var path = Path(roundedRect: rect, cornerRadius: 4)

                        if isSelected {
                            context.fill(path, with: .color(strokeColor.opacity(0.22)))
                        }
                        context.stroke(path, with: .color(strokeColor), lineWidth: isSelected ? 3 : 2)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let location = value.location
                        guard imageFrame.contains(location) else {
                            return
                        }

                        if let hold = holds.reversed().first(where: { $0.rect.toCGRect(in: imageFrame).contains(location) }) {
                            onHoldTap?(hold)
                            return
                        }

                        let normalizedPoint = CGPoint(
                            x: (location.x - imageFrame.minX) / imageFrame.width,
                            y: (location.y - imageFrame.minY) / imageFrame.height
                        )
                        onEmptyImageTap?(normalizedPoint)
                    }
            )
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
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
