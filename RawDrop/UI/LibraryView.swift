import SwiftUI
import Photos

struct LibraryView: View {
    let library: RawLibrary

    @State private var selection = Selection()
    @State private var send = SendController()
    @State private var sent = SentRegistry()
    @State private var search = SearchModel()
    @State private var indexer = Indexer()
    /// The photo open in the viewer, if any. Also the pager's position.
    @State private var viewerID: String?
    /// What the viewer pages through, fixed when it opens. Results that
    /// shift underneath (a search refining, a heart removed in Favourites)
    /// must not pull the photo you are looking at out from under you.
    @State private var viewerPhotos: [RawPhoto] = []
    @State private var viewerPosition: [String: Int] = [:]
    /// Photos' rule: nothing selects until you say Select.
    @State private var isSelecting = false
    @State private var showingInfo = false
    /// When the grid first drew, for the stand-in cells' light.
    @State private var loadingSince = Date.now
    /// The wait has gone on long enough to say so.
    @State private var waitedLong = false
    @State private var isScrolling = false
    /// A deep link that arrived before the library had loaded.
    @State private var pendingLink: URL?
    @State private var tiles = TileRegistry()
    @State private var swipe = SwipeSelect()
    @FocusState private var searchFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    // MARK: What is on screen

    /// The search results when there is a search, otherwise the whole scope.
    private var shownPhotos: [RawPhoto] { search.results?.photos ?? library.photos }
    private var shownSections: [DaySection] { search.results?.sections ?? library.sections }
    private var shownPosition: [String: Int] { search.results?.position ?? library.position }

    /// The send bar and the search pill share the bottom edge. The bar wins
    /// whenever there is something to send or a send under way.
    private var dockShowsSearch: Bool { selection.isEmpty && send.phase == .idle }

