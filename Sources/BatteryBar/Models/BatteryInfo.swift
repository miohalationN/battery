import Foundation

/// 电池实时与静态信息
/// Equatable：PowerSampler 用它门控 Observation 写入（元数据未变不触发视图失效）
struct BatteryInfo: Equatable {
    let designCapacity: Int     // mAh
    let maxCapacity: Int        // mAh（实际满充容量）
    let cycleCount: Int
    let serialNumber: String
    let manufacturer: String
    let voltage: Double         // mV
    let instantAmperage: Double // mA
    let temperature: Double     // 摄氏度
    let isCharging: Bool
    let externalConnected: Bool
    let systemPower: Double     // 当前系统负载（瓦特）
    let batteryPower: Double    // 电池包当前充入/放出功率绝对值（瓦特）
    let adapterInputPower: Double // 适配器输入功率（瓦特，遥测不可用时为 0）
    let systemPowerAvailable: Bool
    let systemPowerIsEstimated: Bool
    let deviceName: String      // IORegistry DeviceName
    let chemistry: String       // 电池化学成分（AppleSmartBattery 均为 Li-ion）
    let adapterWatts: Double    // 电源适配器额定功率 (W)，0 表示未连接或未知
    let adapterProtocol: String // 充电协议: "USB-PD"/"USB-C"/"MagSafe"/"未知"/"未连接"

    /// 健康百分比
    var healthPercent: Double {
        guard designCapacity > 0 else { return 0 }
        return Double(maxCapacity) / Double(designCapacity) * 100
    }

    /// 电池包实时充入/放出功率（瓦特）。
    var wattage: Double {
        batteryPower
    }
}
