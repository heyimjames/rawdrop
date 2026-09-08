import SwiftUI
import Photos

struct LibraryView: View {
    let library: RawLibrary

    @State private var selection = Selection()
    @State private var send = SendController()
    @State private var sent = SentRegistry()
    /// The photo open in the viewer, if any. Also the pager's position.
    @State private var viewerID: String?
    /// Photos' rule: nothing selects until you say Select.
    @State private var isSelecting = false
    @State private var showingInfo = false
    /// Flips once, when the grid first has something in it. Tiles land in
    /// sequence rather than as a block; after that they are just there.
    @State private var landed = false
    /// A deep link that arrived before the library had loaded.
    @State private var pendingLink: URL?
    @State private var tiles = TileRegistry()
    @State private var swipe = SwipeSelect()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        #if DEBUG
        let _ = HangMonitor.mark("LibraryView.body selecting=\(isSelecting) sel=\(selection.count)")
        #endif
        return ScrollViewReader { scroller in
          ZStack {
            NavigationStack {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(library.sections) { section in
                            Section {
                                ForEach(section.photos) { photo in
                                    tile(for: photo)
                                }
                            } header: {
                                DayHeader(
                                    title: section.title,
                                    count: section.photos.count,
                                    allSelected: isSelecting && isFullySelected(section),
                                    disabled: send.isBusy
                                ) {
                                    toggle(section)
                                }
                            }
                        }
                    }
                    .coordinateSpace(name: "grid")
                    .gesture(swipeGesture)
                    .padding(.bottom, 80)
                }
                .background(Color.black)
                .scrollDisabled(library.photos.isEmpty)
                .overlay {
                    if library.photos.isEmpty && !library.isLoading {
                        EmptyLibraryView(
                            isLimited: library.status == .limited,
                            inAlbum: library.album != nil
                        ) {
                            library.presentLimitedPicker()
                        }
                    }
                }
                .navigationTitle(library.album?.title ?? "RAW")
                .navigationSubtitle(subtitle)
                .toolbarTitleMenu { albumMenu }
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    SendBar(
                        selectedCount: selection.count,
                        phase: send.phase,
                        send: startSend,
                        trim: trimSelection,
                        cancel: send.cancel
                    )
                    .background(alignment: .bottom) {
                        // Photos dissolve as they pass under the bar.
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0), location: 0),
                                .init(color: .black.opacity(0.85), location: 0.45),
                                .init(color: .black, location: 0.7),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 190)
                        .offset(y: 50)            // reaches through the home indicator zone
                        .allowsHitTesting(false)
                        .opacity(selection.isEmpty && !send.isBusy ? 0 : 1)
                        .animation(Motion.fade, value: selection.isEmpty && !send.isBusy)
                    }
                }
            }

            if viewerID != nil {
                PhotoViewer(
                    photos: library.photos,
                    current: $viewerID,
                    library: library,
                    sentIDs: sent.ids,
                    selection: selection.ids,
                    isBusy: send.isBusy,
                    origin: { id in tiles.frame(for: id)?.global },
                    toggleSelect: { photo in
                        isSelecting = true
                        toggle(photo.id)
                    },
                    sendCurrent: { photo in
                        send.send([photo])
                    },
                    sendSelection: {
                        startSend()
                    },
                    trimSelection: trimSelection,
                    willDismiss: {
                        // Bring the tile on screen, unanimated, so the photo
                        // has somewhere to drop back into.
                        if let id = viewerID, tiles.frame(for: id) == nil {
                            var t = Transaction(); t.disablesAnimations = true
                            withTransaction(t) { scroller.scrollTo(id, anchor: .center) }
                        }
                    },
                    didDismiss: { viewerID = nil }
                )
                .zIndex(1)
            }
          }
        }
        .sheet(item: $send.shareBatch) { batch in
            ShareSheet(batch: batch) { completed in
                let sentIDs = send.shareFinished(completed: completed)
                if !sentIDs.isEmpty { sent.markSent(sentIDs) }
            }
            .presentationDetents([.medium, .large])
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingInfo) {
            InfoSheet()
        }
        .onChange(of: library.photos.isEmpty, initial: true) { _, empty in
            if !empty {
                landed = true
                applyDebugFlags()
                openPendingLink()
            }
        }
        .onChange(of: library.allPhotos.count, initial: true) { _, _ in refreshWidget() }
        .onChange(of: sent.ids.count) { _, _ in refreshWidget() }
        .onOpenURL { url in
            pendingLink = url
            openPendingLink()
        }
        .onChange(of: library.album) { _, _ in
            selection.removeAll()
            isSelecting = false
        }
        .onChange(of: send.phase) { _, phase in
            // The selection clears only once the whole send has landed.
            if case .sent = phase {
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    withAnimation(Motion.mode) {
                        selection.removeAll()
                        isSelecting = false
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
        .sensoryFeedback(.success, trigger: send.completedBatches)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: viewerID != nil) { _, now in now }
    }

    // MARK: Widget and deep link

    private func refreshWidget() {
        guard !library.allPhotos.isEmpty || sent.lastSend != nil else { return }
        WidgetSnapshotWriter.update(allPhotos: library.allPhotos, sentIDs: sent.ids, lastSend: sent.lastSend)
    }

    /// rawdrop://select-new → select mode with the waiting photos chosen.
    private func openPendingLink() {
        guard let url = pendingLink, !library.photos.isEmpty else { return }
        pendingLink = nil
        guard url.host == "select-new", !send.isBusy else { return }
        if library.album != nil { library.select(album: nil) }
        viewerID = nil
        withAnimation(Motion.mode) {
            isSelecting = true
            let unsent = library.photos.map(\.id).filter { !sent.ids.contains($0) }
            selection = Selection(unsent.isEmpty ? library.photos.map(\.id) : unsent)
        }
    }

    // MARK: Debug flags

    /// Simulator-only shortcuts so screens can be reached without taps:
    /// `-open-viewer`, `-select-mode`, `-show-about`.
    private func applyDebugFlags() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-open-viewer"), viewerID == nil {
            viewerID = library.photos.first?.id
        }
        if args.contains("-select-mode") {
            isSelecting = true
            let n = args.firstIndex(of: "-select-count").flatMap { Int(args[$0 + 1]) } ?? 2
            selection = Selection(library.photos.prefix(n).map(\.id))
        }
        if args.contains("-trim-after") {
            Task { try? await Task.sleep(for: .seconds(4)); trimSelection() }
        }
        if args.contains("-show-about") {
            showingInfo = true
        }
        if args.contains("-select-after") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                let t0 = Date()
                print("[perf] select tap at \(t0.timeIntervalSince1970)")
                enterSelectMode()
                await Task.yield()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1))
                    print("[perf] main thread free again after \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                }
            }
        }
        #endif
    }

    // MARK: Tile

    private func tile(for photo: RawPhoto) -> some View {
        RawTile(
            photo: photo,
            info: library.info[photo.id],
            isSelecting: isSelecting,
            isSelected: selection.contains(photo.id),
            isSent: sent.ids.contains(photo.id),
            isExtracting: send.currentPhotoID == photo.id,
            isLifted: viewerID == photo.id,
            tap: { tap(photo) },
            resolveInfo: { library.resolveInfo(for: photo) }
        )
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        tiles.register(photo.id) {
                            TileFrame(grid: proxy.frame(in: .named("grid")), global: proxy.frame(in: .global))
                        }
                    }
                    .onDisappear { tiles.unregister(photo.id) }
            }
        }
        .id(photo.id)
        .opacity(landed ? 1 : 0)
        .animation(landingAnimation(for: photo), value: landed)
    }

    private func tap(_ photo: RawPhoto) {
        guard !send.isBusy, viewerID == nil else { return }
        if isSelecting {
            toggle(photo.id)
        } else {
            viewerID = photo.id
        }
    }

    private func landingAnimation(for photo: RawPhoto) -> Animation {
        if reduceMotion { return Motion.reduced }
        let index = min(library.position[photo.id] ?? 0, 14)     // only the first screenful staggers
        return Motion.fade.delay(Double(index) * 0.028)
    }

    /// Sideways drag across tiles selects (or deselects) everything it crosses.
    private var swipeGesture: some UIGestureRecognizerRepresentable {
        DirectionalPan(
            axis: .horizontal,
            enabled: isSelecting && !send.isBusy && viewerID == nil,
            space: .named("grid"),
            began: { value in
                swipe.begin(at: value.location, tiles: tiles, selection: &selection)
            },
            moved: { value in
                swipe.move(to: value.location, tiles: tiles, selection: &selection)
            },
            ended: { _ in swipe.end() }
        )
    }


    // MARK: Albums

    /// Tap the title. Same gesture Files and Photos use for changing scope.
    @ViewBuilder
    private var albumMenu: some View {
        Button {
            library.select(album: nil)
        } label: {
            Label("All RAW photos", systemImage: library.album == nil ? "checkmark" : "photo.on.rectangle")
        }
        if !library.albums.isEmpty {
            Divider()
            ForEach(library.albums) { album in
                Button {
                    library.select(album: album)
                } label: {
                    Label(album.title, systemImage: library.album == album ? "checkmark" : "rectangle.stack")
                }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(bulkTitle) {
                    withAnimation(Motion.state) { selection = bulkSelection() }
                }
                .disabled(send.isBusy)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") { exitSelectMode() }
                    .disabled(send.isBusy)
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button("About RawDrop", systemImage: "info.circle") { showingInfo = true }
            }
            if library.status == .limited {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Choose photos") { library.presentLimitedPicker() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !library.photos.isEmpty {
                    Button("Select") { enterSelectMode() }
                        .disabled(send.isBusy)
                }
            }
        }
    }

    private func enterSelectMode() {
        #if DEBUG
        HangMonitor.mark("enterSelectMode")
        #endif
        withAnimation(Motion.mode) { isSelecting = true }
    }

    private func exitSelectMode() {
        withAnimation(Motion.mode) {
            isSelecting = false
            selection.removeAll()
        }
    }

    /// Once some photos have gone to Lightroom, the obvious bulk action is
    /// "the ones that haven't", so that is what the button becomes. The
    /// title is decided from counts alone; the walk over the library only
    /// happens when the button is tapped.
    private var bulkTitle: String {
        if !library.photos.isEmpty && selection.count == library.photos.count { return "Deselect all" }
        return sent.ids.isEmpty ? "Select all" : "Select new"
    }

    private func bulkSelection() -> Selection {
        if bulkTitle == "Deselect all" { return Selection() }
        if sent.ids.isEmpty { return Selection(library.photos.map(\.id)) }
        let unsent = library.photos.map(\.id).filter { !sent.ids.contains($0) }
        return unsent.isEmpty ? Selection(library.photos.map(\.id)) : Selection(unsent)
    }

    /// Over the limit: keep the first 50 picked, let the rest go.
    private func trimSelection() {
        withAnimation(Motion.state) { selection.trim(to: Handoff.selectionLimit) }
    }

    // MARK: Selection helpers

    private func isFullySelected(_ section: DaySection) -> Bool {
        section.photos.allSatisfy { selection.contains($0.id) }
    }

    private var subtitle: String {
        let n = library.photos.count
        if n == 0 { return library.isLoading ? "Looking for RAW photos" : "" }
        if !isSelecting { return n == 1 ? "1 photo" : "\(n.formatted()) photos" }
        if selection.isEmpty { return "Select photos" }
        let over = selection.count - Handoff.selectionLimit
        if over > 0 { return "\(selection.count.formatted()) selected · \(over.formatted()) over the limit" }
        return "\(selection.count.formatted()) of \(n.formatted()) selected"
    }

    private func toggle(_ id: String) {
        guard !send.isBusy else { return }
        selection.toggle(id)
    }

    private func toggle(_ section: DaySection) {
        guard !send.isBusy else { return }
        let ids = section.photos.map(\.id)
        withAnimation(Motion.state) {
            isSelecting = true
            if isFullySelected(section) {
                selection.subtract(ids)
            } else {
                selection.formUnion(ids)
            }
        }
    }

    private func startSend() {
        // In the order they were picked, so batch 1 is what they picked first.
        let byID = Dictionary(uniqueKeysWithValues: library.photos.filter { selection.contains($0.id) }.map { ($0.id, $0) })
        send.send(selection.order.compactMap { byID[$0] })
    }
}

// MARK: - Day header

/// A label, not a bar. It scrolls with its photos.
struct DayHeader: View {
    let title: String
    let count: Int
    let allSelected: Bool
    let disabled: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text(count.formatted())
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            Button(allSelected ? "Deselect" : "Select", action: toggle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .contentTransition(.interpolate)
                .disabled(disabled)
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .animation(Motion.mode, value: allSelected)
    }
}

// MARK: - Empty

struct EmptyLibraryView: View {
    let isLimited: Bool
    let inAlbum: Bool
    let choosePhotos: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            Text(title)
                .font(.title3.weight(.semibold))

            Text(body_)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if isLimited {
                Button("Choose photos", action: choosePhotos)
                    .buttonStyle(.glass)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 60)
    }

    private var title: String {
        if inAlbum { return "No RAW in this album" }
        return isLimited ? "No RAW in the photos you chose" : "No RAW photos yet"
    }

    private var body_: String {
        if inAlbum { return "Tap the title to look somewhere else." }
        return isLimited
            ? "Pick the camera imports you want RawDrop to see."
            : "Import from your camera into Photos. Anything with a RAW inside shows up here on its own."
    }
}
