import SwiftUI

/// Optional context stays in its block and takes space only when the athlete asks for it.
struct BlockInfo<Label: View, Information: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isExpanded = false

    var hasInformation = true
    var stacksHeaderAtAccessibilitySizes = false
    @ViewBuilder var label: () -> Label
    @ViewBuilder var information: () -> Information

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerLayout {
                label()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hasInformation {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "info.circle.fill" : "info.circle")
                            .font(.body)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isExpanded ? Text("Hide information") : Text("Show information"))
                    .accessibilityIdentifier("block-info-toggle")
                }
            }
            if hasInformation && isExpanded {
                information()
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
    }

    private var headerLayout: AnyLayout {
        if stacksHeaderAtAccessibilitySizes && dynamicTypeSize.isAccessibilitySize {
            AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        } else {
            AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        }
    }
}

/// A list section with its heading and optional explanation together inside the card.
struct InfoSection<Content: View, Header: View, Information: View>: View {
    var hasInformation = true
    var stacksHeaderAtAccessibilitySizes = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var header: () -> Header
    @ViewBuilder var information: () -> Information

    var body: some View {
        Section {
            BlockInfo(hasInformation: hasInformation, stacksHeaderAtAccessibilitySizes: stacksHeaderAtAccessibilitySizes) {
                header()
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .labelStyle(.titleAndIcon)
                    .textCase(nil)
            } information: {
                information()
            }
            .listRowSeparator(.hidden, edges: .bottom)
            content()
        }
    }
}
