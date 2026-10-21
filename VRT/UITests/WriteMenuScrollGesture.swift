import XCTest

/// Scrolls only within the independently identified native clipping viewport.
@MainActor enum WriteMenuScrollGesture {
    static func reveal(
        _ element: XCUIElement,
        in app: XCUIApplication,
        menu: XCUIElement,
        viewport: CGRect,
        needsHitTarget: Bool
    ) -> Bool {
        let visible = {
            element.exists && !element.frame.isEmpty && viewport.contains(element.frame) &&
                (!needsHitTarget || element.isHittable)
        }
        if visible() {
            return true
        }
        guard discover(element, in: app, menu: menu, viewport: viewport) else { return false }
        // Native menu pans can consume part of a drag before scrolling. Allow
        // bounded continued alignment only while the clipping deficit decreases.
        // No menu action is retried and full containment remains required.
        for _ in 0 ..< 12 {
            if visible() {
                return true
            }
            let before = element.frame
            guard before.height <= viewport.height, before.width <= viewport.width else { return false }
            guard menu.exists, step(element, in: app, viewport: viewport, searchDownward: false) else { return false }
            if visible() {
                return true
            }
            guard element.exists, !element.frame.isEmpty,
                  clippingDeficit(element.frame, in: viewport) < clippingDeficit(before, in: viewport)
            else { return false }
        }
        return visible()
    }

    private static func clippingDeficit(_ target: CGRect, in viewport: CGRect) -> CGFloat {
        max(0, viewport.minY - target.minY) + max(0, target.maxY - viewport.maxY)
    }

    private static func hasGeometry(_ element: XCUIElement) -> Bool {
        element.exists && !element.frame.isEmpty
    }

    private static func discover(
        _ element: XCUIElement, in app: XCUIApplication, menu: XCUIElement, viewport: CGRect
    ) -> Bool {
        for downward in [true, false] {
            for _ in 0 ..< 8 {
                if hasGeometry(element) {
                    return true
                }
                guard menu.exists else { return false }
                let before = menu.buttons.allElementsBoundByIndex.map(\.frame)
                guard step(element, in: app, viewport: viewport, searchDownward: downward) else { return false }
                if hasGeometry(element) {
                    return true
                }
                // At a scroll boundary, reverse once rather than repeating stationary drags.
                if menu.buttons.allElementsBoundByIndex.map(\.frame) == before {
                    break
                }
            }
        }
        return hasGeometry(element)
    }

    static func step(_ element: XCUIElement, in app: XCUIApplication, viewport: CGRect, searchDownward: Bool) -> Bool {
        let target = element.exists ? element.frame : .zero
        let downward: Bool
        let distance: CGFloat
        if !target.isEmpty {
            if target.minY < viewport.minY {
                downward = true
                distance = viewport.minY - target.minY
            } else if target.maxY > viewport.maxY {
                downward = false
                distance = target.maxY - viewport.maxY
            } else {
                // A fully contained but unhittable action is not a scrolling problem.
                return false
            }
        } else {
            // Lazy menu cells have no geometry. Search a bounded small sweep,
            // then reverse; switch to exact target geometry as soon as it exists.
            downward = searchDownward
            distance = viewport.height / 3
        }
        let padding = target.isEmpty ? 12 : min(12, max(0, (viewport.height - target.height) / 2))
        let movement = min(viewport.height * 2 / 3, max(24, distance + padding))
        let origin = app.coordinate(withNormalizedOffset: .zero)
        // Start opposite the scroll direction so the whole sweep stays inside
        // the clipping viewport instead of limiting every pan to half its height.
        let startY = downward ? viewport.minY + viewport.height / 6 : viewport.maxY - viewport.height / 6
        let start = origin.withOffset(CGVector(dx: viewport.midX, dy: startY))
        let end = origin.withOffset(CGVector(
            dx: viewport.midX,
            dy: startY + (downward ? movement : -movement)
        ))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        return true
    }
}
