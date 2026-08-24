import Foundation

/// 电池包功率来源选择（纯逻辑，可单测）。
///
/// 规则（冻结）：
/// 1. 按既定优先级取「第一个存在且合法的直接值」；
/// 2. 合法值包含原始 0——0 必须立即胜出并返回 available=true/value=0，
///    禁止继续被低优先级节点或电压×电流乘积覆盖；
/// 3. 缺失（nil）或越界坏值（归一化失败）才允许继续；
/// 4. 全部直接来源无合法值时，才允许使用乘积>0 的电压×电流回退（estimated）。
enum BatteryPowerSelection {
    struct Result: Equatable {
        var value: Double
        var available: Bool
        var source: TelemetrySource
        var isEstimated: Bool

        static let unavailable = Result(value: 0, available: false, source: .unavailable, isEstimated: false)
    }

    /// 从直接候选（按优先级排序）解析电池包功率。
    /// - Parameters:
    ///   - directCandidates: 直接来源候选，数组顺序即优先级（高→低）。
    ///   - voltage: 电压（mV），用于乘积回退。
    ///   - amperage: 瞬时电流（mA），用于乘积回退。
    static func resolve(
        directCandidates: [(raw: Double?, source: TelemetrySource)],
        voltage: Double,
        amperage: Double
    ) -> Result {
        for candidate in directCandidates {
            guard let raw = candidate.raw else { continue }
            if raw == 0 {
                // 合法原始 0：立即胜出，禁止被更低优先级节点或 V×I 覆盖
                return Result(value: 0, available: true, source: candidate.source, isEstimated: false)
            }
            let normalized = BatteryReader.normalizedBatteryPower(raw)
            if normalized > 0 {
                return Result(value: normalized, available: true, source: candidate.source, isEstimated: false)
            }
            // 越界坏值（归一化失败）→ 继续
        }
        let product = abs(voltage * amperage) / 1_000_000
        if product > 0 {
            return Result(value: product, available: true, source: .voltageCurrentDerived, isEstimated: true)
        }
        return .unavailable
    }
}
