import AxoPhoneModel
import AxoProtocol
import SwiftUI
import UIKit

/// The conversation's list: a `UICollectionView` whose rows are drawn by SwiftUI (RFD0039).
///
/// It does two things, and only it does them:
/// - **It lists the feed's rows,** in the feed's order: each time the feed's rows change, its
///   snapshot becomes their ids. A row's content changing is not the list's business; the row's
///   own view redraws, and its cell sizes itself again.
/// - **It decides where the conversation is scrolled to,** in its layout pass, once UIKit has
///   sized the rows and before anything is drawn. While following, the end; otherwise the row the
///   reader was looking at stays where it was, however rows above or below grow or arrive.
struct ConversationList: UIViewRepresentable {
  /// What the list shows and does, for the chat on screen; given anew on each redraw.
  struct Content {
    let feed: ConversationFeed
    let chat: Chat?
    let phone: PhoneWorkbench
    let workbench: HostWorkbenchModel?
    let session: SessionID?
    let canSend: Bool
    let actions: ConversationRowActions
    let pull: ConversationPull
    let loadOlder: () -> Void
    let refresh: () -> Void

    /// Whether the top and bottom would be given the same: what they do not read themselves.
    @MainActor func sameInputs(as other: Content) -> Bool {
      feed === other.feed && chat === other.chat && workbench === other.workbench && session == other.session
        && canSend == other.canSend
    }
  }

  let content: Content
  let scroll: ConversationScroll
  /// What the rows read from SwiftUI's environment, which cells hosted by UIKit do not inherit.
  let sidewaysScrolling: SidewaysScrolling
  let tint: Color
  let assetLoader: AssetLoader?

  func makeCoordinator() -> Coordinator { Coordinator(scroll: scroll) }

  func makeUIView(context: Context) -> ConversationCollectionView {
    let view = context.coordinator.makeView()
    update(view, context: context)
    return view
  }

  func updateUIView(_ view: ConversationCollectionView, context: Context) {
    let _ = RenderCount.note("Transcript")
    update(view, context: context)
  }

  private func update(_ view: ConversationCollectionView, context: Context) {
    let coordinator = context.coordinator
    coordinator.environment = .init(sidewaysScrolling: sidewaysScrolling, tint: tint, assetLoader: assetLoader)
    coordinator.show(content)
  }

  static func dismantleUIView(_ view: ConversationCollectionView, coordinator: Coordinator) {
    coordinator.stop()
  }

  /// The list's three parts: what is above the rows (older history, or the empty chat), the rows,
  /// and what is below them (what is asked, and what Pi is doing).
  enum Section: Hashable { case top, rows, bottom }

  enum Entry: Hashable {
    case top
    case row(String)
    case bottom
  }

  struct Environment {
    var sidewaysScrolling: SidewaysScrolling
    var tint: Color
    var assetLoader: AssetLoader?
  }

  @MainActor
  final class Coordinator: NSObject, UICollectionViewDelegate {
    let scroll: ConversationScroll
    var environment: Environment?
    private var content: Content?
    private weak var view: ConversationCollectionView?
    private var dataSource: UICollectionViewDiffableDataSource<Section, Entry>?
    /// The feed the snapshot lists, and whether a change to its rows is waiting to be applied.
    private weak var listed: ConversationFeed?
    private var changeWaiting = false

    init(scroll: ConversationScroll) { self.scroll = scroll }

