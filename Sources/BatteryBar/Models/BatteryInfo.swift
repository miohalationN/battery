import Foundation

/// 电池静态信息
/// Equatable：PowerSampler 用它门控 @Published 写入（值未变不触发 objectWillChange）
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
    let systemPower: Double     // 系统总功耗（瓦特）
    let deviceName: String      // IORegistry DeviceName
    let chemistry: String       // 电池化学成分（AppleSmartBattery 均为 Li-ion）
    let adapterWatts: Double    // 电源适配器额定功率 (W)，0 表示未连接或未知
    let adapterProtocol: String // 充电协议: "USB-PD"/"USB-C"/"MagSafe"/"未知"/"未连接"

    /// 健康百分比
    var healthPercent: Double {
        guard designCapacity > 0 else { return 0 }
        return Double(maxCapacity) / Double(designCapacity) * 100
    }

    /// 实时功率（瓦特）
    var wattage: Double {
        abs(voltage * instantAmperage) / 1_000_000
    }
}
