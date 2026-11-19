import Foundation
import AgentRuntime
#if os(iOS)
import HealthKit

enum HealthTypes {
    struct Metric { let id: String; let type: HKQuantityType; let unit: HKUnit; let unitLabel: String; let cumulative: Bool }
    static let metrics: [Metric] = [
        .init(id: "steps", type: HKQuantityType(.stepCount), unit: .count(), unitLabel: "步", cumulative: true),
        .init(id: "distance", type: HKQuantityType(.distanceWalkingRunning), unit: .meterUnit(with: .kilo), unitLabel: "公里", cumulative: true),
        .init(id: "activeEnergy", type: HKQuantityType(.activeEnergyBurned), unit: .kilocalorie(), unitLabel: "千卡", cumulative: true),
        .init(id: "flights", type: HKQuantityType(.flightsClimbed), unit: .count(), unitLabel: "层", cumulative: true),
        .init(id: "exerciseMinutes", type: HKQuantityType(.appleExerciseTime), unit: .minute(), unitLabel: "分钟", cumulative: true),
        .init(id: "heartRate", type: HKQuantityType(.heartRate), unit: HKUnit.count().unitDivided(by: .minute()), unitLabel: "次/分", cumulative: false),
        .init(id: "restingHeartRate", type: HKQuantityType(.restingHeartRate), unit: HKUnit.count().unitDivided(by: .minute()), unitLabel: "次/分", cumulative: false),
        .init(id: "hrv", type: HKQuantityType(.heartRateVariabilitySDNN), unit: .secondUnit(with: .milli), unitLabel: "毫秒", cumulative: false),
        .init(id: "oxygen", type: HKQuantityType(.oxygenSaturation), unit: .percent(), unitLabel: "", cumulative: false),
        .init(id: "respiratoryRate", type: HKQuantityType(.respiratoryRate), unit: HKUnit.count().unitDivided(by: .minute()), unitLabel: "次/分", cumulative: false),
        .init(id: "weight", type: HKQuantityType(.bodyMass), unit: .gramUnit(with: .kilo), unitLabel: "公斤", cumulative: false),
    ]
    static let sleep = HKCategoryType(.sleepAnalysis)
    static var read: Set<HKObjectType> { Set(metrics.map(\.type) as [HKObjectType]).union([sleep, HKObjectType.workoutType()]) }
}

final class HealthStoreBox: @unchecked Sendable { static let shared = HealthStoreBox(); let store = HKHealthStore() }
#endif

enum HealthSkills {
    static let unknownNote = "健康 App 不会告诉第三方是否已授权读取；没有数据可能表示未记录、未同步或未允许读取，不代表数值为零。"

