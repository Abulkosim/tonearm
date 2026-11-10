import SwiftUI

/// Compact centered screen for states where there is nothing to control.
struct StatusMessage<Actions: View>: View {
    var symbol: String
    var title: String
    var detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundColor(PlayerTheme.textSecondary)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 16)
            Text(detail)
                .font(.system(size: 13))
                .foregroundColor(PlayerTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            VStack(spacing: 8) {
                actions
            }
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}
