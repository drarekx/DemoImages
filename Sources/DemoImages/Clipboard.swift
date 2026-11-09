import AppKit
import UniformTypeIdentifiers

/// Copies library images so they paste anywhere: Finder gets the file, a web form,
/// chat or document gets the picture.
enum Clipboard {
    static func copy(_ urls: [URL], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard urls.count == 1, let url = urls.first else {
            // Several files: Finder-style file list.
            pasteboard.writeObjects(urls.map { $0 as NSURL })
            return
        }

        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        // The file's own bytes under its type (public.png, org.webmproject.webp…).
        if let type = UTType(filenameExtension: url.pathExtension), let data = try? Data(contentsOf: url) {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        // PNG too: browsers and most apps paste images as PNG, whatever the file is.
        if url.pathExtension.lowercased() != "png", let png = pngData(url) {
            item.setData(png, forType: .png)
        }
        pasteboard.writeObjects([item])
    }

    private static func pngData(_ url: URL) -> Data? {
        guard let image = try? ImageEncoder.loadImage(url) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
