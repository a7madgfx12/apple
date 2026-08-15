import Foundation

enum QuranError: LocalizedError {
    case indexUnavailable
    case networkUnavailableAndNotCached
    case pageOutOfRange

    var errorDescription: String? {
        switch self {
        case .indexUnavailable: return "تعذر تحميل فهرس السور."
        case .networkUnavailableAndNotCached: return "هذه السورة غير متاحة بدون اتصال بالإنترنت بعد. يرجى الاتصال بالإنترنت مرة واحدة لتنزيلها."
        case .pageOutOfRange: return "رقم الصفحة غير صحيح."
        }
    }
}

/// Provides Quran content sourced from surahquran.com, per product requirement.
///
/// Architecture: the 114-Surah index (number, Arabic name, ayah count) is bundled locally
/// as static metadata (Resources/Quran/surah_index.json) — this is standard, unchanging
/// Mushaf metadata, not Quran *text*, so it is safe to ship offline. The actual Quran
/// *text* (surah content) is fetched from the source on first access and cached to
/// disk (Application Support/Quran/) so subsequent reads — including offline reads — use
/// the cached copy, satisfying the "offline after installation" requirement without
/// requiring us to hand-transcribe 6,236 ayahs into this repository.
///
/// Known source limitation: surahquran.com does not expose a per-Mushaf-page reading
/// endpoint (its `/page/N.html` URLs are tafsir pages indexed by *surah* number, not
/// Mushaf page). To keep the Page Index feature usable, `ayahs(forPage:)` maps the
/// requested Mushaf page number to its containing Surah — using each Surah's standard
/// starting page in the 604-page Uthmani Mushaf (King Fahd Complex layout), bundled as
/// `startPage` in `surah_index.json` — and returns that Surah's full (accurately fetched)
/// text. This shows the correct real content for that area of the Mushaf; it is not a
/// pixel-exact single printed page, which the approved source cannot provide — see README.
final class QuranService {
    private let session: URLSession
    private let cacheDirectory: URL
    private let sourceBaseURL = URL(string: "https://surahquran.com")!

    private(set) var surahIndex: [SurahInfo] = []

    init(session: URLSession = .shared) {
        self.session = session
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.cacheDirectory = appSupport.appendingPathComponent("Quran", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        loadBundledIndex()
    }

    private func loadBundledIndex() {
        guard let url = Bundle.main.url(forResource: "surah_index", withExtension: "json", subdirectory: "Quran") ??
                Bundle.main.url(forResource: "surah_index", withExtension: "json") else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        surahIndex = (try? JSONDecoder().decode([SurahInfo].self, from: data)) ?? []
    }

    func surah(number: Int) -> SurahInfo? {
        surahIndex.first { $0.number == number }
    }

    /// Fetches (or returns cached) ayahs for a whole surah, reading from surahquran.com and
    /// caching to disk. Falls back to the disk cache when offline.
    func ayahs(forSurah surahNumber: Int) async throws -> [Ayah] {
        let cacheFile = cacheDirectory.appendingPathComponent("surah_\(surahNumber).json")
        if let cached = try? Data(contentsOf: cacheFile), let ayahs = try? JSONDecoder().decode([Ayah].self, from: cached), !ayahs.isEmpty {
            return ayahs
        }
        let ayahs = try await fetchSurahFromSource(surahNumber)
        guard !ayahs.isEmpty else { throw QuranError.networkUnavailableAndNotCached }
        if let encoded = try? JSONEncoder().encode(ayahs) {
            try? encoded.write(to: cacheFile)
        }
        return ayahs
    }

    /// surahquran.com has no per-Mushaf-page endpoint, so this resolves the page to its
    /// containing Surah (via `startPage`) and returns that Surah's real fetched text —
    /// see type-level documentation.
    func ayahs(forPage pageNumber: Int) async throws -> [Ayah] {
        guard let surah = surahForPage(pageNumber) else { throw QuranError.pageOutOfRange }
        return try await ayahs(forSurah: surah.number)
    }

    /// Returns the Surah whose printed range contains `pageNumber`, using each Surah's
    /// `startPage` (sorted ascending — the next Surah's startPage is this Surah's end).
    func surahForPage(_ pageNumber: Int) -> SurahInfo? {
        let sorted = surahIndex.sorted { $0.startPage < $1.startPage }
        guard !sorted.isEmpty, pageNumber >= 1 else { return nil }
        var result: SurahInfo?
        for surah in sorted where surah.startPage <= pageNumber {
            result = surah
        }
        return result ?? sorted.first
    }

    // MARK: - Source fetching (surahquran.com)

    private func fetchSurahFromSource(_ surahNumber: Int) async throws -> [Ayah] {
        let url = sourceBaseURL.appendingPathComponent("\(surahNumber).html")
        let (data, _) = try await session.data(from: url)
        return try QuranHTMLParser.parseAyahs(html: data, surahNumber: surahNumber)
    }
}

/// HTML scraper for surahquran.com's ayah markup, verified against the site's actual output.
///
/// Ayah text on a surah page (e.g. surahquran.com/1.html) is rendered as plain text inside a
/// single container `<div>`, interspersed with `<b>` tags (bold emphasis on some words — not
/// semantically meaningful) and `<br>` line breaks, with each ayah terminated by a
/// `<label>(N)</label>` marker containing its ayah number. There is no `data-ayah` attribute
/// or per-ayah wrapper element. This parser locates the region starting at
/// `id="reading"` and extracts the text preceding each `<label>(N)</label>` marker as that
/// ayah's content.
enum QuranHTMLParser {
    static func parseAyahs(html data: Data, surahNumber: Int?) throws -> [Ayah] {
        guard let html = String(data: data, encoding: .utf8) else { return [] }

        guard let readingMarkerRange = html.range(of: "id=\"reading\"") else { return [] }
        var region = String(html[readingMarkerRange.upperBound...])
        if let endRange = region.range(of: "id=\"surah\"") ?? region.range(of: "id=\"mp3\"") {
            region = String(region[..<endRange.lowerBound])
        }

        guard let labelRegex = try? NSRegularExpression(pattern: #"<label>\((\d+)\)</label>"#) else { return [] }
        let nsRegion = region as NSString
        let matches = labelRegex.matches(in: region, range: NSRange(location: 0, length: nsRegion.length))

        var results: [Ayah] = []
        var cursor = 0
        for match in matches {
            guard let numberRange = Range(match.range(at: 1), in: region) else { continue }
            let ayahNumber = Int(region[numberRange]) ?? 0
            let rawSegment = nsRegion.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let text = stripTags(rawSegment)
            if !text.isEmpty {
                results.append(Ayah(surahNumber: surahNumber ?? 0, ayahNumber: ayahNumber, text: text))
            }
            cursor = match.range.location + match.range.length
        }
        return results
    }

    private static func stripTags(_ segment: String) -> String {
        var result = segment.replacingOccurrences(of: "<br>", with: " ")
        result = result.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
