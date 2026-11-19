import Foundation
import AgentRuntime
import CoreLocation
import MapKit

/// One-shot location fix (a retained manager plus its delegate; times out instead of hanging).
@MainActor final class LocationFix: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var done: CheckedContinuation<CLLocation, Error>?
    static func current(timeout: Double = 12) async throws -> CLLocation {
        let f = LocationFix()
        f.manager.delegate = f; f.manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        return try await withCheckedThrowingContinuation { c in
            f.done = c
            f.manager.requestLocation()
            Task { @MainActor in try? await Task.sleep(for: .seconds(timeout)); f.finish(.failure(fail("定位超时，请到开阔处再试", retry: true))) }
        }
    }
    private func finish(_ r: Result<CLLocation, Error>) { guard let d = done else { return }; done = nil; d.resume(with: r); _ = self }
    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        guard let loc = l.last else { return }
        Task { @MainActor in self.finish(.success(loc)) }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failure(fail("无法获取位置：\(error.localizedDescription)", retry: true))) }
    }
}

enum PlaceSkills {
    static func round(_ v: Double, _ places: Double) -> Double { (v * places).rounded() / places }

    static func address(_ item: MKMapItem) -> String {
        item.address?.fullAddress ?? item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true) ?? ""
    }
    static func itemJSON(_ i: MKMapItem, from: CLLocation?) -> JSONValue {
        var o: [String: JSONValue] = ["name": .string(i.name ?? ""), "address": .string(address(i)),
                                      "latitude": .number(round(i.location.coordinate.latitude, 1e5)), "longitude": .number(round(i.location.coordinate.longitude, 1e5))]
        if let p = i.phoneNumber { o["phone"] = .string(p) }
        if let u = i.url { o["url"] = .string(u.absoluteString) }
        if let c = i.pointOfInterestCategory { o["category"] = .string(c.rawValue.replacingOccurrences(of: "MKPOICategory", with: "")) }
        if let from { o["distanceMeters"] = .number(i.location.distance(from: from).rounded()) }
        return .object(o)
    }

    /// Resolves a place description to a map item (search near the person when location is available).
    static func resolve(_ query: String, near: CLLocation?) async throws -> MKMapItem {
        let req = MKLocalSearch.Request(); req.naturalLanguageQuery = query
        if let near { req.region = MKCoordinateRegion(center: near.coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        guard let item = try await MKLocalSearch(request: req).start().mapItems.first else { throw fail("找不到「\(query)」") }
        return item
    }
    static func here(_ allowed: Bool) async -> CLLocation? {
        guard allowed, locationAuthorized(CLLocationManager().authorizationStatus) else { return nil }
        return try? await LocationFix.current(timeout: 8)
    }

    static let currentLocation = FnTool(ToolSpec(name: "location_current", description: "获取当前位置与地址（默认约百米精度）", parameters: [
        "precise": ParamSpec(.boolean, "需要精确坐标时为 true", required: false)
    ], permission: .readOnly, capability: .location, systemPermission: .location, dataClass: .personal, timeoutSeconds: 15)) { a, _ in
        let loc = try await LocationFix.current()
        let scale = a.flag("precise") == true ? 1e5 : 1e3
        var o: [String: JSONValue] = ["latitude": .number(round(loc.coordinate.latitude, scale)), "longitude": .number(round(loc.coordinate.longitude, scale)),
                                      "accuracyMeters": .number(loc.horizontalAccuracy.rounded())]
        if let r = MKReverseGeocodingRequest(location: loc), let item = try? await r.mapItems.first {
            o["address"] = .string(address(item))
            if let city = item.addressRepresentations?.cityWithContext { o["city"] = .string(city) }
        }
        return out(o, "已获取当前位置\(o["city"]?.string.map { "（\($0)）" } ?? "")")
    }

    static let search = FnTool(ToolSpec(name: "maps_search", description: "搜索附近或指定地点的地点、商户、地址（Apple 地图数据，国内为高德数据）", parameters: [
        "query": ParamSpec(.string, "例如“咖啡”“西湖”“北京南站”", maxLength: 100),
        "nearMe": ParamSpec(.boolean, "在当前位置附近搜索，默认 true", required: false),
        "limit": ParamSpec(.integer, "默认 8", required: false, minimum: 1, maximum: 20)
    ], permission: .readOnly, capability: .maps, dataClass: .personal, timeoutSeconds: 20)) { a, _ in
        guard let q = a.str("query") else { throw fail("缺少搜索内容") }
        let me = await here(a.flag("nearMe") ?? true)
        let req = MKLocalSearch.Request(); req.naturalLanguageQuery = q
        if let me { req.region = MKCoordinateRegion(center: me.coordinate, latitudinalMeters: 8000, longitudinalMeters: 8000) }
        let items = try await MKLocalSearch(request: req).start().mapItems
        let sorted = me.map { m in items.sorted { $0.location.distance(from: m) < $1.location.distance(from: m) } } ?? items
        let list = sorted.prefix(a.int("limit") ?? 8)
        return out(["results": .array(list.map { itemJSON($0, from: me) }), "nearMe": .bool(me != nil)], "找到 \(list.count) 个地点")
    }

    static let route = FnTool(ToolSpec(name: "maps_route", description: "估算路线距离与耗时（驾车/步行/公交）", parameters: [
        "to": ParamSpec(.string, "目的地", maxLength: 120),
        "from": ParamSpec(.string, "出发地，默认当前位置", required: false, maxLength: 120),
        "mode": ParamSpec(.string, "方式", required: false, enumValues: ["driving", "walking", "transit"])
    ], permission: .readOnly, capability: .maps, dataClass: .personal, timeoutSeconds: 25)) { a, _ in
        guard let to = a.str("to") else { throw fail("缺少目的地") }
        let me = await here(true)
        let dest = try await resolve(to, near: me)
        let req = MKDirections.Request()
        if let f = a.str("from") { req.source = try await resolve(f, near: me) }
        else if me != nil { req.source = MKMapItem.forCurrentLocation() }
        else { throw fail("没有出发地：请说明出发地点，或允许 iTalk 使用位置") }
        req.destination = dest
        req.transportType = ["walking": .walking, "transit": .transit][a.str("mode") ?? ""] ?? .automobile
        let eta = try await MKDirections(request: req).calculateETA()
        return out(["destination": itemJSON(dest, from: me), "minutes": .number((eta.expectedTravelTime / 60).rounded()),
                    "km": .number(round(eta.distance / 1000, 10)), "arrival": .string(ArgDate.iso(eta.expectedArrivalDate)),
                    "mode": .string(a.str("mode") ?? "driving")], "到\(dest.name ?? to)约 \(Int(eta.expectedTravelTime / 60)) 分钟")
    }

    static func openMaps(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "maps_open", description: "在地图 App 中显示地点或开始导航（Apple 地图、高德地图、百度地图）", parameters: [
            "destination": ParamSpec(.string, "地点", maxLength: 120),
            "navigate": ParamSpec(.boolean, "直接开始导航", required: false),
            "app": ParamSpec(.string, "默认 apple", required: false, enumValues: ["apple", "amap", "baidu"]),
            "mode": ParamSpec(.string, "方式", required: false, enumValues: ["driving", "walking", "transit"])
        ], permission: .lowRiskAction, capability: .maps, timeoutSeconds: 20)) { a, _ in
            guard let d = a.str("destination") else { throw fail("缺少地点") }
            let enc = d.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? d
            let mode = a.str("mode") ?? "driving"
            let url: URL
            switch a.str("app") ?? "apple" {
            case "amap":
                let t = ["driving": "0", "transit": "1", "walking": "2"][mode] ?? "0"
                url = URL(string: "iosamap://path?sourceApplication=iTalk&dname=\(enc)&dev=0&t=\(t)")!
            case "baidu":
                url = URL(string: "baidumap://map/direction?destination=\(enc)&mode=\(mode)&src=ios.italk.assistant")!
            default:
                let flag = ["driving": "d", "walking": "w", "transit": "r"][mode] ?? "d"
                url = URL(string: a.flag("navigate") == true ? "maps://?daddr=\(enc)&dirflg=\(flag)" : "maps://?q=\(enc)")!
            }
            guard await ctx.presenter.canOpen(url) else { throw fail("没有安装对应的地图 App") }
            let ok = await ctx.presenter.open(url)
            return out(["opened": .bool(ok), "app": .string(a.str("app") ?? "apple")], ok ? "已在地图中打开「\(d)」" : "未能打开地图")
        }
    }

    // MARK: Weather (Open-Meteo: no key, global coverage; WeatherKit needs a paid service entitlement)

    static let codes: [Int: String] = [0: "晴", 1: "大致晴朗", 2: "局部多云", 3: "阴", 45: "雾", 48: "雾凇", 51: "小毛毛雨", 53: "毛毛雨", 55: "大毛毛雨",
        61: "小雨", 63: "中雨", 65: "大雨", 66: "冻雨", 67: "强冻雨", 71: "小雪", 73: "中雪", 75: "大雪", 77: "雪粒", 80: "阵雨", 81: "中阵雨", 82: "强阵雨",
        85: "阵雪", 86: "强阵雪", 95: "雷阵雨", 96: "雷阵雨伴冰雹", 99: "强雷阵雨伴冰雹"]

    static let weather = FnTool(ToolSpec(name: "weather_forecast", description: "查询当前天气、逐日预报和空气质量", parameters: [
        "place": ParamSpec(.string, "城市或地点；省略则用当前位置", required: false, maxLength: 80),
        "days": ParamSpec(.integer, "预报天数 1–7，默认 3", required: false, minimum: 1, maximum: 7)
    ], permission: .readOnly, capability: .weather, timeoutSeconds: 25)) { a, _ in
        let me = await here(a.str("place") == nil)
        let lat: Double, lon: Double, name: String
        if let p = a.str("place") {
            let item = try await resolve(p, near: nil)
            lat = item.location.coordinate.latitude; lon = item.location.coordinate.longitude; name = item.name ?? p
        } else if let me { lat = me.coordinate.latitude; lon = me.coordinate.longitude; name = "当前位置" }
        else { throw fail("请告诉我城市，或允许 iTalk 使用位置") }
        let days = a.int("days") ?? 3
        let f = String(format: "latitude=%.3f&longitude=%.3f", lat, lon)
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?\(f)&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,precipitation&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,uv_index_max,sunrise,sunset&timezone=auto&forecast_days=\(days)")!
        let (data, _) = try await WebHTTP().get(url, accept: "application/json")
        guard let j = JSONValue.parse(String(decoding: data, as: UTF8.self)), let cur = j["current"] else { throw fail("天气服务返回无效", retry: true) }
        let daily = j["daily"]
        var forecast: [JSONValue] = []
        for i in 0..<(daily?["time"]?.array?.count ?? 0) {
            func d(_ k: String) -> JSONValue { daily?[k]?.array?[i] ?? .null }
            forecast.append(.object(["date": d("time"), "weather": .string(codes[Int(d("weather_code").number ?? -1)] ?? "未知"),
                                     "max": d("temperature_2m_max"), "min": d("temperature_2m_min"), "rainChance": d("precipitation_probability_max"),
                                     "uv": d("uv_index_max"), "sunrise": d("sunrise"), "sunset": d("sunset")]))
        }
        var o: [String: JSONValue] = ["place": .string(name), "now": .object([
            "temperature": cur["temperature_2m"] ?? .null, "feelsLike": cur["apparent_temperature"] ?? .null, "humidity": cur["relative_humidity_2m"] ?? .null,
            "weather": .string(codes[Int(cur["weather_code"]?.number ?? -1)] ?? "未知"), "windKmh": cur["wind_speed_10m"] ?? .null,
            "precipitationMm": cur["precipitation"] ?? .null]), "daily": .array(forecast), "source": .string("Open-Meteo")]
        if let aq = try? await WebHTTP().get(URL(string: "https://air-quality-api.open-meteo.com/v1/air-quality?\(f)&current=pm2_5,pm10,us_aqi")!, accept: "application/json"),
           let aj = JSONValue.parse(String(decoding: aq.0, as: UTF8.self))?["current"] {
            o["air"] = .object(["aqiUS": aj["us_aqi"] ?? .null, "pm2_5": aj["pm2_5"] ?? .null, "pm10": aj["pm10"] ?? .null])
        }
        return out(o, "\(name)：\(o["now"]?["weather"]?.string ?? "") \(cur["temperature_2m"]?.number.map { "\(Int($0.rounded()))°C" } ?? "")")
    }
}
