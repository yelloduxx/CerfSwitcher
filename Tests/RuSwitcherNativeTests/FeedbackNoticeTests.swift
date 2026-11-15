import AppKit
import XCTest
@testable import RuSwitcher

final class FeedbackNoticeTests: XCTestCase {
    @MainActor
    func testShortNoticeUsesCompactHeightAndHasDismissAction() async throws {
        _ = NSApplication.shared
        let controller = FeedbackNoticeController()
        let view = controller.makeContent(message: "Replacement sent, not confirmed", offersUndo: false)
        XCTAssertEqual(view.frame.width, 356)
        XCTAssertGreaterThan(view.frame.height, 50)
        XCTAssertLessThan(view.frame.height, 92)
        let buttons = descendants(view).compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 1)
        let close = try XCTUnwrap(buttons.first)
        XCTAssertEqual(close.identifier?.rawValue, "notice.close")
        XCTAssertNotNil(close.action)
        XCTAssertTrue(close.target === controller)
        XCTAssertFalse(close.accessibilityLabel()?.isEmpty ?? true)
    }

    @MainActor
    func testLongLocalizedNoticeGrowsInsteadOfClipping() async {
        _ = NSApplication.shared
        let message = "Замена запомнена для всех приложений. Последнее сохранение можно отменить."
        let view = FeedbackNoticeController().makeContent(message: message, offersUndo: true)
        let window = FeedbackNoticeController.makePanel(content: view)
        view.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        XCTAssertEqual(view.frame.width, 356)
        XCTAssertGreaterThan(view.frame.height, 92)
        for child in descendants(view) where child is NSTextField || child is NSButton {
            let frame = child.convert(child.bounds, to: view)
            XCTAssertTrue(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "Clipped \(type(of: child))")
            XCTAssertGreaterThan(frame.height, 0)
        }
        XCTAssertTrue(descendants(view).contains { $0.identifier?.rawValue == "notice.undo" })
    }

    @MainActor
    func testNoticePanelCannotStealKeyboardFocus() async {
        _ = NSApplication.shared
        let view = FeedbackNoticeController().makeContent(message: "Saved", offersUndo: false)
        let panel = FeedbackNoticeController.makePanel(content: view)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor.alphaComponent, 0)
        XCTAssertTrue(panel.hasShadow)
        panel.contentView = nil
    }

    @MainActor
    func testModernNoticeUsesNativeGlassShapeWithEmbeddedContent() async throws {
        _ = NSApplication.shared
        if #available(macOS 26.0, *) {
            let view = FeedbackNoticeController().makeContent(message: "Saved", offersUndo: true)
            let glass = try XCTUnwrap(view as? NSGlassEffectView)
            XCTAssertEqual(glass.style, .regular)
            XCTAssertEqual(glass.cornerRadius, 26)
            let content = try XCTUnwrap(glass.contentView)
            XCTAssertTrue(descendants(content).contains { $0.identifier?.rawValue == "notice.undo" })
        }
    }

    @MainActor
    func testRenderedNoticeHasNoOpaqueRectangleOutsideItsCorners() async throws {
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = FeedbackNoticeController().makeContent(message: "Saved", offersUndo: true)
            let panel = FeedbackNoticeController.makePanel(content: view)
            panel.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            defer { panel.contentView = nil }
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let width = bitmap.pixelsWide
            let height = bitmap.pixelsHigh
            for point in [(1, 1), (width - 2, 1), (1, height - 2), (width - 2, height - 2)] {
                XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1)).alphaComponent, 0.01)
            }
            // A blank snapshot must not pass the corner check.
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: width / 2, y: height / 2)).alphaComponent, 0.5)
        }
    }

    @MainActor
    func testLegacyMaterialMaskHasTransparentCornersAtBothScales() async throws {
        _ = NSApplication.shared
        let background = FeedbackNoticeController.makeLegacyBackground(
            frame: NSRect(x: 0, y: 0, width: 356, height: 110))
        let mask = try XCTUnwrap(background.maskImage)
        XCTAssertEqual(mask.resizingMode, .stretch)
        for scale in [1, 2] {
            let width = Int(background.frame.width) * scale
            let height = Int(background.frame.height) * scale
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            mask.draw(in: background.bounds)
            NSGraphicsContext.restoreGraphicsState()
            for point in [(1, 1), (width - 2, 1), (1, height - 2), (width - 2, height - 2)] {
                XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1)).alphaComponent, 0.01)
            }
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: width / 2, y: height / 2)).alphaComponent, 0.99)
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: width / 2, y: 1)).alphaComponent, 0.99)
        }
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
