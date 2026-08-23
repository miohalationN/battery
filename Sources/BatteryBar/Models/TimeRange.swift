import Foundation

/// 图表时间范围（供 PowerTab 共用）
enum TimeRange: String, CaseIterable {
    case hour1 = "1小时"
    case day6 = "6小时"
    case day24 = "24小时"

    var hours: Double {
        switch self {
        case .hour1: return 1
        case .day6: return 6
        case .day24: return 24
        }
    }

    /// X 轴刻度步进
    var axisStride: (component: Calendar.Component, count: Int) {
        switch self {
        case .hour1: return (.minute, 15)
        case .day6: return (.hour, 1)
        case .day24: return (.hour, 3)
        }
    }

    /// 返回完整墙上时间范围，避免 Swift Charts 按少量现有样本自动缩放并铺满全宽。
    func domain(endingAt end: Date) -> ClosedRange<Date> {
        end.addingTimeInterval(-hours * 3600)...end
    }
}