    func makeView() -> ConversationCollectionView {
      let view = ConversationCollectionView(frame: .zero, collectionViewLayout: ConversationList.layout())
      view.backgroundColor = .clear
      view.alwaysBounceVertical = true
      view.keyboardDismissMode = .interactive
      view.contentInsetAdjustmentBehavior = .never
      view.delegate = self
      view.scroll = scroll
      view.entryAt = { [weak self] indexPath in self?.dataSource?.itemIdentifier(for: indexPath) }
      view.indexPathOf = { [weak self] entry in self?.dataSource?.indexPath(for: entry) }
      if #available(iOS 26, *) {
        view.topEdgeEffect.style = .soft
        view.bottomEdgeEffect.style = .soft
      }
      let row = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
        guard let self, let content = self.content, let item = content.feed.item(id) else { return }
        Self.clip(cell)
        cell.contentConfiguration = UIHostingConfiguration {
          self.dressed(ConversationItemView(item: item, feed: content.feed, actions: content.actions))
        }
        .margins(.all, 0)
      }
      let top = UICollectionView.CellRegistration<UICollectionViewCell, Void> { [weak self] cell, _, _ in
        guard let self, let content = self.content else { return }
        cell.contentConfiguration = UIHostingConfiguration {
          self.dressed(ConversationTop(content: content))
        }
        .margins(.all, 0)
      }
      let bottom = UICollectionView.CellRegistration<UICollectionViewCell, Void> { [weak self] cell, _, _ in
        guard let self, let content = self.content else { return }
        cell.contentConfiguration = UIHostingConfiguration {
          self.dressed(ConversationBottom(content: content))
        }
        .margins(.all, 0)
      }
      dataSource = UICollectionViewDiffableDataSource(collectionView: view) { view, indexPath, entry in
        switch entry {
        case .top: view.dequeueConfiguredReusableCell(using: top, for: indexPath, item: ())
        case .row(let id): view.dequeueConfiguredReusableCell(using: row, for: indexPath, item: id)
        case .bottom: view.dequeueConfiguredReusableCell(using: bottom, for: indexPath, item: ())
        }
      }
      self.view = view
      return view
    }

    /// A row grows (a reply's words coming out) a moment before its cell does: SwiftUI draws its
    /// new lines at once, and the list makes room in its next layout pass. Clipped, what does not
    /// fit yet is not drawn over the rows below in the meantime.
    private static func clip(_ cell: UICollectionViewCell) {
      cell.clipsToBounds = true
      cell.contentView.clipsToBounds = true
    }

    /// Gives a hosted row what SwiftUI's environment would have.
    private func dressed(_ row: some View) -> some View {
      // Lined up with the column's leading edge: a row that asks for more than the column (a
      // half-written code block) runs off to the right, rather than sliding left of the column.
      LeadingColumn { row }
        .environment(environment?.sidewaysScrolling ?? SidewaysScrolling())
        .tint(environment?.tint)
        .environment(\.assetLoader, environment?.assetLoader)
    }

    /// The chat on screen, or what the list shows of it, changed.
    func show(_ content: Content) {
      let feed = content.feed
      let shown = self.content
      self.content = content
      guard let view, let dataSource else { return }
      if listed !== feed {
        // Another chat: its rows from the start, at its end.
        listed?.changed = nil
        listed = feed
        feed.changed = { [weak self, weak feed] grew in
          guard let self, let feed else { return }
          self.rowsChanged(feed, grew: grew)
        }
        scroll.follow = ScrollFollow()
        apply(feed, to: dataSource, reset: true)
        view.pinToEnd()
      } else if let before = shown, !before.sameInputs(as: content) {
        // The top and bottom read what they show themselves; given new inputs, they are made again.
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([.top, .bottom])
        dataSource.apply(snapshot, animatingDifferences: false)
      }
    }

    /// Lists the feed's rows.
    private func apply(
      _ feed: ConversationFeed, to dataSource: UICollectionViewDiffableDataSource<Section, Entry>, reset: Bool = false
    ) {
      let rows = feed.items.map { Entry.row($0.id) }
      let current = dataSource.snapshot()
      let listed = current.sectionIdentifiers == [.top, .rows, .bottom] ? current.itemIdentifiers(inSection: .rows) : []
      if !reset, current.numberOfSections > 0, listed == rows { return }
      var snapshot = NSDiffableDataSourceSnapshot<Section, Entry>()
      snapshot.appendSections([.top, .rows, .bottom])
      snapshot.appendItems([.top], toSection: .top)
      snapshot.appendItems(rows, toSection: .rows)
      snapshot.appendItems([.bottom], toSection: .bottom)
      // With no rows the top shows the empty chat; with some, it does not.
      if listed.isEmpty || rows.isEmpty || reset {
        snapshot.reconfigureItems([.top])
      }
      if reset {
        dataSource.applySnapshotUsingReloadData(snapshot)
      } else {
        dataSource.apply(snapshot, animatingDifferences: false)
      }
    }

    /// The feed's rows changed: listed, and the ones that changed sized, now, before the frame
    /// they changed in is drawn.
    private func rowsChanged(_ feed: ConversationFeed, grew: Set<String>) {
      guard feed === listed, let dataSource, let view else { return }
      apply(feed, to: dataSource)
      if let held = feed.held { view.hold(.row(held)) }
      let changed = grew.compactMap { dataSource.indexPath(for: .row($0)) }
      view.size(Set(changed).intersection(view.indexPathsForVisibleItems))
    }

    func stop() {
      listed?.changed = nil
      listed = nil
    }

    // MARK: Scrolling

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      scroll.pull.touching = true
      _ = scroll.follow.scrollingChanged(to: .byReader, atEnd: (scrollView as? ConversationCollectionView)?.isAtEnd ?? true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      scroll.pull.touching = false
      if let content { scroll.pull.release(refresh: content.refresh) }
      if !decelerate { cameToRest(scrollView) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { cameToRest(scrollView) }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
      guard let view = scrollView as? ConversationCollectionView else { return }
      view.animatingToEnd = false
      _ = scroll.follow.scrollingChanged(to: .idle, atEnd: view.isAtEnd)
      // The end may have moved while it went there.
      view.setNeedsLayout()
    }

    /// Where the reader left the conversation decides whether it follows.
    private func cameToRest(_ scrollView: UIScrollView) {
      guard let view = scrollView as? ConversationCollectionView else { return }
      _ = scroll.follow.scrollingChanged(to: .idle, atEnd: view.isAtEnd)
      view.setNeedsLayout()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      guard let content else { return }
      let top = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
      // Pull-to-refresh, played by Axo: how far the content is past its top.
      let pull = content.pull
      pull.state.armTravel = content.feed.items.isEmpty ? PullToRefresh.longPull : PullToRefresh.shortPull
      pull.state.pulled(to: max(0, -top), height: scrollView.bounds.height, touching: scrollView.isTracking)
      // Older history, once the reader scrolls up to within a screen of the top; never by itself.
      if scrollView.isDragging || scrollView.isDecelerating, top < scrollView.bounds.height,
        case .loaded(_, true) = content.chat?.history
      {
        content.loadOlder()
      }
    }
  }

  fileprivate static func layout() -> UICollectionViewCompositionalLayout {
    UICollectionViewCompositionalLayout { index, _ in
      let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(120))
      let item = NSCollectionLayoutItem(layoutSize: size)
      let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
      let section = NSCollectionLayoutSection(group: group)
      switch index {
      case 0:
        // Less the point the top takes when it has nothing to show (`LeadingColumn`).
        section.contentInsets = .init(top: 23, leading: 20, bottom: 0, trailing: 20)
      default:
        // No room between rows: each row leaves its own under it (`ConversationItemView.gap`), so
        // tools used one after another can join into one block. What is under the last row is the
        // bottom's to leave (`ConversationBottom`).
        section.contentInsets = .init(top: 0, leading: 20, bottom: 0, trailing: 20)
      }
      return section
    }
  }
}

