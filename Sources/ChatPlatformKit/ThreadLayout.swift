#if canImport(UIKit)
import UIKit

/// A vertical stack of rows with exact, precomputed heights.
///
/// Not a compositional layout: that needs estimated sizes for rows of varying
/// height, and rows above the viewport keep their estimates until they're
/// shown, so prepending older messages moves what the user is looking at.
/// With exact heights every frame is known up front: prepends can be anchored
/// to the pixel, and scrolling never re-measures. Lookups are binary searches,
/// so a 5,000-message thread costs the same per frame as a short one.
@MainActor
final class ThreadLayout: UICollectionViewLayout {
    /// Height of the item at an index path for a given width. Must be cheap
    /// (cached); called for every item when the data or width changes.
    var heightForItem: ((IndexPath, CGFloat) -> CGFloat)?
    var topPadding: CGFloat = 8
    var bottomPadding: CGFloat = 8

    private var frames: [CGRect] = []
    private var contentHeight: CGFloat = 0
    private var builtForSize: CGSize = .zero
    private var needsRebuild = true

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let size = collectionView.bounds.size
        if needsRebuild || size != builtForSize { rebuild(collectionView) }
    }

    private func rebuild(_ collectionView: UICollectionView) {
        needsRebuild = false
        builtForSize = collectionView.bounds.size
        let width = collectionView.bounds.width
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        frames.removeAll(keepingCapacity: true)
        frames.reserveCapacity(count)
        var y = topPadding
        for item in 0..<count {
            let height = heightForItem?(IndexPath(item: item, section: 0), width) ?? 44
            frames.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height
        }
        y += bottomPadding
        // Short threads sit at the bottom, next to the input bar, like any chat.
        let insets = collectionView.adjustedContentInset
        let visible = collectionView.bounds.height - insets.top - insets.bottom
        let slack = max(0, visible - y)
        if slack > 0 {
            for index in frames.indices { frames[index].origin.y += slack }
        }
        contentHeight = y + slack
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !frames.isEmpty else { return [] }
        // First frame whose bottom reaches the rect.
        var low = 0, high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].maxY < rect.minY { low = mid + 1 } else { high = mid }
        }
        var result: [UICollectionViewLayoutAttributes] = []
        var index = low
        while index < frames.count, frames[index].minY <= rect.maxY {
            result.append(attributes(at: index))
            index += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, frames.indices.contains(indexPath.item) else { return nil }
        return attributes(at: indexPath.item)
    }

    private func attributes(at index: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = frames[index]
        return attributes
    }

    /// The frame of an item in the current layout, if laid out.
    func frame(at index: Int) -> CGRect? {
        frames.indices.contains(index) ? frames[index] : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != builtForSize
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        if context.invalidateEverything || context.invalidateDataSourceCounts
            || context.invalidatedItemIndexPaths != nil
        {
            needsRebuild = true
        }
        super.invalidateLayout(with: context)
    }

    /// Call when row heights changed without a data source change
    /// (Dynamic Type, a reconfigured row).
    func invalidateHeights() {
        needsRebuild = true
        invalidateLayout()
    }

    // New rows fade in from slightly below; removed rows fade out.
    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath)
        -> UICollectionViewLayoutAttributes?
    {
        guard let attributes = layoutAttributesForItem(at: itemIndexPath)?.copy()
            as? UICollectionViewLayoutAttributes
        else { return nil }
        attributes.alpha = 0
        attributes.transform = CGAffineTransform(translationX: 0, y: 8)
        return attributes
    }
}
#endif
