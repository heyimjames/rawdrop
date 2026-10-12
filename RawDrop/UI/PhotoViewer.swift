import SwiftUI
import Photos

/* ─────────────────────────────────────────────────────────
 * VIEWER STORYBOARD
 *
 *  tap tile     the tile goes dark; a square copy of the photo lifts
 *               off the grid and arcs into its fitted place (spring,
 *               ~420ms), un-cropping as it grows; chrome fades in from
 *               120ms; the pager takes over underneath when it lands
 *  flick ←→     next / previous photo, newest on the left. Pages leave
 *               like cards: the outgoing photo tilts away (10° about Y),
 *               shrinks to 92% and fades to 75% as it crosses the edge;
 *               the incoming one arrives flat. A soft tick as it lands.
 *               Reduce Motion: flat slide, tick stays. (see Carousel)
 *
 *  CAPTION      stays put. When the page settles the filename digits
 *               roll to the next frame number; camera · lens does not
 *               move when unchanged; exposure numbers roll as the new
 *               EXIF arrives. Reduce Motion: crossfade only.
 *  tap ring     (bottom left, by the thumb) or double-tap the photo:
 *               medium tap; the photo dips; the amber frame settles onto
 *               it from 1.03 on the toy spring; the ring pops; the send
 *               count ticks. Deselect: soft tap, frame fades, no motion.
 *  heart        top right, opposite close. Sets the favourite in Photos
 *               itself; the heart fills and pops on the toy spring with
 *               a light tap, the grid tile's heart lands with it.
 *  pull down    the photo follows the finger, backdrop thins
 *  release      past 110pt or flicked → the copy flies back, cropping
 *               to 1:1 and landing on its tile (grid already scrolled
 *               there); else springs back to centre
 *
 *  Layout is four stacked bands, top to bottom: chrome, stage, caption,
 *  button. They never overlap, so nothing ever covers a control.
 * ───────────────────────────────────────────────────────── */

struct PhotoViewer: View {
    let photos: [RawPhoto]
    /// Each photo's index in `photos`.
    let position: [String: Int]
    @Binding var current: String?
    let library: RawLibrary
    let sentIDs: Set<String>
    let selection: Set<String>
    let favouriteIDs: Set<String>
    let isBusy: Bool
    /// On-screen frame of a photo's grid tile, if that tile is realised.
    let origin: (String) -> CGRect?
    let toggleSelect: (RawPhoto) -> Void
    let toggleFavourite: (RawPhoto) -> Void
    let sendCurrent: (RawPhoto) -> Void
    let sendSelection: () -> Void
    let trimSelection: () -> Void
    /// Called before the exit animation, so the grid can bring the tile on screen.
    let willDismiss: () -> Void
    /// Called after the exit animation. The parent removes the viewer here.
    let didDismiss: () -> Void

    @State private var pull: CGFloat = 0
    /// 0 = the photo is on its tile, 1 = in place in the viewer. Drives the
    /// flying copy on open and close; the pager is only shown at 1.
    @State private var hero: CGFloat = 0
    @State private var flying = true
    /// Stays a beat longer than `flying` so the pager's first frame is covered.
    @State private var heroVisible = true
    @State private var heroImage: UIImage?
    @State private var closing = false
    @State private var closeTask: Task<Void, Never>?
    @State private var stageFrame: CGRect = .zero
    @State private var hostFrame: CGRect = .zero
    @State private var shot: ShotInfo?
    /// Bumped by a double-tap so the ring can pop in acknowledgement.
    @State private var ringPop = 0
    /// Haptic triggers: selecting is a firmer tap than deselecting.
    @State private var selects = 0
    @State private var deselects = 0
    @State private var hearts = 0
    /// Mirror of the selection that the hosted pages can observe. Pages are
    /// built once by UIKit, so they cannot read the parent's state directly.
    @State private var pageState = PageState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentPhoto: RawPhoto? {
        guard let current, let i = position[current], photos.indices.contains(i) else { return nil }
        return photos[i]
    }

    private var fade: Double { Double(hero) * (1 - Double(min(pull / 140, 1))) }

    /// Where the photo sits when fitted into the stage, in host coordinates.
    private func fittedRect(for photo: RawPhoto) -> CGRect {
        let stage = stageFrame.offsetBy(dx: -hostFrame.minX, dy: -hostFrame.minY)
        let inset = stage.insetBy(dx: 12, dy: 0)
        let aspect = CGFloat(max(photo.asset.pixelWidth, 1)) / CGFloat(max(photo.asset.pixelHeight, 1))
        var w = inset.width
        var h = w / aspect
        if h > inset.height { h = inset.height; w = h * aspect }
        return CGRect(x: inset.midX - w / 2, y: inset.midY - h / 2, width: w, height: h)
    }