    static let query = FnTool(ToolSpec(name: "health_query", description: "读取健康数据（步数、距离、活动能量、心率、静息心率、HRV、血氧、呼吸频率、体重等）", parameters: [
        "metric": ParamSpec(.string, "指标", enumValues: ["steps", "distance", "activeEnergy", "flights", "exerciseMinutes", "heartRate", "restingHeartRate", "hrv", "oxygen", "respiratoryRate", "weight"]),
        "start": ParamSpec(.string, "开始日期/时间，默认今天 0 点", required: false, maxLength: 40),
        "end": ParamSpec(.string, "结束，默认现在", required: false, maxLength: 40),
        "byDay": ParamSpec(.boolean, "按天分组（最多 31 天）", required: false)
    ], permission: .readOnly, capability: .health, systemPermission: .health, dataClass: .sensitive, timeoutSeconds: 15)) { a, ctx in
        #if os(iOS)
        guard let id = a.str("metric"), let m = HealthTypes.metrics.first(where: { $0.id == id }) else { throw fail("不支持的指标") }
        let cal = Calendar.current
        let start = ArgDate.parse(a.str("start"), now: ctx.now) ?? cal.startOfDay(for: ctx.now)
        let end = min(ArgDate.parse(a.str("end"), now: ctx.now) ?? ctx.now, ctx.now)
        guard end > start else { throw fail("时间范围无效") }
        let store = HealthStoreBox.shared.store
        let pred = HKQuery.predicateForSamples(withStart: start, end: end)
        let options: HKStatisticsOptions = m.cumulative ? .cumulativeSum : [.discreteAverage, .discreteMin, .discreteMax]
        func value(_ s: HKStatistics?) -> JSONValue {
            guard let s else { return .null }
            if m.cumulative { return s.sumQuantity().map { .number(($0.doubleValue(for: m.unit) * 10).rounded() / 10) } ?? .null }
            guard let avg = s.averageQuantity() else { return .null }
            let scale = m.id == "oxygen" ? 100.0 : 1
            return .object(["average": .number((avg.doubleValue(for: m.unit) * scale * 10).rounded() / 10),
                            "min": .number((s.minimumQuantity()?.doubleValue(for: m.unit) ?? 0) * scale),
                            "max": .number((s.maximumQuantity()?.doubleValue(for: m.unit) ?? 0) * scale)])
        }
        if a.flag("byDay") == true {
            let dayStart = cal.startOfDay(for: start)
            guard end.timeIntervalSince(dayStart) <= 31 * 86400 else { throw fail("按天最多 31 天") }
            let coll = try await HKStatisticsCollectionQueryDescriptor(predicate: .quantitySample(type: m.type, predicate: pred), options: options,
                                                                        anchorDate: dayStart, intervalComponents: DateComponents(day: 1)).result(for: store)
            var days: [JSONValue] = []
            coll.enumerateStatistics(from: dayStart, to: end) { s, _ in
                days.append(.object(["date": .string(ArgDate.iso(s.startDate).prefix(10).description), "value": value(s)]))
            }
            let recorded = days.filter { $0["value"] != .null }.count
            return out(["metric": .string(id), "unit": .string(m.unitLabel), "days": .array(days), "daysWithData": .number(Double(recorded)),
                        "note": .string(unknownNote)], "\(id) 按天 \(days.count) 天（\(recorded) 天有记录）")
        }
        let s = try await HKStatisticsQueryDescriptor(predicate: .quantitySample(type: m.type, predicate: pred), options: options).result(for: store)
        let v = value(s)
        let label = ["steps": "步数", "distance": "距离", "activeEnergy": "活动能量", "flights": "爬楼层数", "exerciseMinutes": "锻炼分钟", "heartRate": "心率",
                     "restingHeartRate": "静息心率", "hrv": "心率变异性", "oxygen": "血氧", "respiratoryRate": "呼吸频率", "weight": "体重"][id] ?? id
        if v == .null {
            return out(["metric": .string(id), "unit": .string(m.unitLabel), "value": .null, "noData": .bool(true),
                        "note": .string("没有读到数据。可能是这段时间没有记录、数据还没同步，或你没有允许 iTalk 读取「\(label)」。不要把它当作 0。")],
                       "没有读到「\(label)」数据：可能未记录或未允许读取")
                .with(recovery: .openSystemSettings, permission: "健康")
        }
        var shown = ""
        if case .number(let n) = v { shown = (n == n.rounded() ? String(Int(n)) : String(n)) + m.unitLabel }
        return ToolOutput(value: .object(["metric": .string(id), "unit": .string(m.unitLabel), "start": .string(ArgDate.iso(start)), "end": .string(ArgDate.iso(end)),
                    "value": v, "note": .string(unknownNote)]), summary: "\(label)：\(shown.isEmpty ? "已读取" : shown)",
                          facts: shown.isEmpty ? nil : [.init(label, shown)])
        #else
        throw fail("此平台没有健康数据")
        #endif
    }

