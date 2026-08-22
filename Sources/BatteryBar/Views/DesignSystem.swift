import SwiftUI

/// 统一设计令牌与复用组件（macOS 26+ Liquid Glass 风格）
///
/// 原则：
/// - 材质分层：页面级卡片用 regularMaterial + 细描边；卡片内信息块用 primary 低透明度填充，
///   层级压在卡片之下，不再每块都上材质 + 阴影
/// - 连续圆角（.continuous）取代普通圆角
/// - 描边代替投影：1pt primary 6% 描边提供玻璃边缘感
/// - 数字排版：大号 rounded + monospacedDigit；说明文字 caption2 + tertiary
/// - 色彩克制：每区块一个强调色，只用于图标底与图形，正文保持中性
enum BBDesign {
    static let cornerRadius: CGFloat = 16
    static let cornerRadiusSmall: CGFloat = 10
    static let cardPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 14
    static let itemSpacing: CGFloat = 10
}

extension View {
    /// 页面级玻璃卡片：材质 + 细描边 + 连续圆角，不加投影
    func glassCard() -> some View {
        self
            .padding(BBDesign.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: BBDesign.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BBDesign.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }

    /// 卡片内信息小块：低透明度填充，层级低于卡片材质
    func insetTile(cornerRadius: CGFloat = BBDesign.cornerRadiusSmall) -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// 区块标题：SF Symbol 彩色渐变圆角底 + 标题（系统设置风格）
struct SectionHeader: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
    }
}

/// 数字统计块：图标 + 大数字 + 单位 + 标签（卡片内嵌块的标准形）
struct StatTile: View {
    let icon: String
    let tint: Color
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: BBDesign.cornerRadiusSmall, style: .continuous))
    }
}
