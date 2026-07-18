import CryptoKit
import Foundation
import TypeEngine

public struct LanguageArtifactAuditResult: Sendable {
    public let failures: [String]
    public let generations: [String: String]
    public let sourceAgeDays: [String: Int]
    public let verifiedFileCount: Int

    public var passed: Bool { failures.isEmpty }
}

/// Deterministic manifest gate for the shipping IS/EN language cohort.
/// The scorecard supplies the git commit date as `referenceDate`, so freshness
/// does not depend on the wall clock and repeated runs at one commit agree.
public enum LanguageArtifactAudit {
    public static let schema = "lyklabord.language-data-manifest.v1"

    public static func run(repoRoot: URL, referenceDate: Date) -> LanguageArtifactAuditResult {
        var failures: [String] = []
        var generations: [String: String] = [:]
        var sourceAges: [String: Int] = [:]
        var verifiedFiles = 0

        for language in ["is", "en"] {
            let directory = repoRoot.appendingPathComponent("data/\(language)")
            let manifestURL = directory.appendingPathComponent("LANGUAGE_DATA_MANIFEST.json")
            guard
                let data = try? Data(contentsOf: manifestURL),
                let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                failures.append("\(language): missing or malformed LANGUAGE_DATA_MANIFEST.json")
                continue
            }

            if manifest["schema"] as? String != schema {
                failures.append("\(language): unsupported manifest schema")
            }
            let generation = manifest["languageDataGeneration"] as? String ?? ""
            let fingerprint = manifest["generationFingerprint"] as? String ?? ""
            if generation.isEmpty || fingerprint.isEmpty || !generation.contains(fingerprint) {
                failures.append("\(language): generation does not carry its source fingerprint")
            } else {
                generations[language] = generation
            }

            let calibrationURL = directory.appendingPathComponent(
                "\(language)-calibration.json")
            do {
                let calibration = try LexiconCalibrationProfile(contentsOf: calibrationURL)
                if !calibration.isValid {
                    failures.append("\(language): invalid lexicon calibration profile")
                }
                if calibration.languageDataGeneration != generation {
                    failures.append("\(language): calibration generation does not match manifest")
                }
                if abs(calibration.addK - EngineConfig().addK) >= 1e-12 {
                    failures.append("\(language): calibration addK does not match shipping config")
                }
            } catch {
                failures.append("\(language): missing or malformed calibration profile")
            }

            let policy = manifest["freshnessPolicy"] as? [String: Any] ?? [:]
            let maxBuildAge = int(policy["maxSourceAgeAtBuildDays"])
            let maxCommitAge = int(policy["maxGenerationAgeAtCommitDays"])
            guard
                let sourceDate = date(manifest["sourceReferenceDate"] as? String),
                let builtDate = date(manifest["builtAt"] as? String),
                let maxBuildAge, let maxCommitAge
            else {
                failures.append("\(language): incomplete freshness policy/dates")
                continue
            }
            let buildAge = days(from: sourceDate, to: builtDate)
            let commitAge = days(from: sourceDate, to: referenceDate)
            sourceAges[language] = commitAge
            if buildAge < 0 || buildAge > maxBuildAge {
                failures.append(
                    "\(language): source was \(buildAge)d old at build (max \(maxBuildAge)d)")
            }
            if commitAge < 0 || commitAge > maxCommitAge {
                failures.append(
                    "\(language): generation is \(commitAge)d old at commit (max \(maxCommitAge)d)")
            }

            var records: [String: (bytes: Int, sha256: String)] = [:]
            collectFileRecords(manifest, key: nil, into: &records)
            let required = manifest["requiredShippingArtifacts"] as? [String] ?? []
            if required.isEmpty { failures.append("\(language): no required shipping artifacts") }
            for filename in required where records[filename] == nil {
                failures.append("\(language): required artifact \(filename) has no hash record")
            }
            for filename in records.keys.sorted() {
                guard let record = records[filename] else { continue }
                let url = directory.appendingPathComponent(filename)
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                    let size = values.fileSize
                else {
                    failures.append("\(language): missing file \(filename)")
                    continue
                }
                if size != record.bytes {
                    failures.append(
                        "\(language): \(filename) bytes \(size) != manifest \(record.bytes)")
                    continue
                }
                do {
                    let digest = try sha256(url)
                    if digest != record.sha256.lowercased() {
                        failures.append("\(language): \(filename) sha256 mismatch")
                    } else {
                        verifiedFiles += 1
                    }
                } catch {
                    failures.append("\(language): cannot hash \(filename): \(error)")
                }
            }
        }
        return LanguageArtifactAuditResult(
            failures: failures,
            generations: generations,
            sourceAgeDays: sourceAges,
            verifiedFileCount: verifiedFiles)
    }

    public static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func collectFileRecords(
        _ value: Any,
        key: String?,
        into records: inout [String: (bytes: Int, sha256: String)]
    ) {
        if let object = value as? [String: Any] {
            if let key, let bytes = int(object["bytes"]), let sha = object["sha256"] as? String {
                records[key] = (bytes, sha)
                return
            }
            for (childKey, child) in object {
                collectFileRecords(child, key: childKey, into: &records)
            }
        } else if let array = value as? [Any] {
            for child in array { collectFileRecords(child, key: nil, into: &records) }
        }
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func days(from start: Date, to end: Date) -> Int {
        Int(floor(end.timeIntervalSince(start) / 86_400))
    }
}