    static let sleep = FnTool(ToolSpec(name: "health_sleep", description: "读取最近几晚的睡眠（入睡/醒来时间、睡眠时长、各阶段）", parameters: [
        "nights": ParamSpec(.integer, "最近几晚，默认 1，最多 14", required: false, minimum: 1, maximum: 14)
    ], permission: .readOnly, capability: .health, systemPermission: .health, dataClass: .sensitive, timeoutSeconds: 15)) { a, ctx in
        #if os(iOS)
        let nights = a.int("nights") ?? 1
        let start = ctx.now.addingTimeInterval(-Double(nights) * 86400 - 12 * 3600)
        let samples = try await HKSampleQueryDescriptor(predicates: [.categorySample(type: HealthTypes.sleep, predicate: HKQuery.predicateForSamples(withStart: start, end: ctx.now))],
                                                        sortDescriptors: [SortDescriptor(\HKCategorySample.startDate)], limit: 5000).result(for: HealthStoreBox.shared.store)
        let asleepValues: Set<Int> = [HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                      HKCategoryValueSleepAnalysis.asleepREM.rawValue, HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue]
        let asleep = samples.filter { asleepValues.contains($0.value) }.map { (s: $0.startDate, e: $0.endDate, v: $0.value) }
        // Group into episodes split by gaps > 4 h; durations are unions (several sources never double-count).
        var episodes: [[(s: Date, e: Date, v: Int)]] = []
        for x in asleep {
            if let last = episodes.last?.map(\.e).max(), x.s.timeIntervalSince(last) <= 4 * 3600 { episodes[episodes.count - 1].append(x) } else { episodes.append([x]) }
        }
        func union(_ xs: [(s: Date, e: Date, v: Int)]) -> Double {
            var total = 0.0, cur: (Date, Date)?
            for x in xs.sorted(by: { $0.s < $1.s }) {
                if let c = cur, x.s <= c.1 { cur = (c.0, max(c.1, x.e)) } else { if let c = cur { total += c.1.timeIntervalSince(c.0) }; cur = (x.s, x.e) }
            }
            if let c = cur { total += c.1.timeIntervalSince(c.0) }
            return total
        }
        let list: [JSONValue] = episodes.suffix(nights).map { ep in
            let stage = { (v: HKCategoryValueSleepAnalysis) in union(ep.filter { $0.v == v.rawValue }) / 60 }
            return .object(["fellAsleep": .string(ArgDate.iso(ep.map(\.s).min()!)), "wokeUp": .string(ArgDate.iso(ep.map(\.e).max()!)),
                            "asleepMinutes": .number((union(ep) / 60).rounded()), "deepMinutes": .number(stage(.asleepDeep).rounded()),
                            "remMinutes": .number(stage(.asleepREM).rounded()), "coreMinutes": .number(stage(.asleepCore).rounded())])
        }
        return out(["nights": .array(list), "note": .string(unknownNote + " 睡眠为可穿戴设备估计，不作医学诊断。")],
                   list.isEmpty ? "没有可读取的睡眠记录" : "读取了 \(list.count) 晚睡眠")
        #else
        throw fail("此平台没有健康数据")
        #endif
    }

    static let workouts = FnTool(ToolSpec(name: "health_workouts", description: "列出最近的体能训练（类型、时长、距离、能量）", parameters: [
        "days": ParamSpec(.integer, "最近几天，默认 7", required: false, minimum: 1, maximum: 90),
        "limit": ParamSpec(.integer, "默认 10", required: false, minimum: 1, maximum: 50)
    ], permission: .readOnly, capability: .health, systemPermission: .health, dataClass: .sensitive, timeoutSeconds: 15)) { a, ctx in
        #if os(iOS)
        let start = ctx.now.addingTimeInterval(-Double(a.int("days") ?? 7) * 86400)
        let list = try await HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: ctx.now))],
                                                     sortDescriptors: [SortDescriptor(\HKWorkout.startDate, order: .reverse)], limit: a.int("limit") ?? 10).result(for: HealthStoreBox.shared.store)
        return out(["workouts": .array(list.map { w in
            var o: [String: JSONValue] = ["activity": .number(Double(w.workoutActivityType.rawValue)), "start": .string(ArgDate.iso(w.startDate)),
                                          "minutes": .number((w.duration / 60).rounded())]
            if let d = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity() { o["km"] = .number((d.doubleValue(for: .meterUnit(with: .kilo)) * 100).rounded() / 100) }
            if let e = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() { o["kcal"] = .number(e.doubleValue(for: .kilocalorie()).rounded()) }
            return .object(o)
        }), "note": .string(unknownNote)], "\(list.count) 次训练")
        #else
        throw fail("此平台没有健康数据")
        #endif
    }
}
