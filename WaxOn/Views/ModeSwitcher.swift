import SwiftUI

struct ModeSwitcher: View {
    @Environment(AppState.self) var appState

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppMode.allCases, id: \.self) { mode in
                let active = appState.mode == mode
                Button {
                    appState.mode = mode
                } label: {
                    Text(mode.rawValue)
                        .font(.subheadline)
                        .fontWeight(active ? .semibold : .regular)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            active
                                ? AnyShapeStyle(Color.accentColor)
                                : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(active ? Color.white : .secondary)
            }
        }
        .padding(3)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
    }
}
