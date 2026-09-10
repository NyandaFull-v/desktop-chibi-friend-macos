import AppKit
import Foundation

final class SpriteStore {
    let root: URL
    let character: CharacterDefinition
    private var currentKey = ""
    private var currentFrames: [NSImage] = []
    private var cachedCoin: NSImage?
    private let itemCache = NSCache<NSString, NSImage>()

    init?() {
        guard let resources = Bundle.main.resourceURL else { return nil }
        root = resources.appendingPathComponent("characters/chibidaful", isDirectory: true)
        let jsonURL = root.appendingPathComponent("character.json")
        guard let data = try? Data(contentsOf: jsonURL),
              let value = try? JSONDecoder().decode(CharacterDefinition.self, from: data) else { return nil }
        character = value
    }

    private func cells(file: String, columns: Int, rows: Int, row: Int, size: CGFloat) -> [NSImage] {
        guard let image = NSImage(contentsOf: root.appendingPathComponent(file)),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let cellWidth = source.width / columns
        let cellHeight = source.height / rows
        return (0..<columns).compactMap { column in
            let cropRect = CGRect(x: column * cellWidth, y: row * cellHeight, width: cellWidth, height: cellHeight)
            guard let crop = source.cropping(to: cropRect) else { return nil }
            let pixels = max(1, Int(size.rounded()))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: pixels * 4, bitsPerPixel: 32),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            let old = NSGraphicsContext.current
            NSGraphicsContext.current = context
            let pixelSize = CGFloat(pixels)
            NSImage(cgImage: crop, size: NSSize(width: pixelSize, height: pixelSize)).draw(
                in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
                from: .zero, operation: .copy, fraction: 1)
            context.flushGraphics()
            NSGraphicsContext.current = old
            guard let resized = bitmap.cgImage else { return nil }
            return NSImage(cgImage: resized, size: NSSize(width: size, height: size))
        }
    }

    func frames(for pose: Pose, size: CGFloat) -> [NSImage] {
        let key = "\(pose.rawValue)-\(Int(size))"
        if key == currentKey, !currentFrames.isEmpty { return currentFrames }
        let result: [NSImage]
        switch pose {
        case .walk:
            result = cells(file: character.animationSheets.sitWalk.file, columns: 4, rows: 2, row: 1, size: size)
        case .sit:
            result = cells(file: character.animationSheets.sitWalk.file, columns: 4, rows: 2, row: 0, size: size)
        case .petting:
            result = cells(file: character.animationSheets.petClimb.file, columns: 4, rows: 2, row: 0, size: size)
        case .climb:
            result = cells(file: character.animationSheets.petClimb.file, columns: 4, rows: 2, row: 1, size: size)
        case .sleep:
            result = cells(file: character.animationSheets.sleepLookTrip.file, columns: 4, rows: 3, row: 0, size: size)
        case .look:
            result = cells(file: character.animationSheets.sleepLookTrip.file, columns: 4, rows: 3, row: 1, size: size)
        case .trip:
            result = cells(file: character.animationSheets.sleepLookTrip.file, columns: 4, rows: 3, row: 2, size: size)
        case .dig:
            result = cells(file: character.animationSheets.dig.file, columns: 4, rows: 1, row: 0, size: size)
        default:
            let index: Int
            switch pose {
            case .stand: index = 0
            case .dash: index = 2
            case .fall: index = 5
            case .joy: index = 7
            case .dice: index = 8
            default: index = 0
            }
            let all = cells(file: character.spriteSheet, columns: character.columns, rows: character.rows, row: index / character.columns, size: size)
            result = all.indices.contains(index % character.columns) ? [all[index % character.columns]] : []
        }
        currentKey = key
        currentFrames = result
        return result
    }

    func coin(size: CGFloat = 54) -> NSImage? {
        if let cachedCoin, abs(cachedCoin.size.width - size) < 0.5 { return cachedCoin }
        let image = cells(file: character.coinFile, columns: 1, rows: 1, row: 0, size: size).first
        cachedCoin = image
        return image
    }

    func item(_ definition: ItemDefinition, size: CGFloat = 96) -> NSImage? {
        let key = "\(definition.id)-\(Int(size))" as NSString
        if let cached = itemCache.object(forKey: key) { return cached }
        let file: String
        switch definition.category {
        case .accessory: file = character.itemAtlases.accessory
        case .sweet: file = character.itemAtlases.sweet
        case .toy: file = character.itemAtlases.toy
        }
        let all = cells(file: file, columns: 5, rows: 1, row: 0, size: size)
        guard all.indices.contains(definition.atlasIndex) else { return nil }
        let image = all[definition.atlasIndex]
        itemCache.setObject(image, forKey: key, cost: Int(size * size * 4))
        itemCache.totalCostLimit = 2 * 1024 * 1024
        return image
    }
}
