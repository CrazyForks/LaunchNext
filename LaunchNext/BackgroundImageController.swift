import AppKit
import Combine
import CoreGraphics
import Darwin
import ImageIO
import QuartzCore
import SwiftUI

@MainActor
final class BackgroundImageController: ObservableObject {
    struct Content {
        let image: CGImage
    }

    private struct DesktopWindow: Equatable {
        let displayID: CGDirectDisplayID
        let windowID: CGWindowID
    }

    private enum CacheKey: Equatable {
        case desktop(DesktopWindow)
        case custom(path: String, fileSize: Int, modificationTime: TimeInterval, targetMaxDimension: Int)
    }

    private enum RequestIdentity: Equatable {
        case desktop(displayID: CGDirectDisplayID)
        case custom(path: String)
    }

    private typealias CGWindowListCreateImageFunction = @convention(c) (
        CGRect,
        CGWindowListOption,
        CGWindowID,
        CGWindowImageOption
    ) -> Unmanaged<CGImage>?

    nonisolated private static let maximumDecodedPixelCount = 4_000_000
    nonisolated private static let windowImageFunction: CGWindowListCreateImageFunction? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ), let symbol = dlsym(handle, "CGWindowListCreateImage") else {
            return nil
        }
        return unsafeBitCast(symbol, to: CGWindowListCreateImageFunction.self)
    }()

    @Published private(set) var content: Content?

    private var activeCacheKey: CacheKey?
    private var requestIdentity: RequestIdentity?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    func refresh(
        for screen: NSScreen?,
        enabled: Bool,
        source: AppStore.BackgroundImageSource,
        customImagePath: String,
        forceDesktopRefresh: Bool = false
    ) {
        guard enabled, let screen, let displayID = Self.displayID(for: screen) else {
            clear()
            return
        }

        let targetMaxDimension = max(
            1,
            Int(max(
                screen.frame.width * screen.backingScaleFactor,
                screen.frame.height * screen.backingScaleFactor
            ).rounded(.up))
        )

        switch source {
        case .desktopWallpaper:
            let identity = RequestIdentity.desktop(displayID: displayID)
            prepare(for: identity)
            refreshDesktop(
                displayID: displayID,
                force: forceDesktopRefresh
            )
        case .customImage:
            let path = customImagePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                clearContent(for: .custom(path: ""))
                return
            }
            let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            let identity = RequestIdentity.custom(path: normalizedPath)
            prepare(for: identity)
            refreshCustom(
                path: normalizedPath,
                targetMaxDimension: targetMaxDimension
            )
        }
    }

    func clear() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        requestIdentity = nil
        activeCacheKey = nil
        content = nil
    }

    private func prepare(for identity: RequestIdentity) {
        guard requestIdentity != identity else { return }
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        requestIdentity = identity
        activeCacheKey = nil
    }

    private func clearContent(for identity: RequestIdentity) {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        requestIdentity = identity
        activeCacheKey = nil
        content = nil
    }

    private func refreshDesktop(displayID: CGDirectDisplayID, force: Bool) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        if force {
            activeCacheKey = nil
        }
        loadTask = Task { [weak self] in
            defer {
                if let self, generation == self.loadGeneration {
                    self.loadTask = nil
                }
            }

            let desktopWindow = await Task.detached(priority: .userInitiated) {
                Self.findDesktopWallpaperWindow(for: displayID)
            }.value

            guard let self,
                  !Task.isCancelled,
                  generation == self.loadGeneration else {
                return
            }
            guard let desktopWindow else {
                self.activeCacheKey = nil
                self.content = nil
                return
            }

            let cacheKey = CacheKey.desktop(desktopWindow)
            if !force, self.activeCacheKey == cacheKey, self.content != nil {
                return
            }

            let image: CGImage? = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                autoreleasepool {
                    guard let captured = Self.capture(windowID: desktopWindow.windowID) else { return nil }
                    return Self.downsampleCapturedImageIfNeeded(captured)
                }
            }.value

            guard !Task.isCancelled, generation == self.loadGeneration else { return }
            guard let image else {
                self.activeCacheKey = nil
                self.content = nil
                return
            }

            self.activeCacheKey = cacheKey
            self.content = Content(image: image)
        }
    }

    private func refreshCustom(path: String, targetMaxDimension: Int) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        loadTask = Task { [weak self] in
            defer {
                if let self, generation == self.loadGeneration {
                    self.loadTask = nil
                }
            }

            let cacheKey = await Task.detached(priority: .userInitiated) {
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.isReadableFile(atPath: path) else { return CacheKey?.none }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return CacheKey.custom(
                    path: path,
                    fileSize: values?.fileSize ?? 0,
                    modificationTime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                    targetMaxDimension: targetMaxDimension
                )
            }.value

            guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
            guard let cacheKey else {
                self.activeCacheKey = nil
                self.content = nil
                return
            }
            if self.activeCacheKey == cacheKey, self.content != nil {
                return
            }

            let image = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    Self.decodeCustomImage(
                        at: URL(fileURLWithPath: path),
                        targetMaxDimension: targetMaxDimension
                    )
                }
            }.value

            guard !Task.isCancelled, generation == self.loadGeneration else { return }
            guard let image else {
                self.activeCacheKey = nil
                self.content = nil
                return
            }

            self.activeCacheKey = cacheKey
            self.content = Content(image: image)
        }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    nonisolated private static func findDesktopWallpaperWindow(
        for displayID: CGDirectDisplayID
    ) -> DesktopWindow? {
        let displayBounds = CGDisplayBounds(displayID)
        guard displayBounds.width > 0, displayBounds.height > 0 else { return nil }

        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] ?? []

        return windows.compactMap { info -> (window: DesktopWindow, score: CGFloat)? in
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let name = info[kCGWindowName as String] as? String ?? ""
            let normalizedName = name.lowercased()
            let isWallpaperWindow = (owner == "WindowManager" && normalizedName == "wallpaper")
                || (owner == "Dock" && normalizedName.hasPrefix("wallpaper"))
            guard isWallpaperWindow,
                  let windowIDNumber = info[kCGWindowNumber as String] as? NSNumber,
                  let bounds = windowBounds(from: info[kCGWindowBounds as String]) else {
                return nil
            }

            let intersection = bounds.intersection(displayBounds)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }
            let displayArea = displayBounds.width * displayBounds.height
            let score = (intersection.width * intersection.height) / displayArea
            guard score >= 0.5 else { return nil }

            return (
                DesktopWindow(displayID: displayID, windowID: CGWindowID(windowIDNumber.uint32Value)),
                score
            )
        }
        .max(by: { $0.score < $1.score })?
        .window
    }

    nonisolated private static func windowBounds(from value: Any?) -> CGRect? {
        guard let dictionary = value as? [String: Any],
              let x = (dictionary["X"] as? NSNumber)?.doubleValue,
              let y = (dictionary["Y"] as? NSNumber)?.doubleValue,
              let width = (dictionary["Width"] as? NSNumber)?.doubleValue,
              let height = (dictionary["Height"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    nonisolated private static func capture(windowID: CGWindowID) -> CGImage? {
        windowImageFunction?(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )?.takeRetainedValue()
    }

    nonisolated private static func downsampleCapturedImageIfNeeded(_ image: CGImage) -> CGImage? {
        let pixelCount = image.width * image.height
        guard pixelCount > maximumDecodedPixelCount else { return image }

        let scale = sqrt(Double(maximumDecodedPixelCount) / Double(pixelCount))
        let width = max(1, Int((Double(image.width) * scale).rounded(.down)))
        let height = max(1, Int((Double(image.height) * scale).rounded(.down)))
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    nonisolated private static func decodeCustomImage(
        at url: URL,
        targetMaxDimension: Int
    ) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0,
              height > 0 else {
            return nil
        }

        let sourceMaxDimension = max(width, height)
        let dimensionScale = min(1, Double(targetMaxDimension) / sourceMaxDimension)
        let pixelScale = min(1, sqrt(Double(maximumDecodedPixelCount) / (width * height)))
        let thumbnailMaxDimension = max(
            1,
            Int((sourceMaxDimension * min(dimensionScale, pixelScale)).rounded(.down))
        )
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }
}

final class BackgroundImageLayerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        layer?.contents = nil
    }
}

struct LaunchpadBackgroundImageView: NSViewRepresentable {
    let image: CGImage?

    func makeNSView(context: Context) -> BackgroundImageLayerView {
        BackgroundImageLayerView(frame: .zero)
    }

    func updateNSView(_ nsView: BackgroundImageLayerView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        nsView.layer?.contents = image
        CATransaction.commit()
    }

    static func dismantleNSView(_ nsView: BackgroundImageLayerView, coordinator: Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        nsView.layer?.contents = nil
        CATransaction.commit()
    }
}
