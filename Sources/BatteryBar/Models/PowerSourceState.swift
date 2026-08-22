import Foundation

/// 电源状态三态。`isCharging` 只表达电池包是否充入；
/// 是否接电由 `externalConnected` 独立表达。
/// 满电保持、优化充电暂停、80% 充电上限都是 onPowerNotCharging，
/// 不得当作离电，也不得显示续航预估。
enum PowerSourceState: Equatable {
    /// 接电且电池包充入中
    case charging
    /// 接电但未充电（满电保持 / 优化充电暂停 / 80% 上限 / 已满静置）
    case onPowerNotCharging
    /// 明确离电
    case onBattery

    init(externalConnected: Bool, isCharging: Bool) {
        if !externalConnected {
            self = .onBattery
        } else if isCharging {
            self = .charging
        } else {
            self = .onPowerNotCharging
        }
    }
}