    private func tileRect(for id: String) -> CGRect? {
        origin(id).map { $0.offsetBy(dx: -hostFrame.minX, dy: -hostFrame.minY) }
    }

    private var isOver: Bool { selection.count > Handoff.selectionLimit }

    var body: some View {
        ZStack {
            Color.black
                .opacity(Double(hero) * Double(1 - min(pull / 320, 0.8)))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                chrome
                    .opacity(fade)

                stage
                    .offset(y: pull)
                    .scaleEffect(1 - min(pull / 1400, 0.12))

                caption
                    .opacity(fade)

                footer
                    .opacity(fade)
            }
        }
        .coordinateSpace(name: "viewer")
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { hostFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.size) { _, _ in hostFrame = proxy.frame(in: .global) }
            }
        }
        .overlay { heroLayer }
        .gesture(pullToDismiss)
        .onAppear {
            open()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-auto-close") {
                Task { try? await Task.sleep(for: .seconds(1.5)); dismiss() }
            }
            if ProcessInfo.processInfo.arguments.contains("-auto-page") {
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if let id = current, let i = position[id], photos.indices.contains(i + 1) {
                        current = photos[i + 1].id
                    }
                }
            }
            #endif
        }
        .onChange(of: selection, initial: true) { _, ids in pageState.selected = ids }
        .onChange(of: current) { _, _ in
            // A new photo arrived while closing (a tap on another tile, or a
            // deep link). Abandon the close and open on it instead.
            if closing {
                closeTask?.cancel()
                closing = false
                open()
            }
        }
        .onDisappear { closeTask?.cancel() }
        .task(id: current) {
            heroImage = nil
            guard let photo = currentPhoto else { return }
            // The grid already holds this photo at tile size, so that request
            // answers from cache before the copy has moved. Then sharpen.
            for await frame in Thumbnails.shared.stream(for: photo.asset, targetSize: CGSize(width: 420, height: 420)) {
                heroImage = frame
                break
            }
            // The sharp copy is decoded off the main thread and only swapped
            // in once nothing is moving, so the flight never pays for it.
            let side = UIScreen.main.bounds.width * UIScreen.main.scale
            for await frame in Thumbnails.shared.stream(for: photo.asset, targetSize: CGSize(width: side, height: side)) {
                let prepared = await frame.byPreparingForDisplay() ?? frame
                // Wait for the flight to end. A cancelled sleep throws at once,
                // so this must bail out rather than spin.
                while flying {
                    do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
                }
                if Task.isCancelled { return }
                heroImage = prepared
            }
        }
        .task(id: current) {
            // Keep the previous details on screen while the next load, so
            // the numbers roll from old to new instead of blinking out.
            guard let photo = currentPhoto else { shot = nil; return }
            library.resolveInfo(for: photo)
            let next = await ShotInfo.load(for: photo.asset)
            guard !Task.isCancelled else { return }
            shot = next
        }
        .accessibilityAddTraits(.isModal)
        .sensoryFeedback(.impact(weight: .medium), trigger: selects)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: deselects)
        .sensoryFeedback(.impact(weight: .light), trigger: hearts)
    }

    // MARK: Bands

    /// Close on the left, the selection ring on the right. Its own strip, so
    /// the pager underneath can never take its taps.
    private var chrome: some View {
        HStack {
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Close")

            Spacer()

            if let photo = currentPhoto {
                HeartButton(isOn: favouriteIDs.contains(photo.id)) {
                    hearts += 1
                    toggleFavourite(photo)
                }
            }
        }
        .overlay { shootPosition }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// "12 of 40": where this photo sits in the day it was shot, counted in
    /// grid order so flicking to the next photo counts up.
    @ViewBuilder
    private var shootPosition: some View {
        if let place = placeInShoot {
            Text("\(place.index) of \(place.count)")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(place.index)))
                .animation(Motion.mode, value: place.index)
                .accessibilityLabel("Photo \(place.index) of \(place.count) from this day")
        }
    }

    /// Days are unbroken runs in the newest-first list, so this only walks
    /// the current photo's day. Nothing is shown for a day of one.
    private var placeInShoot: (index: Int, count: Int)? {
        guard let current, let i = position[current], photos.indices.contains(i),
              let day = photos[i].creationDate else { return nil }
        let calendar = Calendar.current
        func sameDay(_ j: Int) -> Bool {
            photos[j].creationDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        }
        var start = i, end = i
        while start > 0, sameDay(start - 1) { start -= 1 }
        while end < photos.count - 1, sameDay(end + 1) { end += 1 }
        let count = end - start + 1
        return count > 1 ? (i - start + 1, count) : nil
    }

    /// The pager is built only once the copy has landed, so none of its
    /// page controllers or image requests compete with the flight.
    private var stage: some View {
        ZStack {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { stageFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.size) { _, _ in stageFrame = proxy.frame(in: .global) }
            }
            if !flying {
                PhotoPager(photos: photos, position: position, current: $current) { photo in
                    ViewerPage(photo: photo, state: pageState)
                }
                .allowsHitTesting(pull == 0)
                .onTapGesture(count: 2) {
                    guard !isBusy, let photo = currentPhoto else { return }
                    if selection.contains(photo.id) { deselects += 1 } else { selects += 1 }
                    toggleSelect(photo)
                    ringPop += 1
                }
            }
        }
    }

    /// Filename and what the camera recorded. Fixed height, so the stage
    /// above it and the button below it never move as details arrive.
    private var caption: some View {
        let filename = currentPhoto.flatMap { library.info[$0.id]?.filename } ?? " "
        let frameNumber = Double(filename.filter(\.isNumber)) ?? 0
        let cameraLine = [shot?.camera, shot?.lens].compactMap { $0 }.joined(separator: " · ")
        let exposure = shot?.line ?? " "
        let whereWhen = currentPhoto.map(Self.whereWhen) ?? " "

        return VStack(spacing: 5) {
            Text(filename)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .contentTransition(reduceMotion ? .opacity : .numericText(value: frameNumber))

            Text(cameraLine.isEmpty ? " " : cameraLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)

            Text(exposure)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .contentTransition(reduceMotion ? .opacity : .numericText())

            Text(whereWhen)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .multilineTextAlignment(.center)
        .frame(height: 94)
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .animation(Motion.mode, value: filename)
        .animation(Motion.mode, value: shot)
        .animation(Motion.mode, value: whereWhen)
        .accessibilityElement(children: .combine)
    }

    /// "Williamsburg, New York City · Sat 11 Oct, 14:32". The place comes
    /// from the bundled gazetteer, so this never waits on a network.
    private static func whereWhen(_ photo: RawPhoto) -> String {
        let place = photo.asset.location.flatMap { PlaceIndex.shared.place(for: $0)?.short }
        let when = photo.creationDate.map { date in
            Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
                ? date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                : date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
        }
        let line = [place, when].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? " " : line
    }

    /// One button. It sends the photo you are looking at until you start
    /// marking keepers, then it sends the keepers.
    private var footer: some View {
        VStack(spacing: 10) {
            if selection.isEmpty, let photo = currentPhoto, sentIDs.contains(photo.id) {
                Label("Already in Lightroom", systemImage: "checkmark")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            HStack(spacing: 12) {
                if let photo = currentPhoto {
                    SelectRing(isSelected: selection.contains(photo.id), pop: ringPop) {
                        if selection.contains(photo.id) { deselects += 1 } else { selects += 1 }
                        toggleSelect(photo)
                    }
                    .disabled(isBusy)
                }
                sendButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .animation(Motion.mode, value: selection.count)
    }

    private var sendButton: some View {
        Group {
            Button {
                if isOver {
                    trimSelection()
                    return
                }
                dismiss()
                if selection.isEmpty, let photo = currentPhoto {
                    sendCurrent(photo)
                } else {
                    sendSelection()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isOver ? "arrow.down.to.line" : "arrow.up.forward.app.fill")
                    Text(buttonTitle)
                        .contentTransition(.numericText(value: Double(selection.count)))
                }
                .font(.headline)
                .foregroundStyle(isOver ? .white : .black)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(isOver ? Palette.over : Palette.amber).interactive(), in: .capsule)
            .animation(Motion.mode, value: isOver)
            .sensoryFeedback(.warning, trigger: isOver) { _, now in now }
            .disabled(isBusy)
        }
    }

    private var buttonTitle: String {
        if isOver { return "Keep the first \(Handoff.selectionLimit)" }
        if selection.isEmpty {
            if let photo = currentPhoto, sentIDs.contains(photo.id) { return "Send again" }
            return "Send to Lightroom"
        }
        return "Send \(selection.count.formatted()) to Lightroom"
    }

    // MARK: Hero

    /// The travelling copy. Present only while opening or closing.
    @ViewBuilder
    private var heroLayer: some View {
        if heroVisible, let photo = currentPhoto {
            let to = fittedRect(for: photo)
            let from = tileRect(for: photo.id) ?? to.insetBy(dx: to.width * 0.04, dy: to.height * 0.04)
            FlyingPhoto(image: heroImage, from: from, to: to, progress: hero)
                .opacity(tileRect(for: photo.id) == nil ? Double(hero) : 1)
                .allowsHitTesting(false)
        }
    }

    private var heroAnimation: Animation {
        reduceMotion ? Motion.reduced : Motion.fly
    }

    /// Tile → viewer. The copy flies in; the pager is revealed under it once
    /// it lands, so the swap is invisible.
    private func open() {
        flying = true
        heroVisible = true
        hero = 0
        Task { @MainActor in
            // Let frames settle, and give the tile-size image a beat to arrive
            // so the copy that flies is the photo, never a placeholder.
            for _ in 0..<8 where heroImage == nil {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
            withAnimation(heroAnimation) { hero = 1 }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 220 : 360))
            guard !closing else { return }
            flying = false                       // pager is built now, under the copy
            try? await Task.sleep(for: .milliseconds(140))
            if !closing { heroVisible = false }  // pager has drawn; drop the copy
        }
    }

    // MARK: Dismiss

    /// Viewer → tile. The copy flies back and the viewer is removed the
    /// moment it lands. Unconditional: nothing may leave a copy on the grid.
    private func dismiss() {
        guard !closing else { return }
        closing = true
        willDismiss()
        closeTask = Task { @MainActor in
            heroVisible = true                   // copy over the pager, same frame
            try? await Task.sleep(for: .milliseconds(16))   // grid may have just scrolled
            flying = true                        // pager gone; only the copy moves
            withAnimation(heroAnimation) {
                hero = 0
                pull = 0
            }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 220 : 380))
            didDismiss()
        }
    }

    private var pullToDismiss: some UIGestureRecognizerRepresentable {
        DirectionalPan(
            axis: .downward,
            enabled: !flying,
            space: .named("viewer"),
            began: { _ in },
            moved: { value in pull = max(value.translation.height, 0) },
            ended: { value in
                let flicked = value.velocity.height > 900
                if pull > 110 || flicked {
                    dismiss()
                } else {
                    withAnimation(reduceMotion ? Motion.reduced : Motion.settle) {
                        pull = 0
                    }
                }
            }
        )
    }
}

