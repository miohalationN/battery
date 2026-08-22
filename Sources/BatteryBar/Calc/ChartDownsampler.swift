import Foundation

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
}
