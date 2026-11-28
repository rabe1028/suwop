import XCTest

extension XCUIApplication {
    /// Opens the gallery options menu and its records submenu. Large text turns both
    /// into scrolling native menus, so each entry is revealed in its clipping viewport.
    @MainActor @discardableResult func openRecordsMenu() -> Bool {
        let menu = buttons["表示と操作"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        return tapNativeMenuItem(buttons["recordsMenu"])
    }

    /// Opens a record or guidance screen from the records submenu.
    @MainActor @discardableResult func openRecord(_ identifier: String) -> Bool {
        openRecordsMenu() && tapNativeMenuItem(buttons[identifier])
    }

    /// Taps an open native-menu item after revealing it inside the menu's clipping viewport.
    @MainActor func tapNativeMenuItem(_ item: XCUIElement) -> Bool {
        _ = item.waitForExistence(timeout: 5)
        guard WriteMenuScrollGesture.revealGalleryItem(item, in: self), item.isEnabled, item.isHittable else {
            XCTFail("\(item) must be enabled and fully visible in the native menu viewport")
            return false
        }
        item.tap()
        return true
    }
}
