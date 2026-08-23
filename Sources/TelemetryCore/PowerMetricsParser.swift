import Foundation

public enum PowerMetricsComponent: Equatable, Sendable {
    case cpu
    case gpu
    case dram
}

public struct ParsedPowerMetric: Equatable, Sendable {
    public let component: PowerMetricsComponent
    public let watts: Double

    public init(component: PowerMetricsComponent, watts: Double) {
        self.component = component
        self.watts = watts
    }
}

/// `powermetrics` 文本协议的单行解析器。
///
/// Helper 强制使用 C locale，并由这里集中处理 mW/uW/W、非有限值、负值和异常范围，
/// 避免系统输出变化把错误数据传播到 UI。Apple 将这些功率定义为模型估算值，调用方
/// 不应把结果描述为精密硬件测量。
public enum PowerMetricsParser {
    public static func parse(line: String) -> ParsedPowerMetric? {
        let component: PowerMetricsComponent
        if line.contains("CPU Power") {
            component = .cpu
        } else if line.contains("GPU Power") {
            component = .gpu
        } else if line.contains("DRAM Power") {
            component = .dram
        } else {
            return nil
        }

        guard let watts = parseWatts(line), watts.isFinite, watts >= 0, watts < 500 else {
            return nil
        }
        return ParsedPowerMetric(component: component, watts: watts)
    }

    private static func parseWatts(_ line: String) -> Double? {
        if let range = line.range(of: "mW") {
            return value(before: range.lowerBound, in: line).map { $0 / 1_000 }
        }
        if let range = line.range(of: "uW") {
            return value(before: range.lowerBound, in: line).map { $0 / 1_000_000 }
        }
        if let range = line.range(of: #"(?<![mu])W"#, options: .regularExpression) {
            return value(before: range.lowerBound, in: line)
        }
        return nil
    }

    private static func value(before unit: String.Index, in line: String) -> Double? {
        let prefix = line[..<unit]
        guard let token = prefix.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "=" }).last else {
            return nil
        }
        return Double(token)
    }
}