/// Whether the conversation follows its end, shared by the list (which scrolls) and the bar below
/// it (which offers the way back). Observed for the bar's sake alone.
@MainActor
@Observable
final class ConversationScroll {
  /// The decisions; not observed, as most leave what the bar shows as it was.
  @ObservationIgnored var follow = ScrollFollow() {
    didSet {
      if isFollowing != follow.isFollowing { isFollowing = follow.isFollowing }
      if hasNew != follow.hasNew { hasNew = follow.hasNew }
    }
  }
  /// What the bar shows: the way back to the end, and whether something new is there.
  private(set) var isFollowing = true
  private(set) var hasNew = false
  @ObservationIgnored let pull: ConversationPull
  /// How far the bars cover the list, above and below: given to the list as they change, without
  /// redrawing the screen.
  @ObservationIgnored var insets = (top: CGFloat(0), bottom: CGFloat(0)) {
    didSet { if insets != oldValue { setInsets(insets.top, insets.bottom) } }
  }
  @ObservationIgnored var setInsets: (CGFloat, CGFloat) -> Void = { _, _ in }
  /// Scrolls to the end, animated: set by the list.
  @ObservationIgnored var goToEnd: () -> Void = {}
  /// Lays the list out again, which follows the end if it is following: set by the list.
  @ObservationIgnored var keepAtEnd: () -> Void = {}

  init(pull: ConversationPull) { self.pull = pull }

  func move(_ move: ScrollFollow.Move) {
    switch move {
    case .stay: break
    case .keepAtEnd: keepAtEnd()
    case .goToEnd: goToEnd()
    }
  }
}

