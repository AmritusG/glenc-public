// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit

/// v0.9.0.3 — scrub bar with "the timeline IS the trim" interaction
/// model. The whole bar's left half (`x < totalW/2`) adjusts
/// `inFrame`; the right half adjusts `outFrame`. Clicking jumps that
/// trim point to the cursor; dragging continues to follow. The
/// half is locked at the start of the drag so dragging across the
/// midpoint doesn't switch sides mid-gesture.
///
/// The playhead thumb is the ONLY way to seek — its hit area
/// (a Circle via `.contentShape(Circle())`) takes precedence over
/// the bar's full-width gesture when the user clicks on the thumb
/// itself; clicks outside the thumb fall through to the trim gesture.
///
/// Double-click on left or right half opens a HH:MM:SS:FF popover
/// for precise editing.
struct ScrubBar: View {
    @ObservedObject var model: PreviewPlayerModel

    @State private var isDraggingPlayhead: Bool = false
    @State private var wasPlayingBeforeDrag: Bool = false
    @State private var showInPopover: Bool = false
    @State private var showOutPopover: Bool = false

    private let trackHeight: CGFloat = 8
    private let thumbDiameter: CGFloat = 14
    private let thumbHitDiameter: CGFloat = 24
    /// Total height of the interactive area — taller than the visible
    /// track so the cursor doesn't have to land pixel-perfect on the
    /// 8pt-tall track to hit the trim gesture.
    private let barHitHeight: CGFloat = 28

    private let coordSpace = "scrubBar"

