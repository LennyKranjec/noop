import Foundation

// WeatherNow.swift — the sky, and what it means for a suggestion.
//
// The hero tile carries the temperature, the conditions, the UV index now and the day's PEAK UV. Not
// decoration: the coach reads the same reading, and "go for a walk" is a different suggestion at 14:00
// under a UV index of 8 in the rain than it is at 18:00 in the dry.
//
// OPEN-METEO, because it needs no key and no account. Every other cloud in this app costs the wearer a
// credential; a weather lookup that needed one would be a setup step in exchange for a line of text.
// One request, no headers, no identity — the only thing that leaves the phone is a latitude and a
// longitude, and those are a CONSTANT here rather than the device's location.
//
// A FIXED PLACE, DELIBERATELY. The wearer asked for Frankfurt am Main, and taking it from Core Location
// would mean asking for location permission, holding a coordinate, and sending a real position to a
// third party — all to answer a question they have already told us the answer to.
//
// A FAILED LOOKUP IS NO WEATHER, never a guess. The tile drops the row and the coach is told nothing
// rather than something invented, because a fabricated forecast is exactly the kind of plausible-looking
// number this project refuses to print.

/// One reading of the sky.
struct WeatherNow: Equatable, Codable {
    /// °C, as the tile shows it.
    let temperatureC: Double
    /// Open-Meteo's WMO weather code, kept raw so the description and the glyph derive from one source.
    let code: Int
    /// The UV index right now.
    let uvIndex: Double
    /// The highest UV index the day reaches — which is the number that decides whether "go outside at
    /// lunchtime" is good advice.
    let uvPeak: Double
    let fetchedAt: Date

    /// Whether water is falling. The one condition that changes a suggestion outright.
    var isWet: Bool {
        // WMO: 51–67 drizzle/rain, 71–77 snow, 80–86 showers, 95–99 thunderstorm.
        (51...67).contains(code) || (71...77).contains(code) || (80...86).contains(code) || (95...99).contains(code)
    }

    /// Plain words for the code. Coarse on purpose: the tile has one line, and "moderate drizzle" and
    /// "light drizzle" ask the reader to care about a difference they cannot act on.
    var summary: String { Self.summary(code: code) }

    /// The same words for any code — the forecast's hours describe themselves with it, so "rain" means
    /// one thing on the tile and in the outlook.
    static func summary(code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67: return "Rain"
        case 71...77: return "Snow"
        case 80...82: return "Showers"
        case 85, 86: return "Snow showers"
        case 95...99: return "Thunderstorm"
        default: return "—"
        }
    }

    /// The SF Symbol for the same code.
    var symbol: String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    /// One line for the coach's grounding block. Everything it is allowed to say about the weather, and
    /// nothing it has to infer.
    var promptLine: String {
        String(format: "WEATHER (Frankfurt am Main): %.0f°C, %@. UV index now %.1f, peaking at %.1f today.",
               temperatureC, summary, uvIndex, uvPeak)
            + (isWet
               ? " It is wet — do not suggest anything outdoors that being rained on would ruin."
               : " It is dry — an outdoor suggestion is reasonable.")
            + (uvPeak >= 6
               ? " UV is high at the peak; if you suggest midday sun, say to cover up."
               : "")
    }
}

/// Today's outlook, as Open-Meteo forecasts it for the same fixed place.
///
/// SEPARATE FROM `WeatherNow`, and cached under its own key, so a reading stored by an older build
/// still decodes and the tile never loses its row because the outlook failed to parse.
struct WeatherToday: Equatable, Codable {
    /// One forecast hour. `hour` is the local hour of the day, 0–23, at the forecast's place.
    struct Hour: Equatable, Codable {
        let hour: Int
        let temperatureC: Double?
        let code: Int?
        /// Chance of precipitation, percent.
        let rainChance: Int?
    }

    /// The local calendar day the outlook is for, "yyyy-MM-dd". A forecast for yesterday is not sent.
    let day: String
    let highC: Double?
    let lowC: Double?
    /// The day's highest chance of precipitation, percent.
    let rainChanceMax: Int?
    /// The day's total precipitation, mm.
    let rainSumMm: Double?
    let uvMax: Double?
    /// "HH:mm", local.
    let sunrise: String?
    let sunset: String?
    let hours: [Hour]
    let fetchedAt: Date

    /// The chance of rain an hour counts as LIKELY from. Below it an umbrella is a hedge, not a plan.
    static let likelyRainChance = 50

