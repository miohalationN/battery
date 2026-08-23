import Testing
import TelemetryCore

@Suite struct PowerMetricsParserTests {
    @Test func parsesSupportedComponentsAndUnits() throws {
        let cpu = try #require(PowerMetricsParser.parse(line: "CPU Power: 1234 mW"))
        #expect(cpu.component == .cpu)
        #expect(abs(cpu.watts - 1.234) < 0.0001)

        let gpu = try #require(PowerMetricsParser.parse(line: "GPU Power: 1.25 W"))
        #expect(gpu.component == .gpu)
        #expect(gpu.watts == 1.25)

        let dram = try #require(PowerMetricsParser.parse(line: "DRAM Power: 250000 uW"))
        #expect(dram.component == .dram)
        #expect(dram.watts == 0.25)
    }

    @Test func zeroIsAValidSample() throws {
        let metric = try #require(PowerMetricsParser.parse(line: "CPU Power: 0 mW"))
        #expect(metric.watts == 0)
    }

    @Test func rejectsUnrelatedMalformedAndImplausibleLines() {
        #expect(PowerMetricsParser.parse(line: "Package Power: 2 W") == nil)
        #expect(PowerMetricsParser.parse(line: "CPU Power: unavailable") == nil)
        #expect(PowerMetricsParser.parse(line: "CPU Power: -2 W") == nil)
        #expect(PowerMetricsParser.parse(line: "GPU Power: 600 W") == nil)
    }
}
