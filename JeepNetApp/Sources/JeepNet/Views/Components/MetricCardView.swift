import JeepNetCore
import SwiftUI

public struct MetricCardView: View {
    public let title: String
    public let value: String
    public let iconName: String
    public let iconColor: Color

    public init(title: String, value: String, iconName: String, iconColor: Color = .accentColor) {
        self.title = title
        self.value = value
        self.iconName = iconName
        self.iconColor = iconColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 14))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
