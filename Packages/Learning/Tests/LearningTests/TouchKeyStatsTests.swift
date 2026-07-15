import XCTest
@testable import Learning

final class TouchKeyStatsTests: XCTestCase {

    /// Batch (two-pass) reference statistics.
    private func batchStats(_ samples: [(dx: Double, dy: Double)]) -> (
        meanDX: Double, meanDY: Double, varDX: Double, varDY: Double, cov: Double
    ) {
        let n = Double(samples.count)
        let meanDX = samples.map(\.dx).reduce(0, +) / n
        let meanDY = samples.map(\.dy).reduce(0, +) / n
        let varDX = samples.map { ($0.dx - meanDX) * ($0.dx - meanDX) }.reduce(0, +) / (n - 1)
        let varDY = samples.map { ($0.dy - meanDY) * ($0.dy - meanDY) }.reduce(0, +) / (n - 1)
        let cov = samples.map { ($0.dx - meanDX) * ($0.dy - meanDY) }.reduce(0, +) / (n - 1)
        return (meanDX, meanDY, varDX, varDY, cov)
    }

    func testWelfordMatchesBatchComputation() throws {
        // Deterministic pseudo-random samples (seeded LCG — reproducible).
        var seed: UInt64 = 0x5EED
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53) - 0.5
        }
        let samples = (0..<1_000).map { _ in (dx: next() * 0.8, dy: next() * 0.6 + 0.1) }

        var stats = TouchKeyStats()
        for sample in samples {
            stats.update(dx: sample.dx, dy: sample.dy)
        }
        let reference = batchStats(samples)

        XCTAssertEqual(stats.count, 1_000)
        XCTAssertEqual(stats.meanDX, reference.meanDX, accuracy: 1e-12)
        XCTAssertEqual(stats.meanDY, reference.meanDY, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(stats.varianceDX), reference.varDX, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(stats.varianceDY), reference.varDY, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(stats.covarianceDXDY), reference.cov, accuracy: 1e-12)
    }

    func testCorrelatedSamplesProducePositiveCovariance() {
        var stats = TouchKeyStats()
        for i in 0..<100 {
            let v = Double(i) / 100.0
            stats.update(dx: v, dy: v * 2)
        }
        XCTAssertGreaterThan(stats.covarianceDXDY ?? 0, 0)
    }

    func testVarianceNilBeforeTwoSamples() {
        var stats = TouchKeyStats()
        XCTAssertNil(stats.varianceDX)
        stats.update(dx: 0.1, dy: 0.2)
        XCTAssertNil(stats.varianceDX)
        XCTAssertNil(stats.covarianceDXDY)
        stats.update(dx: 0.3, dy: 0.4)
        XCTAssertNotNil(stats.varianceDX)
    }

    func testDecayPreservesMeansVarianceAndCovariance() throws {
        var stats = TouchKeyStats()
        let samples: [(Double, Double)] = [(0.1, -0.2), (0.3, 0.1), (-0.1, 0.4), (0.2, 0.0)]
        for (dx, dy) in samples {
            stats.update(dx: dx, dy: dy)
        }
        let meanDX = stats.meanDX
        let meanDY = stats.meanDY
        let varDX = try XCTUnwrap(stats.varianceDX)
        let cov = try XCTUnwrap(stats.covarianceDXDY)

        stats.decay(by: 0.5)
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats.meanDX, meanDX, accuracy: 1e-12)
        XCTAssertEqual(stats.meanDY, meanDY, accuracy: 1e-12)
        // m2/(n−1) shifts slightly because n changes while m2 scales — the
        // population variance m2/n is what decay preserves exactly.
        XCTAssertEqual(stats.m2DX / stats.count, varDX * 3 / 4, accuracy: 1e-12)
        XCTAssertEqual(stats.cDXDY / stats.count, cov * 3 / 4, accuracy: 1e-12)
    }

    func testDecayMakesNewSamplesDominate() {
        var stats = TouchKeyStats()
        for _ in 0..<100 {
            stats.update(dx: 1.0, dy: 1.0)
        }
        stats.decay(by: 0.1)  // history weight 10
        for _ in 0..<90 {
            stats.update(dx: 0.0, dy: 0.0)
        }
        XCTAssertEqual(stats.meanDX, 0.1, accuracy: 1e-9, "10 weight at 1.0 + 90 at 0.0 ⇒ mean 0.1")
    }

    func testModelAppliesDecayAtThreshold() throws {
        let config = PersonalModel.Configuration(touchSampleDecayThreshold: 10, touchDecayFactor: 0.5)
        let model = PersonalModel(configuration: config)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchDecay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = EventLog(url: directory.appendingPathComponent("events.log"), dayProvider: { 20_000 })

        for _ in 0..<20 {
            try log.append(.touchSample(keyChar: "j", dx: 0.1, dy: 0.1))
        }
        try model.compact(applying: log)
        let stats = try XCTUnwrap(model.touchStatistics(for: "j"))
        XCTAssertLessThanOrEqual(stats.count, 10.5, "effective count stays bounded by the decay threshold")
        XCTAssertEqual(stats.meanDX, 0.1, accuracy: 1e-9)
    }
}