/// The list's view, which owns the scroll position: after each layout pass it puts the end in
/// view while following, and otherwise keeps the reader's row where it was (RFD0039).
final class ConversationCollectionView: UICollectionView {
  weak var scroll: ConversationScroll? {
    didSet {
      scroll?.goToEnd = { [weak self] in self?.goToEnd() }
      scroll?.keepAtEnd = { [weak self] in self?.setNeedsLayout() }
      scroll?.setInsets = { [weak self] top, bottom in self?.setInsets(top: top, bottom: bottom) }
      rowResized = { [weak scroll] atEnd in scroll?.follow.rowResized(atEnd: atEnd) }
      if let scroll { setInsets(top: scroll.insets.top, bottom: scroll.insets.bottom) }
    }
  }
  var entryAt: (IndexPath) -> ConversationList.Entry? = { _ in nil }
  var indexPathOf: (ConversationList.Entry) -> IndexPath? = { _ in nil }
  /// An animated move to the end is under way: nothing else moves the list meanwhile.
  var animatingToEnd = false
  /// The reader's row, by its place in the content, as of the last layout pass.
  private var anchor: (entry: ConversationList.Entry, minY: CGFloat)?
  /// A row the reader opened or folded, by where it was on screen and how tall it was: layouts
  /// keep it there until its new size is laid out (SwiftUI draws it anew a pass or two later), or
  /// a moment passes.
  private var holding: (entry: ConversationList.Entry, onScreen: CGFloat, height: CGFloat, until: Date)?
  /// Told, after a held row was laid out, whether the end is in view.
  private var rowResized: (Bool) -> Void = { _ in }

  /// Keeps `entry` where it is on screen through the next layout, whatever it is following: the
  /// reader opened or folded it, and it opens downwards from under their finger.
  func hold(_ entry: ConversationList.Entry) {
    guard let indexPath = indexPathOf(entry), let frame = layoutAttributesForItem(at: indexPath)?.frame else { return }
    holding = (entry, frame.minY - contentOffset.y, frame.height, Date().addingTimeInterval(0.5))
  }

  private var scale: CGFloat { max(1, traitCollection.displayScale) }

  /// Where the offset is when the end of the content is just above the bottom inset.
  var end: CGFloat {
    let end = max(-contentInset.top, contentSize.height + contentInset.bottom - bounds.height)
    return (end * scale).rounded() / scale
  }

  /// Whether the end is in view, near enough.
  var isAtEnd: Bool { contentOffset.y >= end - 60 }

  /// Whether the reader, or an animated move, has the scroll view: then nothing else moves it.
  private var held: Bool { isTracking || isDragging || isDecelerating || animatingToEnd }

  func setInsets(top: CGFloat, bottom: CGFloat) {
    let insets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
    guard contentInset != insets else { return }
    contentInset = insets
    verticalScrollIndicatorInsets = insets
    setNeedsLayout()
  }

