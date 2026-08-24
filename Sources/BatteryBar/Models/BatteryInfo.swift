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
    let batteryPower: Double    // 电池包当前充入/放出功率绝对值（瓦特；available=false 时为兼容哨兵 0，不得进入质量模型或积分）
    /// 本轮电池包功率是否真实可用（含可信的有效 0W）。false = 没有读到功率。
    let batteryPowerAvailable: Bool
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

/// 电池健康口径（冻结）：UI 首选 macOS system_profiler 报告的「最大容量」；
/// FullChargeCapacity÷DesignCapacity 仅作回退并标注「容量比估算」。
/// percent==0 表示不可用——不默认 100，不用 StateOfCharge 冒充。
struct BatteryHealthMetric: Equatable {
    var percent: Double = 0
    /// true = 系统报告（system_profiler 最大容量）；false = 容量比估算
    var sourceIsSystem: Bool = false
    var readAt: Date?

    /// 展示来源标注；nil = 不可用
    var sourceLabel: String? {
        guard percent > 0 else { return nil }
        return sourceIsSystem ? "系统最大容量" : "容量比估算"
    }

    var isEstimated: Bool { !sourceIsSystem }

    /// 健康口径选择（纯函数，可注入反例）：
    /// - 系统值存在 → 永远优先（source=system，如 98%）；
    /// - 系统值缺失但容量可算 → 容量比估算（96.3% 这类，标 estimated）；
    /// - 全部缺失 → 不可用（percent=0），不默认 100。
    static func resolved(
        systemReading: SystemHealthReading?,
        maxCapacityMah: Int,
        designCapacityMah: Int
    ) -> BatteryHealthMetric {
        if let system = systemReading {
            return BatteryHealthMetric(percent: system.percent, sourceIsSystem: true, readAt: system.readAt)
        }
        guard maxCapacityMah > 0, designCapacityMah > 0 else {
            return BatteryHealthMetric()
        }
        return BatteryHealthMetric(
            percent: Double(maxCapacityMah) / Double(designCapacityMah) * 100,
            sourceIsSystem: false,
            readAt: Date()
        )
    }

    /// 系统健康刷新的纯 TTL 决策：未取过→刷新；TTL 内→不刷新；到期→刷新；
    /// 时钟回拨按需要刷新处理。
    static func shouldRefresh(lastFetchAt: Date?, now: Date, ttl: TimeInterval) -> Bool {
        guard let last = lastFetchAt else { return true }
        let elapsed = now.timeIntervalSince(last)
        return !(elapsed >= 0 && elapsed < ttl)
    }

    /// system_profiler SPPowerDataType 健康度解析（纯函数，fixture 可测）。
    /// 只接受 0 < value <= 100 的百分比；解析失败返回 nil，不得默认 100。
    static func systemProfilerHealthPercent(json: [String: Any]) -> Double? {
        guard let powerArray = json["SPPowerDataType"] as? [[String: Any]],
              let power = powerArray.first(where: { $0["sppower_battery_health_info"] != nil }),
              let healthInfo = power["sppower_battery_health_info"] as? [String: Any],
              let healthStr = healthInfo["sppower_battery_health_maximum_capacity"] as? String
        else { return nil }
        guard let percent = Double(healthStr.replacingOccurrences(of: "%", with: "")),
              percent.isFinite, percent > 0, percent <= 100
        else { return nil }
        return percent
    }
}

/// system_profiler 健康读取结果：percent 来自 macOS 报告的「Maximum Capacity」
/// （如 98%），是 UI 健康度的首选口径。
struct SystemHealthReading: Equatable {
    let percent: Double
    let readAt: Date
}