    var body: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            ZStack(alignment: .leading) {
                // (1) Full-width invisible gesture surface for trim
                // adjust. Behind everything else visually but its
                // gesture fires whenever the click isn't captured by
                // the playhead thumb (which sits on top).
                Color.clear
                    .frame(width: totalW, height: barHitHeight)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2, coordinateSpace: .named(coordSpace))
                            .onEnded { value in
                                let leftHalf = value.location.x < totalW / 2
                                if leftHalf { showInPopover = true } else { showOutPopover = true }
                            }
                    )
                    .gesture(barTrimGesture(totalW: totalW))

                // (2) Track background (gray, non-interactive — the
                // gesture surface above catches clicks).
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: trackHeight)
                    .allowsHitTesting(false)

                // (3) Trim region overlay (accent fill between in and out).
                if model.totalFrames > 1 {
                    let inX = trimInX(totalW: totalW)
                    let outX = trimOutX(totalW: totalW)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.5))
                        .frame(width: max(0, outX - inX), height: trackHeight)
                        .offset(x: inX)
                        .allowsHitTesting(false)
                }

                // (4) Playhead thumb — only this seeks. Z-order LAST
                // so its hit area wins when the user clicks directly
                // on the thumb. The contentShape Circle limits the
                // hit area to the visible circle (not its bounding
                // rect), so clicks near-but-not-on the thumb fall
                // through to the trim gesture.
                if model.totalFrames > 1 {
                    playheadThumb(totalW: totalW)
                }
            }
            .frame(height: barHitHeight)
            .coordinateSpace(name: coordSpace)
            // Popovers anchored to the bar; their `isPresented` is
            // driven by the SpatialTapGesture above.
            .popover(isPresented: $showInPopover, arrowEdge: .top) {
                TimecodePopover(
                    title: "Set in-point",
                    initialFrame: model.inFrame ?? 0,
                    fps: model.frameRate,
                    totalFrames: model.totalFrames,
                    onSet: { newFrame in
                        let last = max(0, model.totalFrames - 1)
                        let outClamp = model.outFrame ?? last
                        let clamped = max(0, min(newFrame, max(0, outClamp - 1)))
                        model.inFrame = clamped
                        showInPopover = false
                    },
                    onCancel: { showInPopover = false }
                )
            }
            .popover(isPresented: $showOutPopover, arrowEdge: .top) {
                TimecodePopover(
                    title: "Set out-point",
                    initialFrame: model.outFrame ?? max(0, model.totalFrames - 1),
                    fps: model.frameRate,
                    totalFrames: model.totalFrames,
                    onSet: { newFrame in
                        let last = max(0, model.totalFrames - 1)
                        let inClamp = model.inFrame ?? 0
                        let clamped = min(last, max(newFrame, inClamp + 1))
                        model.outFrame = clamped
                        showOutPopover = false
                    },
                    onCancel: { showOutPopover = false }
                )
            }
        }
        .frame(height: barHitHeight)
    }

    // MARK: - Bar trim gesture

    private func barTrimGesture(totalW: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordSpace))
            .onChanged { value in
                guard model.totalFrames > 1 else { return }
                let last = model.totalFrames - 1
                // Lock to the half decided at the START of the drag
                // so dragging past midpoint doesn't switch sides.
                let startedLeft = value.startLocation.x < totalW / 2
                let target = frameForX(value.location.x, width: totalW)
                if startedLeft {
                    let outClamp = model.outFrame ?? last
                    let snapped = max(0, min(target, max(0, outClamp - 1)))
                    if model.inFrame != snapped { model.inFrame = snapped }
                } else {
                    let inClamp = model.inFrame ?? 0
                    let snapped = min(last, max(target, inClamp + 1))
                    if model.outFrame != snapped { model.outFrame = snapped }
                }
            }
    }

    // MARK: - Playhead

    private func playheadThumb(totalW: CGFloat) -> some View {
        let x = thumbX(totalW: totalW)
        return Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.secondary.opacity(0.6), lineWidth: 0.5))
            .frame(width: thumbDiameter, height: thumbDiameter)
            .shadow(radius: 1)
            .frame(width: thumbHitDiameter, height: thumbHitDiameter)
            .contentShape(Circle())  // hit only the visible circle, not bounding rect
            .offset(x: x - thumbHitDiameter / 2)
            .gesture(playheadGesture(totalW: totalW))
    }

    private func playheadGesture(totalW: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordSpace))
            .onChanged { value in
                if !isDraggingPlayhead {
                    isDraggingPlayhead = true
                    wasPlayingBeforeDrag = (model.playState == .playing)
                    if wasPlayingBeforeDrag { model.pause() }
                }
                let frame = frameForX(value.location.x, width: totalW)
                if frame != model.currentFrame {
                    model.seek(to: frame)
                }
            }
            .onEnded { _ in
                isDraggingPlayhead = false
                if wasPlayingBeforeDrag { model.play() }
                wasPlayingBeforeDrag = false
            }
    }

    // MARK: - Geometry helpers

    private var playheadFraction: Double {
        guard model.totalFrames > 1 else { return 0 }
        let p = Double(model.currentFrame) / Double(model.totalFrames - 1)
        return min(max(p, 0), 1)
    }

    private func thumbX(totalW: CGFloat) -> CGFloat {
        CGFloat(playheadFraction) * totalW
    }

    private func trimInX(totalW: CGFloat) -> CGFloat {
        let f = model.inFrame ?? 0
        return positionForFrame(f, totalW: totalW)
    }

    private func trimOutX(totalW: CGFloat) -> CGFloat {
        let f = model.outFrame ?? max(0, model.totalFrames - 1)
        return positionForFrame(f, totalW: totalW)
    }

    private func frameForX(_ x: CGFloat, width: CGFloat) -> Int {
        guard model.totalFrames > 1, width > 0 else { return 0 }
        let clamped = max(0, min(width, x))
        let t = Double(clamped / width)
        return Int((t * Double(model.totalFrames - 1)).rounded())
    }

    private func positionForFrame(_ f: Int, totalW: CGFloat) -> CGFloat {
        guard model.totalFrames > 1 else { return 0 }
        let t = Double(f) / Double(model.totalFrames - 1)
        return CGFloat(min(max(t, 0), 1)) * totalW
    }
}
