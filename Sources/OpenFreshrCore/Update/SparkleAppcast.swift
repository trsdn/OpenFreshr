import Foundation

/// Reads a Sparkle appcast and extracts the newest advertised version.
///
/// This is the one place the previously-unused ``HTTPFetching`` protocol is
/// wired in. Everything here is **defensive**: an unreachable feed, a feed that
/// is not XML, or a feed that carries no usable version all resolve to `nil`, so
/// the update resolver can turn them into *unbekannt* rather than an invented
/// version. It never throws to the caller.
///
/// Both shapes real appcasts use are handled — the Sparkle fields as child
/// elements of `<item>` *and* as attributes on the `<enclosure>`:
///
/// ```xml
/// <item>
///   <sparkle:shortVersionString>2.0</sparkle:shortVersionString>
///   <sparkle:version>2000</sparkle:version>
///   <enclosure url="…" sparkle:shortVersionString="2.0" sparkle:version="2000"/>
/// </item>
/// ```
public enum SparkleAppcast {

    /// Fetch `feedURL` through `fetcher` and return the newest advertised version,
    /// or `nil` on any failure.
    ///
    /// Only `https` feeds are attempted. A plaintext feed could be rewritten in
    /// transit to advertise any version it likes; that only drives a display
    /// here rather than an install, but a version claim still steers what the
    /// user is told to update, so it is not worth accepting.
    public static func fetchNewestVersion(
        feedURL: String,
        using fetcher: any HTTPFetching
    ) async -> String? {
        guard let url = URL(string: feedURL),
            url.scheme?.lowercased() == "https"
        else {
            return nil
        }
        guard let data = try? await fetcher.data(from: url) else { return nil }
        return newestVersion(from: data)
    }

    /// Parse appcast `data` and return the newest advertised marketing version,
    /// or `nil` when the document cannot be parsed or carries no version.
    ///
    /// The marketing string (`sparkle:shortVersionString`) is preferred over the
    /// build string (`sparkle:version`) because it is what a bundle's
    /// `CFBundleShortVersionString` is compared against. Across several items the
    /// newest is chosen with ``VersionComparator``; when two cannot be ordered
    /// the earlier (feeds are conventionally newest-first) is kept.
    public static func newestVersion(from data: Data) -> String? {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else { return nil }

        let candidates = delegate.items.compactMap { $0.short ?? $0.build }
        guard var best = candidates.first else { return nil }
        for candidate in candidates.dropFirst() {
            if VersionComparator.compare(installed: best, available: candidate) == .older {
                best = candidate
            }
        }
        return best
    }

    /// Collects `<item>` version data. Deliberately tolerant: unknown elements are
    /// ignored and missing fields simply stay `nil`.
    private final class Delegate: NSObject, XMLParserDelegate {
        private(set) var items: [(short: String?, build: String?)] = []

        private var inItem = false
        private var shortVersion: String?
        private var buildVersion: String?
        private var currentElement: String?
        private var currentText = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            let name = elementName.lowercased()
            if name == "item" {
                inItem = true
                shortVersion = nil
                buildVersion = nil
                currentElement = nil
                currentText = ""
                return
            }
            guard inItem else { return }

            currentElement = name
            currentText = ""

            // The enclosure often carries the versions as attributes instead of
            // as child elements; take whichever appears first.
            if name == "enclosure" {
                for (key, value) in attributeDict {
                    let key = key.lowercased()
                    if key.hasSuffix("shortversionstring") {
                        shortVersion = shortVersion ?? trimmedNonEmpty(value)
                    } else if key.hasSuffix("version") {
                        buildVersion = buildVersion ?? trimmedNonEmpty(value)
                    }
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inItem, currentElement != nil else { return }
            currentText += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let name = elementName.lowercased()
            if name == "item" {
                items.append((short: shortVersion, build: buildVersion))
                inItem = false
                currentElement = nil
                return
            }
            guard inItem else { return }

            if name.hasSuffix("shortversionstring") {
                shortVersion = shortVersion ?? trimmedNonEmpty(currentText)
            } else if name.hasSuffix("version") {
                buildVersion = buildVersion ?? trimmedNonEmpty(currentText)
            }
            currentElement = nil
            currentText = ""
        }

        private func trimmedNonEmpty(_ string: String) -> String? {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
