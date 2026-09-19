import Foundation

/// Named deep-analysis prompts for the Coach composer.
///
/// THE CHIP SHOWS THE NAME, THE MODEL GETS THE BRIEF. A chip reads "Analyse my sleep"; tapping it puts
/// that name in the transcript and sends `instruction` in its place on the wire (see
/// `AICoachEngine.send(_:wireText:)`), so the thread stays readable while the model gets a precise,
/// multi-step brief over the data context it already receives.
struct CoachAnalysisPreset: Identifiable, Equatable {
    let id: String
    /// SF Symbol for the chip.
    let symbol: String
    /// The short name shown on the chip and in the transcript. Localized.
    let title: String
    /// The full brief sent to the model. English on purpose: the coach already answers in the app
    /// language, and one brief keeps the analyses identical across languages.
    let instruction: String

    static let all: [CoachAnalysisPreset] = [
        CoachAnalysisPreset(
            id: "sleep", symbol: "moon.zzz",
            title: String(localized: "Analyse my sleep"),
            instruction: """
            Analyse my sleep in depth. Cover: last night versus my personal sleep need (hours vs needed, \
            sleep debt), stage composition (deep, REM, light, awake) against my own 30-day norm, sleep \
            timing and consistency (bedtime and wake drift over the last 7 nights), overnight HRV, resting \
            HR and respiratory rate versus baseline, and the bedroom climate if available. Name the one or \
            two factors that most limited my sleep, then give concrete actions for tonight with times \
            (bedtime target, wind-down start, caffeine/meal cut-off, room temperature).
            """),
        CoachAnalysisPreset(
            id: "energy", symbol: "bolt.heart",
            title: String(localized: "My energy budget today"),
            instruction: """
            Analyse my current state right now and how much energy I can still invest today. Use my \
            charge/recovery, last night's sleep and sleep debt, HRV and resting HR versus baseline, stress \
            now and over today, effort so far versus today's recommended target, the time of day, my \
            planned bedtime and today's weather. Answer: 1) a one-line verdict on my state; 2) how much \
            physical load is left (effort still available, which zone and how long); 3) how much \
            demanding cognitive work is sensible and in which time windows; 4) when I should stop pushing \
            today. Be specific with numbers and clock times.
            """),
        CoachAnalysisPreset(
            id: "charge", symbol: "battery.50percent",
            title: String(localized: "Why is my charge like this?"),
            instruction: """
            Explain today's charge/recovery score from its inputs: HRV, resting HR, respiratory rate, skin \
            temperature and sleep, each compared with my own baseline, and which ones pulled it up or \
            down the most. Relate it to the last 3 days of effort, stress and sleep. End with what I can \
            do today and tonight to raise tomorrow's charge.
            """),
        CoachAnalysisPreset(
            id: "load", symbol: "figure.run",
            title: String(localized: "Check my training load"),
            instruction: """
            Assess my training load: the last 7 days of effort versus the 4-week average (acute versus \
            chronic), how the load was spread over the days, heart-rate zone distribution of recent \
            workouts, and whether recovery kept up (charge, HRV and resting-HR trend). Say whether I am \
            under-training, balanced or at risk of overreaching, and suggest the next 3 days of training \
            (type, zone, duration).
            """),
        CoachAnalysisPreset(
            id: "stress", symbol: "waveform.path.ecg",
            title: String(localized: "Analyse my stress"),
            instruction: """
            Analyse my stress: today's stress by hour and the peaks, how today compares with my usual \
            days, the HRV trend, and what the peaks coincided with (workouts, time of day, sleep, \
            journal entries if any). Give me concrete, timed recovery actions for the rest of the day \
            (breathing, breaks, movement) and one habit to try this week.
            """),
        CoachAnalysisPreset(
            id: "week", symbol: "calendar",
            title: String(localized: "Review my week"),
            instruction: """
            Review my last 7 days against the 7 before: charge, effort, sleep (duration, need, \
            consistency), HRV, resting HR, stress, workouts and water. Give the three most important \
            insights, what went well, what to change, and a short plan for the coming week.
            """),
        CoachAnalysisPreset(
            id: "evening", symbol: "sunset",
            title: String(localized: "Plan my evening"),
            instruction: """
            Plan my evening for the best possible sleep tonight: a bedtime from my sleep need, sleep debt \
            and wake time, when to start winding down, cut-offs for caffeine, food, screens and hard \
            exercise given what I did today, and the bedroom temperature and humidity to aim for. Give it \
            as a short timeline with clock times.
            """),
        CoachAnalysisPreset(
            id: "fitness", symbol: "chart.line.uptrend.xyaxis",
            title: String(localized: "Track my fitness progress"),
            instruction: """
            Assess my fitness progress over the last 90 days: VO2max, fitness age, resting HR, HRV and \
            training volume trends. What is improving, what is stalling, and what should my training \
            focus on over the next 4 weeks to keep improving?
            """),
    ]
}
