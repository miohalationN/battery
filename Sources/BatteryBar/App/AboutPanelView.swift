import SwiftUI

/// 自定义关于面板。
///
/// 品牌使用规则：首行出现完整品牌「BA · BatteryArchive」，
/// 下方补充「电池档案 · 电池健康与功耗记录」；版本与 build 由 AppBrand 集中提供。
/// 纯静态展示，无动画、无 blur，不新增任何持续资源占用。
struct AboutPanelView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(AppBrand.fullBrand)
                .font(.system(size: 19, weight: .bold, design: .rounded))
            Text(AppBrand.localizedFullBrand)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("版本 \(AppBrand.version) (\(AppBrand.build))")
                .font(.system(size: 11, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .padding(28)
        .frame(width: 380)
    }
}