// MARK: - Page

/// Selection as seen from inside a page.
@Observable
final class PageState {
    var selected: Set<String> = []
}

/// Just the photo, fitted inside the stage with a little air. Selected, the
/// amber line draws itself around the photo and blooms once; deselected,
/// it simply fades.
private struct ViewerPage: View {
    let photo: RawPhoto
    let state: PageState

    @State private var image: UIImage?
    @State private var shown = false            // frame is on
    @State private var dip: CGFloat = 1         // photo scale on tap
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSelected: Bool { state.selected.contains(photo.id) }

    var body: some View {
        ZStack {
            Color.clear
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay { border }
                    .scaleEffect(dip)
                    .transition(.opacity)
            }
        }
        .onChange(of: isSelected, initial: true) { _, selected in
            if reduceMotion {
                withAnimation(Motion.reduced) { shown = selected }
                return
            }
            if selected {
                dip = 0.985
                withAnimation(Motion.toy) { shown = true }
                withAnimation(Motion.settle.delay(0.06)) { dip = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.14)) { shown = false }
                dip = 1
            }
        }
        .padding(.horizontal, 12)
        .animation(Motion.fade, value: image == nil)
        .task(id: photo.id) {
            let scale = UIScreen.main.scale
            let side = UIScreen.main.bounds.width * scale
            for await frame in Thumbnails.shared.stream(for: photo.asset, targetSize: CGSize(width: side, height: side)) {
                image = frame
            }
        }
    }

    /// One frame, one settle. Scale and opacity share the toy spring, so
    /// it lands with a single small overshoot and nothing else moves.
    private var border: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Palette.amber, lineWidth: 3)
            .scaleEffect(shown ? 1 : 1.03)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
    }
}

