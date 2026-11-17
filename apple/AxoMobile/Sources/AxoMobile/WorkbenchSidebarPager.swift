import SwiftUI

/// Paging belongs to the sidebar, never the selected conversation or its composer.
struct WorkbenchSidebarPager<Chats: View, Hosts: View>: View {
  @Binding var showingHosts: Bool
  let chats: Chats
  let hosts: Hosts

  var body: some View {
    TabView(selection: $showingHosts) {
      chats.tag(false)
        .accessibilityHidden(showingHosts)
      hosts.tag(true)
        .accessibilityHidden(!showingHosts)
    }
    .tabViewStyle(.page(indexDisplayMode: .never))
  }
}
