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
    var summary: String {
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

enum WeatherService {

    /// Frankfurt am Main. A constant — see the note at the top on why this is not the device's location.
    static let latitude = 50.1109
    static let longitude = 8.6821

    /// How long a reading stays fresh. Weather moves, but not in five minutes, and the tile is redrawn
    /// on every appearance — without this it would make a request each time Today came back.
    static let staleAfter: TimeInterval = 30 * 60

    private static let cacheKey = "weather.now"

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

    /// Fetch, unless the cached reading is still fresh. Nil when there is nothing to show.
    @discardableResult
    static func refresh() async -> WeatherNow? {
        if let cached { return cached }
        guard let url = URL(string:
            "https://api.open-meteo.com/v1/forecast"
            + "?latitude=\(latitude)&longitude=\(longitude)"
            + "&current=temperature_2m,weather_code,uv_index"
            + "&daily=uv_index_max&forecast_days=1&timezone=auto")
        else { return lastKnown }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let current = root["current"] as? [String: Any]
        else { return lastKnown }

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
}
