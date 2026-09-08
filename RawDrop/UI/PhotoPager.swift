import SwiftUI
import UIKit

/// Horizontal paging over the whole grid, one photo per page. Backed by
/// UIPageViewController because it only ever builds the page you're on and
/// its two neighbours, and it never lands between pages.
struct PhotoPager<Page: View>: UIViewControllerRepresentable {
    let photos: [RawPhoto]
    let position: [String: Int]
    @Binding var current: String?
    let page: (RawPhoto) -> Page

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 20]
        )
        controller.view.backgroundColor = .clear
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        if let id = current, let photo = photo(for: id) {
            controller.setViewControllers([context.coordinator.host(photo)], direction: .forward, animated: false)
        }
        context.coordinator.observe(controller)
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        // Only move when something other than the user's own swipe changed the id.
        guard let id = current,
              (controller.viewControllers?.first as? PageHost)?.photoID != id,
              let photo = photo(for: id) else { return }
        let shown = (controller.viewControllers?.first as? PageHost)?.photoID
        let forward = (position[shown ?? ""] ?? 0) <= (position[id] ?? 0)
        controller.setViewControllers([context.coordinator.host(photo)], direction: forward ? .forward : .reverse, animated: true)
    }

    private func photo(for id: String) -> RawPhoto? {
        guard let index = position[id], photos.indices.contains(index) else { return nil }
        return photos[index]
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PhotoPager
        private var offsetObservation: NSKeyValueObservation?

        init(_ parent: PhotoPager) { self.parent = parent }

        /// The page controller keeps a private scroll view with the pages as
        /// its subviews. Watching its offset lets each page be shaped by how
        /// far it is from centre, so photos leave like cards, not slides.
        func observe(_ controller: UIPageViewController) {
            guard let scrollView = controller.view.subviews.compactMap({ $0 as? UIScrollView }).first else { return }
            offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { view, _ in
                Carousel.shape(view)
            }
        }

        func host(_ photo: RawPhoto) -> PageHost {
            let host = PageHost(rootView: AnyView(parent.page(photo)))
            host.photoID = photo.id
            host.view.backgroundColor = .clear
            return host
        }

        private func neighbour(of controller: UIViewController, offset: Int) -> UIViewController? {
            guard let id = (controller as? PageHost)?.photoID,
                  let index = parent.position[id] else { return nil }
            let next = index + offset
            guard parent.photos.indices.contains(next) else { return nil }
            return host(parent.photos[next])
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            neighbour(of: vc, offset: -1)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            neighbour(of: vc, offset: 1)
        }

        func pageViewController(_ pvc: UIPageViewController, willTransitionTo pending: [UIViewController]) {
            Carousel.haptic.prepare()
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let id = (pvc.viewControllers?.first as? PageHost)?.photoID else { return }
            Carousel.haptic.impactOccurred()
            parent.current = id
        }
    }

    final class PageHost: UIHostingController<AnyView> {
        var photoID: String = ""
    }
}

/// The card feel. Every value that shapes a page as it crosses the screen.
enum Carousel {
    static let tilt: CGFloat = 10          // degrees about Y at a full page away
    static let minScale: CGFloat = 0.92    // size at a full page away
    static let minAlpha: CGFloat = 0.75    // opacity at a full page away
    static let perspective: CGFloat = 900  // camera distance for the tilt

    static let haptic = UIImpactFeedbackGenerator(style: .soft)

    /// Shapes each page by its distance from the visible centre: 0 is flat
    /// and full size, ±1 is a page away. Identity when nothing is moving.
    static func shape(_ scrollView: UIScrollView) {
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let centre = scrollView.contentOffset.x + width / 2

        for page in scrollView.subviews where page.bounds.width > 0 {
            let distance = max(-1, min(1, (page.center.x - centre) / width))
            guard !reduceMotion else {
                page.layer.transform = CATransform3DIdentity
                page.alpha = 1
                continue
            }
            let scale = 1 - (1 - minScale) * abs(distance)
            var t = CATransform3DIdentity
            t.m34 = -1 / perspective
            t = CATransform3DScale(t, scale, scale, 1)
            t = CATransform3DRotate(t, -distance * tilt * .pi / 180, 0, 1, 0)
            page.layer.transform = t
            page.alpha = 1 - (1 - minAlpha) * abs(distance)
        }
    }
}
