import Charts
import SwiftUI

/// A small live area chart of bytes per second.
struct ThroughputSparkline: View {
    let samples: [ThroughputSample]
    let keyPath: KeyPath<ThroughputSample, Double>
    let color: Color

    var body: some View {
        Chart(samples) { sample in
            AreaMark(
                x: .value("Time", sample.time),
                y: .value("Bytes/s", sample[keyPath: keyPath])
            )
            .foregroundStyle(color.opacity(0.18))
            .interpolationMethod(.monotone)
            LineMark(
                x: .value("Time", sample.time),
                y: .value("Bytes/s", sample[keyPath: keyPath])
            )
            .foregroundStyle(color)
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: 0...max(1024, (samples.map { $0[keyPath: keyPath] }.max() ?? 0) * 1.1))
        .frame(height: 36)
    }
}
