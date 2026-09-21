#!/usr/bin/env swift
// Renders Resources/AppIcon.icns: a blue squircle with white line art of a small
// app window inside a circular refresh arrow.
//
// Reproduce with stock macOS tools only (Swift, CoreGraphics, iconutil):
//
//     swift scripts/make-app-icon.swift            # writes Resources/AppIcon.icns
//     swift scripts/make-app-icon.swift out.icns   # or somewhere else
//
// The drawing is a pure function of the constants below, so the output is
// reproducible; change the design here, never edit the .icns by hand.

import AppKit
import CoreGraphics
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"

/// Draws the icon at `size` x `size` pixels into a bitmap and returns PNG data.
func renderPNG(size: Int) -> Data {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: the squircle fills 824 of 1024 points, centered.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(
        roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Blue gradient background, lighter at the top.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 0.30, green: 0.62, blue: 1.00, alpha: 1),
            CGColor(red: 0.04, green: 0.31, blue: 0.86, alpha: 1),
        ] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // White line art.
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.setStrokeColor(white)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // App window: rounded rectangle with a title bar line.
    ctx.setLineWidth(34)
    let window = CGRect(x: 392, y: 400, width: 240, height: 224)
    ctx.addPath(CGPath(roundedRect: window, cornerWidth: 44, cornerHeight: 44, transform: nil))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: window.minX, y: window.maxY - 62))
    ctx.addLine(to: CGPoint(x: window.maxX, y: window.maxY - 62))
    ctx.strokePath()

    // Two refresh arcs around the window, each ending in an arrowhead.
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 250
    ctx.setLineWidth(40)
    // Each arc sweeps clockwise (the arrow direction); the gaps hold the heads.
    func arc(from startDeg: CGFloat, to endDeg: CGFloat) {
        // Clockwise sweep from startDeg down to endDeg.
        ctx.addArc(
            center: center, radius: radius,
            startAngle: startDeg * .pi / 180, endAngle: endDeg * .pi / 180, clockwise: true)
        ctx.strokePath()
    }
    func head(atDeg deg: CGFloat) {
        // Arrowhead at the clockwise end of an arc: a chevron pointing along the
        // direction of travel (tangent, clockwise = angle decreasing).
        let a = deg * .pi / 180
        let tip = CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
        let tangent = CGPoint(x: sin(a), y: -cos(a))  // direction of decreasing angle
        let normal = CGPoint(x: cos(a), y: sin(a))
        let len: CGFloat = 78
        let spread: CGFloat = 52
        let tipForward = CGPoint(x: tip.x + tangent.x * 34, y: tip.y + tangent.y * 34)
        let back = CGPoint(x: tipForward.x - tangent.x * len, y: tipForward.y - tangent.y * len)
        ctx.move(to: CGPoint(x: back.x + normal.x * spread, y: back.y + normal.y * spread))
        ctx.addLine(to: tipForward)
        ctx.addLine(to: CGPoint(x: back.x - normal.x * spread, y: back.y - normal.y * spread))
        ctx.strokePath()
    }
    arc(from: 165, to: 45)  // upper-left to upper-right
    head(atDeg: 45)
    arc(from: -15, to: -135)  // lower-right to lower-left
    head(atDeg: -135)

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

// iconutil wants an .iconset directory with these exact names.
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("OpenFreshr-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for entry in entries {
    try renderPNG(size: entry.px).write(
        to: iconset.appendingPathComponent(entry.name + ".png"))
}

let out = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(
    at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["--convert", "icns", "--output", out.path, iconset.path]
try tool.run()
tool.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(tool.terminationStatus)
