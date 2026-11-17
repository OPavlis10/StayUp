// Vykreslí ikonu aplikace Stay Up do PNG 1024×1024. Použití: swift Tools/make-icon.swift <výstup.png>
import AppKit

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Mřížka ikon macOS: tvar 824×824 uprostřed plátna 1024, poloměr rohu asi 185.
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

// Jemný stín pod tvarem.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.30).cgColor)
NSColor.black.setFill()
shape.fill()
ctx.restoreGState()

// Pozadí: noční modrá přecházející do indigové.
ctx.saveGState()
shape.addClip()
let colors = [NSColor(srgbRed: 0.36, green: 0.42, blue: 0.98, alpha: 1).cgColor,
              NSColor(srgbRed: 0.10, green: 0.11, blue: 0.32, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
// Teplá záře vpravo nahoře jako světlo, které zůstává svítit.
let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                      colors: [NSColor(srgbRed: 1.0, green: 0.78, blue: 0.35, alpha: 0.55).cgColor,
                               NSColor(srgbRed: 1.0, green: 0.78, blue: 0.35, alpha: 0).cgColor] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 760, y: 800), startRadius: 0,
                       endCenter: CGPoint(x: 760, y: 800), endRadius: 520, options: [])
ctx.restoreGState()

// Bílý symbol šálku, stejný jako v liště při zapnutém bdění.
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    let scale = min(520 / s.width, 520 / s.height)
    let w = s.width * scale, h = s.height * scale
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    symbol.draw(in: CGRect(x: (size - w) / 2, y: (size - h) / 2 - 6, width: w, height: h))
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
