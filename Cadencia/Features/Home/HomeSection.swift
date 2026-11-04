import SwiftUI

/// Home cards share an in-card heading, alignment, and minimum header height.
struct HomeSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        InfoSection(hasInformation: false) {
            content()
        } header: {
            Text(title)
                .font(.headline)
                .frame(minHeight: 44, alignment: .leading)
        } information: {
            EmptyView()
        }
    }
}