    /// One line for the coach. Only what was forecast; a field the service left out is left out here.
    var promptLine: String {
        func deg(_ v: Double) -> String { String(format: "%.0f", v) }
        var sentences: [String] = []
        if let lowC, let highC { sentences.append("\(deg(lowC))–\(deg(highC)) °C") }

        // MORNING, AFTERNOON, EVENING — the three windows a suggestion is actually placed in. The
        // worst code of the window names it, because the one wet hour is the one that ruins the walk.
        let windows: [(name: String, hours: Range<Int>)] =
            [("morning", 6..<12), ("afternoon", 12..<18), ("evening", 18..<24)]
        var parts: [String] = []
        for window in windows {
            let inWindow = hours.filter { window.hours.contains($0.hour) }
            let temps = inWindow.compactMap { $0.temperatureC }
            var part = window.name
            if let worst = inWindow.compactMap({ $0.code }).max() {
                let words = WeatherNow.summary(code: worst)
                if words != "—" { part += " " + words.lowercased() }
            }
            if !temps.isEmpty { part += " " + deg(temps.reduce(0, +) / Double(temps.count)) + " °C" }
            if let chance = inWindow.compactMap({ $0.rainChance }).max(), chance >= 30 {
                part += " (rain \(chance)%)"
            }
            if part != window.name { parts.append(part) }
        }
        if !parts.isEmpty {
            let joined = parts.joined(separator: ", ")
            sentences.append(joined.prefix(1).uppercased() + String(joined.dropFirst()))
        }

        if let chance = rainChanceMax {
            if chance < 20 {
                sentences.append("Dry: rain chance \(chance)%")
            } else {
                var rain = "Rain chance up to \(chance)%"
                if let mm = rainSumMm, mm > 0 { rain += String(format: " (%.1f mm)", mm) }
                let wet = hours.filter { ($0.rainChance ?? 0) >= Self.likelyRainChance }.map { $0.hour }
                if let first = wet.min(), let last = wet.max() {
                    rain += String(format: ", likeliest %02d:00–%02d:00", first, last + 1)
                }
                sentences.append(rain)
            }
        }
        if let sunrise { sentences.append("Sunrise " + sunrise) }
        if let sunset { sentences.append("Sunset " + sunset) }
        if let uvMax { sentences.append("UV max " + String(format: "%.0f", uvMax)) }

        return "TODAY'S FORECAST (Frankfurt am Main, \(day)): " + sentences.joined(separator: ". ") + "."
    }
}

enum WeatherService {

    /// Frankfurt am Main. A constant — see the note at the top on why this is not the device's location.
    static let latitude = 50.1109
    static let longitude = 8.6821

    /// How long a reading stays fresh. Weather moves, but not in five minutes, and the tile is redrawn
    /// on every appearance — without this it would make a request each time Today came back.
    static let staleAfter: TimeInterval = 30 * 60

    private static let cacheKey = "weather.now"
    private static let forecastKey = "weather.today"

