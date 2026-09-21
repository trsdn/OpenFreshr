import Testing

@testable import OpenFreshrCore

/// Exhaustive tests for the version comparator — the component the whole
/// "never a false update" guarantee rests on. The `nil` (→ *unbekannt*) cases
/// get as much attention as the ordered ones, because a wrong `older` is the
/// one outcome that can trigger an unnecessary replacement.
struct VersionComparatorTests {

    // MARK: - Ordered comparisons (an update exists / does not)

    @Test
    func plainDottedNumericOrdersAsExpected() {
        #expect(VersionComparator.compare(installed: "1.2.3", available: "1.2.4") == .older)
        #expect(VersionComparator.compare(installed: "1.2.3", available: "1.2.3") == .same)
        #expect(VersionComparator.compare(installed: "1.2.4", available: "1.2.3") == .newer)
        #expect(VersionComparator.compare(installed: "1.9.0", available: "2.0.0") == .older)
    }

    @Test
    func shorterVersionIsZeroPadded() {
        #expect(VersionComparator.compare(installed: "1.2", available: "1.2.0") == .same)
        #expect(VersionComparator.compare(installed: "1.2.0.0", available: "1.2") == .same)
        #expect(VersionComparator.compare(installed: "1.2.3.4", available: "1.2.3") == .newer)
        #expect(VersionComparator.compare(installed: "1.2.3", available: "1.2.3.1") == .older)
    }

    @Test
    func leadingZerosAreNumericNotLexical() {
        #expect(VersionComparator.compare(installed: "02.08.02.61", available: "2.8.2.61") == .same)
        #expect(VersionComparator.compare(installed: "1.02", available: "1.10") == .older)
    }

    @Test
    func dateLikeVersionsCompareNumerically() {
        #expect(VersionComparator.compare(installed: "2026.8.1", available: "2026.8.2") == .older)
        #expect(VersionComparator.compare(installed: "2026.8.1", available: "2026.8.1") == .same)
        #expect(VersionComparator.compare(installed: "2027.1.0", available: "2026.12.9") == .newer)
    }

    @Test
    func buildAndPrereleaseSeparatorsAreFolded() {
        // ` (456)`, `-457`, `_458`, `+459` all normalise to a fourth numeric field.
        #expect(VersionComparator.compare(installed: "1.2.3 (456)", available: "1.2.3-457") == .older)
        #expect(VersionComparator.compare(installed: "1.2.3_2", available: "1.2.3+1") == .newer)
        #expect(VersionComparator.compare(installed: "v1.2.3", available: "1.2.4") == .older)
        #expect(VersionComparator.compare(installed: "1.2.3", available: "v1.2.3") == .same)
    }

    @Test
    func homebrewCommaRevisionSeparatesAMarketingTie() {
        // Marketing versions equal, numeric revisions differ → the revision decides.
        #expect(VersionComparator.compare(installed: "5.7.3,2320", available: "5.7.3,2321") == .older)
        #expect(VersionComparator.compare(installed: "5.7.3,2320", available: "5.7.3,2320") == .same)
        #expect(VersionComparator.compare(installed: "5.7.3,2322", available: "5.7.3,2320") == .newer)
    }

    @Test
    func aRevisionOnlyOnOneSideDoesNotManufactureAnUpdate() {
        // Installed "5.7.3" vs cask "5.7.3,2320": marketing tie, only one side has a
        // revision → up to date, NOT an update. This is the real `alfred` case.
        #expect(VersionComparator.compare(installed: "5.7.3", available: "5.7.3,2320") == .same)
        #expect(VersionComparator.compare(installed: "5.7.3,2320", available: "5.7.3") == .same)
    }

    @Test
    func realWorldOnePasswordCaseIsAMinorUpdate() {
        #expect(VersionComparator.compare(installed: "8.11.22", available: "8.12.34") == .older)
        #expect(VersionComparator.isMajorChange(from: "8.11.22", to: "8.12.34") == false)
    }

    // MARK: - The unknown cases — must be nil, never an update

    @Test
    func prereleaseQualifierOnAMarketingTieIsUnknown() {
        // Neither direction is safe to guess when only a qualifier separates them.
        #expect(VersionComparator.compare(installed: "1.2.3", available: "1.2.3-beta") == nil)
        #expect(VersionComparator.compare(installed: "1.2.3-beta", available: "1.2.3") == nil)
        #expect(VersionComparator.compare(installed: "1.2.3-rc1", available: "1.2.3-rc2") == nil)
    }

    @Test
    func aClearMarketingDifferenceStillOrdersDespiteAQualifier() {
        // The qualifier only blocks a *tie*; a real numeric difference still orders.
        #expect(VersionComparator.compare(installed: "1.2.3-beta", available: "1.2.4") == .older)
        #expect(VersionComparator.compare(installed: "1.3.0-beta", available: "1.2.9") == .newer)
    }

    @Test
    func latestPlaceholderIsUnknown() {
        #expect(VersionComparator.compare(installed: "latest", available: "1.2.3") == nil)
        #expect(VersionComparator.compare(installed: "1.2.3", available: "latest") == nil)
        #expect(VersionComparator.compare(installed: "1.2.3", available: ":latest") == nil)
    }

    @Test
    func emptyOrNonNumericVersionsAreUnknown() {
        #expect(VersionComparator.compare(installed: "", available: "1.2.3") == nil)
        #expect(VersionComparator.compare(installed: "1.2.3", available: "") == nil)
        #expect(VersionComparator.compare(installed: "   ", available: "1.2.3") == nil)
        #expect(VersionComparator.compare(installed: "nightly", available: "1.2.3") == nil)
        #expect(VersionComparator.compare(installed: "1.2.3", available: "unknown") == nil)
    }

    @Test
    func gitShaRevisionIsDroppedNotMisordered() {
        // The post-comma git SHA parses to nothing; both reduce to a marketing tie
        // with no usable revision → same, never a spurious update.
        #expect(VersionComparator.compare(installed: "1.40609.0,f65e386", available: "1.40609.0,a1b2c3d") == .same)
        #expect(VersionComparator.compare(installed: "1.40609.0,f65e386", available: "1.40610.0,a1b2c3d") == .older)
    }

    // MARK: - Major-change detection

    @Test
    func majorChangeIsFirstComponentOnly() {
        #expect(VersionComparator.isMajorChange(from: "1.2.3", to: "2.0.0") == true)
        #expect(VersionComparator.isMajorChange(from: "1.2.3", to: "1.9.9") == false)
        #expect(VersionComparator.isMajorChange(from: "2.0.0", to: "1.9.9") == true)
        #expect(VersionComparator.isMajorChange(from: "2026.8.1", to: "2027.1.0") == true)
    }

    @Test
    func majorChangeIsFalseWhenEitherSideIsUnparseable() {
        // A major upgrade is only ever *asserted* about two versions that compare.
        #expect(VersionComparator.isMajorChange(from: "latest", to: "2.0.0") == false)
        #expect(VersionComparator.isMajorChange(from: "1.2.3", to: "") == false)
        #expect(VersionComparator.isMajorChange(from: "abc", to: "def") == false)
    }
}
