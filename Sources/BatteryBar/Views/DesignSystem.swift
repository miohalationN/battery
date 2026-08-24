import SwiftUI

/// 电池档案（BatteryArchive）的视觉令牌与复用组件。
///
/// 设计语言围绕三件事：石墨色背景承载长期使用、薄荷绿表达电池状态、
/// 暖黄色表达实时能量。卡片只承担分组，不用大面积灰底争夺图表注意力。
enum BBDesign {
    static let cornerRadius: CGFloat = 18
    static let cornerRadiusSmall: CGFloat = 11
    static let cardPadding: CGFloat = 18
    static let pagePadding: CGFloat = 22
    static let sectionSpacing: CGFloat = 14
    static let itemSpacing: CGFloat = 10
    static let sidebarWidth: CGFloat = 184
}

extension Color {
    static let bbMint = Color(red: 0.20, green: 0.80, blue: 0.58)
    static let bbTeal = Color(red: 0.13, green: 0.68, blue: 0.72)
    static let bbBlue = Color(red: 0.25, green: 0.55, blue: 0.96)
    static let bbAmber = Color(red: 0.98, green: 0.66, blue: 0.18)
    static let bbPurple = Color(red: 0.61, green: 0.45, blue: 0.94)
}

/// 整个主窗口的环境底色。彩色光晕非常克制，避免浅色模式下变成一整片灰。
struct AppBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [Color.bbBlue.opacity(0.055), Color.clear, Color.bbMint.opacity(0.045)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.bbMint.opacity(0.07), Color.clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// 页面级内容卡片：使用动态实体色而不是实时背景模糊。
    /// Liquid Glass 属于导航/控制层；滚动数据内容使用实体表面能显著减少离屏合成。
    func glassCard(accent: Color = .clear) -> some View {
        self
            .padding(BBDesign.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: BBDesign.cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: BBDesign.cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [accent.opacity(0.095), Color.clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: BBDesign.cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.primary.opacity(0.105)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
    }

    /// 卡片内部的次级信息块。
    func insetTile(cornerRadius: CGFloat = BBDesign.cornerRadiusSmall) -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                Color.primary.opacity(0.042),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.055), lineWidth: 1)
            }
    }

    /// 图表绘图区的统一底板。
    func chartSurface() -> some View {
        self
            .padding(.horizontal, 2)
            .padding(.top, 6)
            .background(
                LinearGradient(
                    colors: [Color.primary.opacity(0.018), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }

    /// macOS 26+ 采用系统 Liquid Glass 主操作样式；旧系统使用原生 prominent 样式。
    @ViewBuilder
    func adaptiveProminentButton(tint: Color) -> some View {
        if #available(macOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .tint(tint)
        } else {
            self
                .buttonStyle(.borderedProminent)
                .tint(tint)
        }
    }
}

/// 页面首屏标题。把当前页面意图固定下来，替代旧 TabView 只显示一个小标签的弱层级。
struct PageHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    var badge: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: systemImage, tint: tint, size: 38, symbolSize: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let badge {
                LiveBadge(text: badge, tint: tint)
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }
}

/// 区块标题：彩色图标只承担定位，正文保持中性。
struct SectionHeader: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            IconBadge(systemImage: systemImage, tint: tint, size: 28, symbolSize: 12)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
    }
}

/// 图标徽章：纯渐变底色，无发光阴影（滚动内容保持轻量合成）。
struct IconBadge: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 28
    var symbolSize: CGFloat = 12

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: symbolSize, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [tint.opacity(0.82), tint],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            )
    }
}

/// 数字统计块。强调色只出现在图标、描边与轻微渐变，不用整块实色。
struct StatTile: View {
    let icon: String
    let tint: Color
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Spacer(minLength: 4)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: BBDesign.cornerRadiusSmall, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.105), Color.primary.opacity(0.035)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: BBDesign.cornerRadiusSmall, style: .continuous)
                .strokeBorder(tint.opacity(0.13), lineWidth: 1)
        }
    }
}

struct LiveBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.09), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.16), lineWidth: 1))
    }
}

struct ChartLegendItem: View {
    let label: String
    let color: Color
    var value: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(color)
                .frame(width: 14, height: 3)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
            }
        }
    }
}

struct EmptyChartState: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 104)
    }
}
