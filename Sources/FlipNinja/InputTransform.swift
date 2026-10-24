import CoreGraphics

/// Pure coordinate math for a rotated built-in display.
///
/// The angles mirror the values passed to the private display-rotation API:
/// `0` = landscape, `1` = 90°, `2` = 180°, `3` = 270°. Only 90° and 270° are
/// exposed by the UI, but 180° is handled for completeness.
///
/// With the MacBook standing on its right edge (270°), the user's physical
/// "up" is the device's negative X axis. Device deltas therefore rotate into
/// screen space by `(dx, dy) -> (-dy, dx)`.
enum InputTransform {

    /// Maps a pointing-device delta from device space into rotated screen space.
    static func pointerDelta(
        dx: Int64,
        dy: Int64,
        rotation: Int
    ) -> (dx: Int64, dy: Int64) {
        switch rotation {
        case 90:
            return (dy, -dx)
        case 180:
            return (-dx, -dy)
        case 270:
            return (-dy, dx)
        default:
            return (dx, dy)
        }
    }

    /// Maps scroll deltas. CoreGraphics reports `axis1` as vertical and
    /// `axis2` as horizontal. Scroll values describe content movement, so the
    /// inverse of the pointer rotation is used; this also preserves whatever
    /// Natural Scrolling direction the system is configured for.
    static func scrollDeltas(
        vertical: Int64,
        horizontal: Int64,
        rotation: Int
    ) -> (vertical: Int64, horizontal: Int64) {
        switch rotation {
        case 90:
            return (horizontal, -vertical)
        case 180:
            return (vertical, horizontal)
        case 270:
            return (-horizontal, vertical)
        default:
            return (vertical, horizontal)
        }
    }
}
