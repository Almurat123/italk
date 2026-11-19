import Foundation
import HealthKit
import AssistantCore

@MainActor final class HealthService {
    private let store = HKHealthStore()
    private let steps = HKQuantityType(.stepCount)
    private let sleep = HKCategoryType(.sleepAnalysis)
    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw AppFailure.message("此设备不支持健康数据。") }
        try await store.requestAuthorization(toShare: [], read: [steps, sleep])
    }
    func answer(_ intent: LocalIntent) async throws -> String {
        guard HKHealthStore.isHealthDataAvailable() else { throw AppFailure.message("此设备不支持健康数据。") }
        let now = Date.now, calendar = Calendar.current
        switch intent {
        case .steps:
            let start = calendar.startOfDay(for: now)
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
            let statistics = try await HKStatisticsQueryDescriptor(predicate: .quantitySample(type: steps, predicate: predicate), options: .cumulativeSum).result(for: store)
            guard let quantity = statistics?.sumQuantity() else { return "目前没有可读取的步数。可能是尚未同步、未记录或未允许读取；这不表示今天走了零步。" }
            return "今天已记录约 \(Int(quantity.doubleValue(for: .count()))) 步。这是健康 App 中目前可读取的累计数据，设备同步可能有延迟。"
        case .sleep:
            let start = calendar.date(byAdding: .hour, value: -36, to: now)!
            let samples = try await sleepSamples(start: start, end: now)
            let asleep = samples.filter { $0.stage != .awake && $0.stage != .inBed }.sorted { $0.end < $1.end }
            guard let latest = asleep.last else { return "暂时没有可读取的近期睡眠记录。请检查佩戴、同步和健康读取设置；我不会把缺失记录当成没有睡觉。" }
            // Separate the latest episode from earlier naps by a four-hour gap.
            var episode = [latest], boundary = latest.start
            for sample in asleep.dropLast().reversed() {
                if boundary.timeIntervalSince(sample.end) > 4 * 3600 { break }
                episode.append(sample); boundary = min(boundary, sample.start)
            }
            let duration = HealthMath.sleepDuration(episode, within: DateInterval(start: boundary, end: latest.end))
            let hours = Int(duration) / 3600, minutes = Int(duration) % 3600 / 60
            let freshness = now.timeIntervalSince(latest.end) > 24 * 3600 ? "这条记录已经超过一天，可能不是最近一次睡眠。" : ""
            return "最近一次已记录的睡眠约 \(hours) 小时 \(minutes) 分钟。\(freshness)这是可穿戴设备的估计，未将卧床时间重复计入，不作为医学诊断。"
        case .trend:
            let end = calendar.startOfDay(for: now), start = calendar.date(byAdding: .day, value: -14, to: end)!
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            let collection = try await HKStatisticsCollectionQueryDescriptor(predicate: .quantitySample(type: steps, predicate: predicate), options: .cumulativeSum, anchorDate: start, intervalComponents: DateComponents(day: 1)).result(for: store)
            var values: [Double?] = []
            collection.enumerateStatistics(from: start, to: end) { statistics, _ in values.append(statistics.sumQuantity()?.doubleValue(for: .count())) }
            guard values.count >= 14, let previous = HealthMath.mean(Array(values.prefix(7))), let current = HealthMath.mean(Array(values.suffix(7))) else { return "两周中每周都需要至少五天可读取的记录，才能做可靠的步数对比。目前数据覆盖不足。" }
            return "最近七天日均约 \(Int(current)) 步，前七天约 \(Int(previous)) 步。数据只比较已记录的天数，佩戴习惯或来源变化也会影响结果。"
        default: throw AppFailure.message("暂不支持此健康查询。")
        }
    }
    private func sleepSamples(start: Date, end: Date) async throws -> [SleepInterval] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let samples = try await HKSampleQueryDescriptor(predicates: [.categorySample(type: sleep, predicate: predicate)], sortDescriptors: [SortDescriptor(\HKCategorySample.startDate)], limit: 3000).result(for: store)
        return samples.compactMap { sample in
            let stage: SleepInterval.Stage
            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .inBed: stage = .inBed
            case .awake: stage = .awake
            case .asleepCore: stage = .core
            case .asleepDeep: stage = .deep
            case .asleepREM: stage = .rem
            case .asleepUnspecified: stage = .asleep
            default: return nil
            }
            return SleepInterval(start: sample.startDate, end: sample.endDate, stage: stage, source: sample.sourceRevision.source.bundleIdentifier)
        }
    }
}