    /// The cached reading, if it is still fresh.
    static var cached: WeatherNow? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let stored = try? JSONDecoder().decode(WeatherNow.self, from: data),
              Date().timeIntervalSince(stored.fetchedAt) < staleAfter
        else { return nil }
        return stored
    }

    /// The last reading whether or not it is fresh.
    ///
    /// Separate from `cached` because a stale reading is still the best thing to DRAW while a new one is
    /// in flight — an hour-old temperature beats an empty row — whereas the freshness check is what
    /// decides whether to make the request at all.
    static var lastKnown: WeatherNow? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(WeatherNow.self, from: data)
    }

    /// The last outlook whether or not it is fresh. The coach reads this per request and never waits on
    /// the network for it; whether it is still TODAY's is the reader's check (`CoachClock`).
    static var lastKnownForecast: WeatherToday? {
        guard let data = UserDefaults.standard.data(forKey: forecastKey) else { return nil }
        return try? JSONDecoder().decode(WeatherToday.self, from: data)
    }

    /// Fetch, unless the cached reading is still fresh. Nil when there is nothing to show.
    ///
    /// `force` skips the staleness gate. A deliberate refresh — a pull, a tab appearance the wearer
    /// asked for — should ask the sky again; the gate exists to stop the app making a request every time
    /// a view happens to rebuild, not to ignore the wearer.
    @discardableResult
    static func refresh(force: Bool = false) async -> WeatherNow? {
        if !force, let cached { return cached }
        guard let url = URL(string:
            "https://api.open-meteo.com/v1/forecast"
            + "?latitude=\(latitude)&longitude=\(longitude)"
            + "&current=temperature_2m,weather_code,uv_index"
            + "&hourly=temperature_2m,weather_code,precipitation_probability"
            + "&daily=uv_index_max,temperature_2m_max,temperature_2m_min,precipitation_probability_max,"
            + "precipitation_sum,sunrise,sunset&forecast_days=1&timezone=auto")
        else { return lastKnown }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return lastKnown }

        // THE OUTLOOK ON ITS OWN: a response missing its `current` block can still carry a usable
        // forecast, and a forecast that fails to parse must not cost the tile its reading.
        if let today = parseToday(root, fetchedAt: Date()),
           let encoded = try? JSONEncoder().encode(today) {
            UserDefaults.standard.set(encoded, forKey: forecastKey)
        }

        guard let current = root["current"] as? [String: Any] else { return lastKnown }

        func number(_ o: [String: Any], _ key: String) -> Double? {
            (o[key] as? NSNumber)?.doubleValue
        }
        guard let temp = number(current, "temperature_2m") else { return lastKnown }
        let code = number(current, "weather_code").map { Int($0) } ?? -1
        let uv = number(current, "uv_index") ?? 0
        let peak = ((root["daily"] as? [String: Any])?["uv_index_max"] as? [Any])?
            .compactMap { ($0 as? NSNumber)?.doubleValue }.first ?? uv

        let reading = WeatherNow(temperatureC: temp, code: code, uvIndex: uv,
                                 uvPeak: peak, fetchedAt: Date())
        if let encoded = try? JSONEncoder().encode(reading) {
            UserDefaults.standard.set(encoded, forKey: cacheKey)
        }
        return reading
    }

    /// Today's outlook out of an Open-Meteo response. Nil when the response carries no daily block.
    ///
    /// Pure, so the parsing is testable without a network. Open-Meteo sends a null for a value it has
    /// no forecast for; every hourly field is read by INDEX so a null stays a nil rather than shifting
    /// the hours out of line.
    static func parseToday(_ root: [String: Any], fetchedAt: Date) -> WeatherToday? {
        guard let daily = root["daily"] as? [String: Any],
              let day = (daily["time"] as? [Any])?.first as? String
        else { return nil }
        func numbers(_ o: [String: Any]?, _ key: String) -> [Double?] {
            ((o?[key] as? [Any]) ?? []).map { ($0 as? NSNumber)?.doubleValue }
        }
        func firstNumber(_ key: String) -> Double? {
            numbers(daily, key).first ?? nil
        }
        // "2026-09-18T07:12" → "07:12", local to the forecast's place as `timezone=auto` asks for.
        func clock(_ key: String) -> String? {
            guard let stamp = (daily[key] as? [Any])?.first as? String,
                  let time = stamp.split(separator: "T").last, time.count >= 5
            else { return nil }
            return String(time.prefix(5))
        }

        let hourly = root["hourly"] as? [String: Any]
        let stamps = (hourly?["time"] as? [Any]) ?? []
        let temps = numbers(hourly, "temperature_2m")
        let codes = numbers(hourly, "weather_code")
        let chances = numbers(hourly, "precipitation_probability")
        var hours: [WeatherToday.Hour] = []
        for (i, stamp) in stamps.enumerated() {
            guard let stamp = stamp as? String,
                  let time = stamp.split(separator: "T").last,
                  let hour = Int(time.prefix(2))
            else { continue }
            let temp: Double? = i < temps.count ? temps[i] : nil
            let code: Double? = i < codes.count ? codes[i] : nil
            let chance: Double? = i < chances.count ? chances[i] : nil
            hours.append(WeatherToday.Hour(
                hour: hour,
                temperatureC: temp,
                code: code.map { Int($0) },
                rainChance: chance.map { Int($0.rounded()) }))
        }

        return WeatherToday(
            day: day,
            highC: firstNumber("temperature_2m_max"),
            lowC: firstNumber("temperature_2m_min"),
            rainChanceMax: firstNumber("precipitation_probability_max").map { Int($0.rounded()) },
            rainSumMm: firstNumber("precipitation_sum"),
            uvMax: firstNumber("uv_index_max"),
            sunrise: clock("sunrise"),
            sunset: clock("sunset"),
            hours: hours,
            fetchedAt: fetchedAt)
    }
}
