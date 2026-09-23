import Foundation

/// 趋势图数据点：来自 v5 分钟聚合。
/// `breakBefore` 标记与上一点之间存在缺口（分钟缺失或覆盖率未达标），
/// 渲染时在此断开连线，绝不跨缺口插值。
/// 定义在 Calc 层：ChartDownsampler 抽稀与视图绘制共用，纯数据无视图依赖。
struct TrendPoint: Equatable {
    let time: Date
    let value: Double
    /// tooltip 附加量（如该窗口的温度最大值）
    let maximum: Double?
    /// 该点所属窗口的覆盖率（tooltip 展示）
    let coverage: Double?
    let breakBefore: Bool

    init(time: Date, value: Double, maximum: Double? = nil, coverage: Double? = nil, breakBefore: Bool = false) {
        self.time = time
        self.value = value
        self.maximum = maximum
        self.coverage = coverage
        self.breakBefore = breakBefore
    }
}

/// 为 Swift Charts 压缩长时间序列。按时间桶保留总功耗的局部最小值与最大值，
/// 相比简单 stride 不会把短时峰值直接跳过，同时把 Chart marks 控制在固定上限。
enum ChartDownsampler {
    static func powerSnapshots(
        _ snapshots: [BatterySnapshot],
        maxPoints: Int = 240
    ) -> [BatterySnapshot] {
        guard maxPoints > 0 else { return [] }
        guard snapshots.count > maxPoints else { return snapshots }
        if maxPoints == 1 { return snapshots.first.map { [$0] } ?? [] }
        if maxPoints == 2 {
            guard let first = snapshots.first, let last = snapshots.last else { return snapshots }
            return [first, last]
        }

        let interiorCount = snapshots.count - 2
        let bucketCount = max(1, (maxPoints - 2) / 2)
        var selectedIndices: [Int] = [0]
        selectedIndices.reserveCapacity(maxPoints)

        for bucket in 0..<bucketCount {
            let lower = 1 + bucket * interiorCount / bucketCount
            let upper = 1 + (bucket + 1) * interiorCount / bucketCount
            guard lower < upper else { continue }

            let indices = lower..<upper
            let minimum = indices.min { snapshots[$0].wattage < snapshots[$1].wattage }
            let maximum = indices.max { snapshots[$0].wattage < snapshots[$1].wattage }
            for index in [minimum, maximum].compactMap({ $0 }).sorted() {
                if selectedIndices.last != index {
                    selectedIndices.append(index)
                }
            }
        }

        if let lastIndex = snapshots.indices.last, selectedIndices.last != lastIndex {
            selectedIndices.append(lastIndex)
        }
        return selectedIndices.map { snapshots[$0] }
    }

    /// TrendPoint 的等距全范围抽稀：与 powerSnapshots 的保峰策略不同，
    /// 趋势点带缺口标志，保留范围完整性优先——24 小时范围内曲线必须与
    /// 同卡统计数字覆盖同一时间窗，只截取末端会让两者无法对账。
    /// 断点传播：被抽稀丢弃的区间内若存在 breakBefore 点，传播到下一个
    /// 保留点，防止抽样后跨真实缺口直连。
    static func downsampleTrendPoints(_ points: [TrendPoint], maxPoints: Int = 240) -> [TrendPoint] {
        guard maxPoints >= 2, points.count > maxPoints else { return points }
        let stride = Double(points.count - 1) / Double(maxPoints - 1)
        var result: [TrendPoint] = []
        result.reserveCapacity(maxPoints + 1)
        var previousKeptIndex: Int?
        var cursor = 0.0
        while Int(cursor) < points.count - 1 {
            let index = Int(cursor)
            var point = points[index]
            if let prev = previousKeptIndex, prev < index,
               ((prev + 1)...index).contains(where: { points[$0].breakBefore }) {
                point = TrendPoint(
                    time: point.time, value: point.value,
                    maximum: point.maximum, coverage: point.coverage,
                    breakBefore: true
                )
            }
            result.append(point)
            previousKeptIndex = index
            cursor += stride
        }
        if let last = points.last, result.last?.time != last.time {
            var lastPoint = last
            if let prev = previousKeptIndex, prev < points.count - 1,
               ((prev + 1)...(points.count - 1)).contains(where: { points[$0].breakBefore }) {
                lastPoint = TrendPoint(
                    time: lastPoint.time, value: lastPoint.value,
                    maximum: lastPoint.maximum, coverage: lastPoint.coverage,
                    breakBefore: true
                )
            }
            result.append(lastPoint)
        }
        return result
    }
}