  /// Touches where the bars cover the list are the bars': the list runs under them only to be
  /// seen through them.
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let y = point.y - bounds.minY
    guard y >= contentInset.top, y <= bounds.height - contentInset.bottom else { return nil }
    return super.hitTest(point, with: event)
  }

  override func layoutSubviews() {
    let before = contentOffset.y
    super.layoutSubviews()
    if let holding, !isTracking, !isDragging {
      guard let indexPath = indexPathOf(holding.entry), let frame = layoutAttributesForItem(at: indexPath)?.frame else {
        self.holding = nil
        return
      }
      // Where it was on screen, as far as the content reaches: a row folded at the end leaves
      // the end where it can be.
      contentOffset.y = max(-contentInset.top, min(end, frame.minY - holding.onScreen))
      let resized = abs(frame.height - holding.height) > 0.5
      if resized || Date() > holding.until {
        self.holding = nil
        rowResized(isAtEnd)
      } else {
        // Not laid out at its new size yet: look again once it is.
        DispatchQueue.main.async { [weak self] in self?.setNeedsLayout() }
      }
      anchor = readerRow()
      return
    }
    holding = nil
    let following = scroll?.follow.isFollowing ?? true
    if following, !held {
      pinToEnd()
    } else if let anchor, let indexPath = indexPathOf(anchor.entry),
      let frame = layoutAttributesForItem(at: indexPath)?.frame
    {
      // What moved the reader's row, less what the layout already moved the offset by.
      let shift = frame.minY - anchor.minY - (contentOffset.y - before)
      if abs(shift) > 0.5, !animatingToEnd { contentOffset.y += shift }
    }
    anchor = readerRow()
  }

  /// Sizes rows on screen to what they show now, and lays the list out: a row that grew moves the
  /// rows below it, and the end, in the same frame that draws it. Left to UIKit, a cell is sized
  /// in a later pass, and in between its new lines are drawn over the rows below. Rows off screen
  /// are sized as they come on.
  func size(_ rows: Set<IndexPath>) {
    let cells = rows.compactMap { cellForItem(at: $0) }
    guard !cells.isEmpty else { return }
    // UIKit's own way for a cell to ask for its size again; only the pass it waits for is now.
    for cell in cells { cell.invalidateIntrinsicContentSize() }
    UIView.performWithoutAnimation { layoutIfNeeded() }
  }

  /// To the end, at once.
  func pinToEnd() {
    guard bounds.height > 0 else { return }
    let end = end
    if abs(contentOffset.y - end) > 0.01 { contentOffset.y = end }
  }

  private func goToEnd() {
    guard bounds.height > 0 else { return }
    layoutIfNeeded()
    if abs(contentOffset.y - end) < 1 {
      pinToEnd()
      return
    }
    animatingToEnd = true
    setContentOffset(CGPoint(x: 0, y: end), animated: true)
  }

  /// The first row whose top is in view, or the first in view at all.
  private func readerRow() -> (entry: ConversationList.Entry, minY: CGFloat)? {
    let top = contentOffset.y + contentInset.top
    let visible = indexPathsForVisibleItems.sorted()
    let attributes = visible.compactMap { layoutAttributesForItem(at: $0) }
    guard let chosen = attributes.first(where: { $0.frame.minY >= top }) ?? attributes.first,
      let entry = entryAt(chosen.indexPath)
    else { return nil }
    return (entry, chosen.frame.minY)
  }
}

/// Above the rows: older history to read, or what an empty chat says.
private struct ConversationTop: View {
  let content: ConversationList.Content

  var body: some View {
    VStack(spacing: 0) {
      OlderHistoryRow(chat: content.chat, load: content.loadOlder)
      if content.feed.items.isEmpty {
        ConversationEmptyState(
          chat: content.chat, isNew: content.session == nil, canSend: content.canSend, pull: content.pull)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, hasContent ? 30 : 0)
  }

  private var hasContent: Bool {
    if content.feed.items.isEmpty { return true }
    switch content.chat?.history {
    case .loaded(_, true), .loadingOlder: return true
    default: return false
    }
  }
}

/// Below the rows: what the extensions and Pi ask, and what Pi is doing.
private struct ConversationBottom: View {
  let content: ConversationList.Content

  var body: some View {
    if let id = content.session {
      let cards = !content.phone.questions(in: id).isEmpty
      let footer = content.feed.question != nil || content.feed.working
      VStack(alignment: .leading, spacing: 30) {
        ElicitationCards(phone: content.phone, session: id, canAnswer: content.workbench?.status == .online)
        ConversationFooter(
          feed: content.feed, chat: content.chat, workbench: content.workbench, session: id, canSend: content.canSend)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      // The last row leaves a gap under itself; with no rows, this leaves it.
      .padding(.top, (cards || footer) && content.feed.items.isEmpty ? ConversationItemView.gap : 0)
      // The room under it all: a gap, and the point the bottom takes when it has nothing to show.
      .padding(.bottom, cards || footer || content.feed.items.isEmpty ? ConversationItemView.gap + 1 : 0)
    } else {
      Color.clear.frame(height: content.feed.items.isEmpty ? ConversationItemView.gap + 1 : 0)
    }
  }
}

/// Exactly as wide as it is offered, with its content at the leading edge, however wide that asks
/// to be: a cell centres what is wider than itself. And never empty: a cell with no height is not
/// shown, and one not shown never hears that its content grew, so a reply that starts with none of
/// its words out would stay hidden for good.
private struct LeadingColumn: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let size = subviews.first?.sizeThatFits(proposal) ?? .zero
    return CGSize(width: proposal.width ?? size.width, height: max(1, size.height))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
  }
}