// MARK: - Heart

/// Favourite, in Photos itself. Same glass circle as close, on the other side.
private struct HeartButton: View {
    let isOn: Bool
    let toggle: () -> Void
    @State private var pops = 0

    var body: some View {
        Button {
            pops += 1
            toggle()
        } label: {
            Image(systemName: isOn ? "heart.fill" : "heart")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .phaseAnimator([false, true], trigger: pops) { view, popped in
            view.scaleEffect(popped && isOn ? 1.15 : 1)
        } animation: { _ in Motion.toy }
        .accessibilityLabel(isOn ? "Favourite" : "Not a favourite")
        .accessibilityHint("Double tap to change. Changes it in Photos too.")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Ring

/// Keep or skip, sized for a thumb. Same language as the grid rings.
private struct SelectRing: View {
    let isSelected: Bool
    var pop: Int = 0
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                    .opacity(isSelected ? 0 : 1)
                Circle()
                    .fill(Palette.amber)
                    .opacity(isSelected ? 1 : 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(14)
            .frame(width: 56, height: 56)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .phaseAnimator([false, true], trigger: pop) { view, popped in
            view.scaleEffect(popped ? 1.12 : 1)
        } animation: { _ in Motion.state }
        .animation(Motion.state, value: isSelected)
        .accessibilityLabel(isSelected ? "Selected" : "Select")
        .accessibilityHint("Double tap the photo also toggles this.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
