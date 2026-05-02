import AppKit

extension NSImage {
    /// Returns a non-template copy of the image, drawn at `size` and recolored
    /// with `color`. Used for menu-bar logos where we want a fixed colour
    /// (white by default) regardless of the system's appearance, with
    /// recoloring on usage warnings.
    func tinted(with color: NSColor, size: NSSize) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        defer { result.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size)
        // Draw the source as the alpha mask.
        self.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        // Multiply by the target colour, keeping only the source's alpha.
        color.set()
        rect.fill(using: .sourceIn)
        return result
    }
}
