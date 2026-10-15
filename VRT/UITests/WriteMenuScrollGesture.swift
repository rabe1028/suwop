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
        // Late discovery gets its own bounded alignment budget. No action is retried.
        for _ in 0 ..< 6 {
            if visible() {
                return true
            }
            let before = element.frame
            guard menu.exists, step(element, in: app, viewport: viewport, searchDownward: false) else { return false }
            if visible() {
                return true
            }
            guard element.exists, !element.frame.isEmpty, element.frame != before else { return false }
        }
        return visible()
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
        let movement = min(viewport.height / 3, max(24, distance + 12))
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: viewport.midX, dy: viewport.midY))
        let end = origin.withOffset(CGVector(
            dx: viewport.midX,
            dy: viewport.midY + (downward ? movement : -movement)
        ))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        return true
    }
}