    var body: some View {
        #if DEBUG
        let _ = HangMonitor.mark("LibraryView.body selecting=\(isSelecting) sel=\(selection.count)")
        #endif
        return ScrollViewReader { scroller in
          ZStack {
            NavigationStack {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        // Until the first photos are in, the grid's own
                        // shape stands in for them. See LoadingGrid.
                        if showsLoadingCells {
                            Section {
                                ForEach(0..<(LoadingCells.rows * columns.count), id: \.self) { i in
                                    LoadingCell(row: i / columns.count + 1, since: loadingSince)
                                }
                            } header: {
                                LoadingHeader(since: loadingSince)
                            }
                        }
                        ForEach(shownSections) { section in
                            Section {
                                ForEach(section.photos) { photo in
                                    tile(for: photo)
                                }
                            } header: {
                                DayHeader(
                                    title: section.title,
                                    place: section.place,
                                    count: section.photos.count,
                                    allSelected: isSelecting && isFullySelected(section),
                                    disabled: send.isBusy || !library.hasLoaded
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
                .scrollDismissesKeyboard(.immediately)
                .onScrollPhaseChange { _, phase in
                    isScrolling = phase.isScrolling
                    updateIndexerPause()
                }
                .id(gridIdentity)                         // a new scope or search is a new grid
                .transition(.opacity)
                .animation(Motion.fade, value: gridIdentity)
                .scrollDisabled(shownPhotos.isEmpty)
                .overlay { emptyState }
                .overlay {
                    // Focused with nothing typed: the grid steps back so the
                    // suggestions read. A tap anywhere puts it back.
                    Color.black
                        .opacity(searchFocused && !search.isActive ? 0.55 : 0)
                        .allowsHitTesting(searchFocused && !search.isActive)
                        .onTapGesture { searchFocused = false }
                        .animation(Motion.fade, value: searchFocused && !search.isActive)
                }
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .toolbarTitleMenu { scopeMenu }
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    dock
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
                            .frame(height: searchFocused ? 420 : 190)
                            .offset(y: 50)            // reaches through the home indicator zone
                            .allowsHitTesting(false)
                            .opacity(dockShowsSearch && !searchFocused ? 0 : 1)
                            .animation(Motion.fade, value: dockShowsSearch && !searchFocused)
                        }
                }
            }

            if viewerID != nil {
                PhotoViewer(
                    photos: viewerPhotos,
                    position: viewerPosition,
                    current: $viewerID,
                    library: library,
                    sentIDs: sent.ids,
                    selection: selection.ids,
                    favouriteIDs: library.favouriteIDs,
                    isBusy: send.isBusy,
                    origin: { id in tiles.frame(for: id)?.global },
                    toggleSelect: { photo in
                        isSelecting = true
                        toggle(photo.id)
                    },
                    toggleFavourite: { photo in
                        library.setFavourite(photo, !library.isFavourite(photo))
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
                        if let id = viewerID, tiles.frame(for: id) == nil, shownPosition[id] != nil {
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
        .onChange(of: library.hasLoaded, initial: true) { _, loaded in
            if loaded {
                applyDebugFlags()
                openPendingLink()
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(LoadingTiming.reassure))
            waitedLong = true
        }
        .onChange(of: library.generation, initial: true) { _, _ in
            search.setSource(library.photos, places: library.placeByDay)
            indexer.sync(with: library.allPhotos)
            refreshWidget()
        }
        .onChange(of: library.favouriteIDs, initial: true) { _, _ in
            search.setFlags(favourites: library.favouriteIDs, sent: sent.ids)
        }
        .onChange(of: sent.ids.count) { _, _ in
            search.setFlags(favourites: library.favouriteIDs, sent: sent.ids)
            refreshWidget()
        }
        .onChange(of: scenePhase, initial: true) { _, _ in updateIndexerPause() }
        .onChange(of: send.isBusy) { _, _ in updateIndexerPause() }
        .onChange(of: viewerID) { _, id in
            if id != nil { searchFocused = false }
            updateIndexerPause()
        }
        .onChange(of: searchFocused) { _, focused in
            if focused { search.prepare() }
        }
        .task {
            indexer.onNewTags = { [search] in search.tagsChanged() }
        }
        .onOpenURL { url in
            pendingLink = url
            openPendingLink()
        }
        .onChange(of: library.scope) { _, _ in
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

    // MARK: Dock

    @ViewBuilder
    private var dock: some View {
        ZStack(alignment: .bottom) {
            if dockShowsSearch && viewerID == nil {
                SearchDock(
                    search: search,
                    indexer: indexer,
                    placeholder: searchPlaceholder,
                    suggestions: searchFocused ? suggestions : [],
                    focused: $searchFocused
                )
                // Nothing to search until the library has been read.
                .disabled(!library.hasLoaded)
                .opacity(library.hasLoaded ? 1 : 0.45)
                .animation(Motion.fade, value: library.hasLoaded)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
            }
            SendBar(
                selectedCount: selection.count,
                phase: send.phase,
                send: startSend,
                trim: trimSelection,
                cancel: send.cancel
            )
        }
        .animation(Motion.mode, value: dockShowsSearch)
    }

    private var suggestions: [SearchModel.Suggestion] {
        let scoped = Set(library.photos.lazy.map(\.id))
        let favourites = library.photos.filter { library.favouriteIDs.contains($0.id) }
        let unsent = library.photos.count - sent.ids.lazy.filter { scoped.contains($0) }.count
        return search.suggestions(
            favouriteCount: library.scope == .favourites ? 0 : favourites.count,
            latestFavourite: favourites.first,
            unsentCount: unsent
        )
    }

    private var searchPlaceholder: String {
        switch library.scope {
        case .all: "Search RAW photos"
        case .favourites: "Search favourites"
        case .album(let album): "Search \(album.title)"
        }
    }

    /// Changes when a new set of results lands, not on every keystroke, so
    /// the grid fades once per answer rather than once per letter.
    private var gridIdentity: String {
        library.shownScope.id + "|" + (search.results?.query ?? "")
    }

    private var showsLoadingCells: Bool {
        !library.hasLoaded && library.photos.isEmpty && !search.isActive
    }

    /// The indexer reads photos through the same Photos pipeline the grid
    /// and the viewer use. Whenever someone is looking, it waits its turn.
    private func updateIndexerPause() {
        indexer.setPaused(scenePhase != .active || send.isBusy || viewerID != nil || isScrolling)
    }

    // MARK: Empty

    @ViewBuilder
    private var emptyState: some View {
        if search.isActive, let results = search.results, results.photos.isEmpty {
            NoResultsView(query: search.query.trimmingCharacters(in: .whitespaces),
                          stillReading: indexer.remaining,
                          interpreting: search.isInterpreting)
                .transition(.opacity)
        } else if library.photos.isEmpty && library.hasLoaded {
            EmptyLibraryView(
                isLimited: library.status == .limited,
                scope: library.scope
            ) {
                library.presentLimitedPicker()
            }
        }
    }

    // MARK: Widget and deep link

    private func refreshWidget() {
        guard !library.allPhotos.isEmpty || sent.lastSend != nil else { return }
        WidgetSnapshotWriter.update(allPhotos: library.allPhotos, sentIDs: sent.ids, lastSend: sent.lastSend)
    }

    /// rawdrop://select-new → select mode with the waiting photos chosen.
    private func openPendingLink() {
        guard let url = pendingLink, library.hasLoaded, !library.photos.isEmpty else { return }
        pendingLink = nil
        guard url.host == "select-new", !send.isBusy else { return }
        search.clear()
        searchFocused = false
        if library.scope != .all { library.select(.all) }
        viewerID = nil
        withAnimation(Motion.mode) {
            isSelecting = true
            let unsent = library.photos.map(\.id).filter { !sent.ids.contains($0) }
            selection = Selection(unsent.isEmpty ? library.photos.map(\.id) : unsent)
        }
    }

    // MARK: Debug flags

    /// Simulator-only shortcuts so screens can be reached without taps:
    /// `-open-viewer`, `-select-mode`, `-show-about`, `-search <query>`,
    /// `-focus-search`, `-scope favourites`.
    private func applyDebugFlags() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-open-viewer"), viewerID == nil, let first = library.photos.first {
            open(first)
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
        if let i = args.firstIndex(of: "-search"), i + 1 < args.count {
            search.query = args[i + 1]
        }
        if args.contains("-focus-search") {
            Task { try? await Task.sleep(for: .seconds(1)); searchFocused = true }
        }
        if let i = args.firstIndex(of: "-scope"), i + 1 < args.count, args[i + 1] == "favourites" {
            library.select(.favourites)
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
            showsFormat: library.mixesFormats,
            isSelecting: isSelecting,
            isSelected: selection.contains(photo.id),
            isSent: sent.ids.contains(photo.id),
            isFavourite: library.favouriteIDs.contains(photo.id),
            isExtracting: send.currentPhotoID == photo.id,
            isLifted: viewerID == photo.id,
            index: shownPosition[photo.id] ?? 0,
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
    }

    private func tap(_ photo: RawPhoto) {
        guard !send.isBusy, viewerID == nil else { return }
        if isSelecting {
            toggle(photo.id)
        } else {
            open(photo)
        }
    }

    private func open(_ photo: RawPhoto) {
        viewerPhotos = shownPhotos
        viewerPosition = shownPosition
        viewerID = photo.id
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

    // MARK: Scope menu

    /// Tap the title. Same gesture Files and Photos use for changing scope.
    /// Everything and Favourites always lead, then the albums. Albums are
    /// listed before their RAWs are counted; any found to hold none drop out.
    @ViewBuilder
    private var scopeMenu: some View {
        Button {
            library.select(.all)
        } label: {
            Label("All RAW photos", systemImage: library.scope == .all ? "checkmark" : "photo.on.rectangle")
            Text(library.allPhotos.count.formatted())
        }
        Button {
            library.select(.favourites)
        } label: {
            Label("Favourites", systemImage: library.scope == .favourites ? "checkmark" : "heart")
            Text(library.favouriteIDs.isEmpty ? "None yet" : library.favouriteIDs.count.formatted())
        }
        if !library.albums.isEmpty {
            Section("Albums") {
                ForEach(library.albums) { album in
                    Button {
                        library.select(.album(album))
                    } label: {
                        Label(album.title, systemImage: library.album?.id == album.id ? "checkmark" : "rectangle.stack")
                        if let count = album.rawCount {
                            Text(count.formatted())
                        }
                    }
                }
            }
        }
    }

    private var title: String {
        switch library.scope {
        case .all: "RAW"
        case .favourites: "Favourites"
        case .album(let album): album.title
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
                if !shownPhotos.isEmpty {
                    Button("Select") { enterSelectMode() }
                        .disabled(send.isBusy || !library.hasLoaded)
                }
            }
        }
    }

    private func enterSelectMode() {
        #if DEBUG
        HangMonitor.mark("enterSelectMode")
        #endif
        searchFocused = false
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
    /// happens when the button is tapped. With a search on, "all" means
    /// all the results.
    private var bulkTitle: String {
        if !shownPhotos.isEmpty && selection.count == shownPhotos.count { return "Deselect all" }
        return sent.ids.isEmpty ? "Select all" : "Select new"
    }

    private func bulkSelection() -> Selection {
        if bulkTitle == "Deselect all" { return Selection() }
        if sent.ids.isEmpty { return Selection(shownPhotos.map(\.id)) }
        let unsent = shownPhotos.map(\.id).filter { !sent.ids.contains($0) }
        return unsent.isEmpty ? Selection(shownPhotos.map(\.id)) : Selection(unsent)
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
        let n = shownPhotos.count
        if isSelecting && !selection.isEmpty {
            let over = selection.count - Handoff.selectionLimit
            if over > 0 { return "\(selection.count.formatted()) selected · \(over.formatted()) over the limit" }
            return "\(selection.count.formatted()) of \(n.formatted()) selected"
        }
        if search.isActive, let results = search.results {
            let found = results.photos.count == 1 ? "1 match" : "\(results.photos.count.formatted()) matches"
            return results.interpreted ? "\(found) · \(results.summary.joined(separator: ", "))" : found
        }
        if !library.hasLoaded {
            // The newest screenful can be up before the rest is read. The
            // count Photos already knows is the honest one to show.
            if n > 0, let total = library.expectedCount {
                return total == 1 ? "1 photo" : "\(total.formatted()) photos"
            }
            if n == 0 {
                return waitedLong ? "Still looking. Big libraries take a moment." : "Looking for RAW photos"
            }
        }
        if n == 0 { return "" }
        if isSelecting { return "Select photos" }
        return n == 1 ? "1 photo" : "\(n.formatted()) photos"
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
        // Picks can span several searches, so look in the whole library.
        let byID = Dictionary(library.allPhotos.filter { selection.contains($0.id) }.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        send.send(selection.order.compactMap { byID[$0] })
    }
}

// MARK: - Day header

/// A label, not a bar. It scrolls with its photos.
struct DayHeader: View {
    let title: String
    let place: String?
    let count: Int
    let allSelected: Bool
    let disabled: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .layoutPriority(1)
            if let place {
                Text(place)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(count.formatted())
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.tertiary)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Button(allSelected ? "Deselect" : "Select", action: toggle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.amber)
                .contentTransition(.interpolate)
                .disabled(disabled)
                .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .animation(Motion.mode, value: allSelected)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Empty

struct EmptyLibraryView: View {
    let isLimited: Bool
    let scope: Scope
    let choosePhotos: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: scope == .favourites ? "heart" : "camera.aperture")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            Text(title)
                .font(.title3.weight(.semibold))

            Text(body_)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if isLimited && scope == .all {
                Button("Choose photos", action: choosePhotos)
                    .buttonStyle(.glass)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 60)
    }

    private var title: String {
        switch scope {
        case .favourites: return "No favourite RAWs yet"
        case .album: return "No RAW in this album"
        case .all: return isLimited ? "No RAW in the photos you chose" : "No RAW photos yet"
        }
    }

    private var body_: String {
        switch scope {
        case .favourites: return "Tap the heart on a photo here or in Photos and it shows up in this list."
        case .album: return "Tap the title to look somewhere else."
        case .all:
            return isLimited
                ? "Pick the camera imports you want RawDrop to see."
                : "Import from your camera into Photos. Anything with a RAW inside shows up here on its own."
        }
    }
}

/// A search that found nothing. Says why when it can: the photos may not
/// all have been read yet.
private struct NoResultsView: View {
    let query: String
    let stillReading: Int
    let interpreting: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: interpreting ? "sparkle" : "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, isActive: interpreting)
                .contentTransition(.symbolEffect(.replace))
                .padding(.bottom, 6)
            Text(interpreting ? "Thinking about \u{201C}\(query)\u{201D}" : "Nothing for \u{201C}\(query)\u{201D}")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 140)
        .animation(Motion.mode, value: interpreting)
    }

    private var detail: String {
        if stillReading > 0 {
            return "Still reading \(stillReading.formatted()) photos. More may turn up as it goes."
        }
        return "Try a place, a camera, a month, or something in the frame."
    }
}
