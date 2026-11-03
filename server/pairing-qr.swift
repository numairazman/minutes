// Shows a QR code that pairs the Minutes iPhone app with this server: scan it with the
// iPhone's Camera and Minutes saves the PC's address and token itself.
//
//   swift server/pairing-qr.swift [pc-address]      (from the repo root, on the Mac)
//
// The token comes from server/.env (MINUTES_TOKEN). The address defaults to the one in
// server/.env's PC_ADDRESS, if set. The code holds the token, so treat it like the token:
// don't post it anywhere.
import AppKit
import CoreImage
import Foundation

let envURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent(".env")
guard let env = try? String(contentsOf: envURL, encoding: .utf8) else {
    print("No server/.env next to this script. Create it from server/.env.example first.")
    exit(1)
}
func value(_ key: String) -> String? {
    env.split(separator: "\n").first { $0.hasPrefix("\(key)=") }
        .map { String($0.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) }
        .flatMap { $0.isEmpty ? nil : $0 }
}
guard let token = value("MINUTES_TOKEN") else {
    print("server/.env has no MINUTES_TOKEN.")
    exit(1)
}
guard let address = CommandLine.arguments.dropFirst().first ?? value("PC_ADDRESS") else {
    print("Give the PC's address: swift server/pairing-qr.swift 192.168.1.168")
    exit(1)
}

var components = URLComponents()
components.scheme = "minutes"
components.host = "pair"
components.queryItems = [URLQueryItem(name: "address", value: address), URLQueryItem(name: "token", value: token)]
let link = components.string!

let filter = CIFilter(name: "CIQRCodeGenerator")!
filter.setValue(Data(link.utf8), forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")
let qr = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 16, y: 16))
let rep = NSCIImageRep(ciImage: qr)
let image = NSImage(size: rep.size)
image.addRepresentation(rep)

// Flatten onto a white margin so phone cameras lock on quickly.
let side = rep.size.width + 96
let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: side, height: side).fill()
image.draw(in: NSRect(x: 48, y: 48, width: rep.size.width, height: rep.size.height))
NSGraphicsContext.restoreGraphicsState()

let out = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-pairing.png")
try canvas.representation(using: .png, properties: [:])!.write(to: out)
print("Scan this with the iPhone's Camera to pair Minutes with \(address).")
NSWorkspace.shared.open(out)
