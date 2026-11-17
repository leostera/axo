import SwiftUI

/// Paging belongs to the sidebar, never the selected conversation or its composer.
struct WorkbenchSidebarPager<Chats: View, Hosts: View>: View {
  @Binding var showingHosts: Bool
  let chats: Chats
  let hosts: Hosts

  var body: some View {
    TabView(selection: $showingHosts) {
      // Hosts are left of the default conversations page; detail never participates in paging.
      hosts.tag(true)
        .accessibilityHidden(!showingHosts)
      chats.tag(false)
        .accessibilityHidden(showingHosts)
    }
    .tabViewStyle(.page(indexDisplayMode: .never))
    // The pager's children cannot paint beyond its UIKit safe-area bounds. Own the
    // column backdrop here too, including the status and bottom system areas.
    .background(ChatColors.background.ignoresSafeArea())
    .containerBackground(ChatColors.background, for: .navigationSplitView)
  }
}
