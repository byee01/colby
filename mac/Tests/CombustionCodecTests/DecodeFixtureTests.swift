import Testing
@testable import CombustionCodec

/// Every fixture file under advertisement/, probe_status/ and node_status/ decodes to its expected value or error.
@Suite("Decode fixtures")
struct DecodeFixtureTests {
    @Test("fixture folders are populated")
    func foldersArePopulated() {
        for (folder, minimum) in [("advertisement", 50), ("probe_status", 60), ("node_status", 30), ("uart_frames", 100)] {
            let files = Fixtures.fileNames(folder)
            #expect(files.count >= minimum, "\(folder) has only \(files.count) files")
            #expect(Fixtures.load(folder).count == files.count, "\(folder): some fixture files do not parse")
        }
    }

    @Test("advertisement", arguments: Fixtures.load("advertisement"))
    func advertisement(_ fixture: Fixture) {
        check(fixture) { Render.advertisement(try decodeAdvertisement(fixture.hex)) }
    }

    @Test("probe status", arguments: Fixtures.load("probe_status"))
    func probeStatus(_ fixture: Fixture) {
        check(fixture) { Render.status(try decodeProbeStatus(fixture.hex)) }
    }

    @Test("node status", arguments: Fixtures.load("node_status"))
    func nodeStatus(_ fixture: Fixture) {
        check(fixture) { Render.nodeStatus(try decodeNodeProbeStatus(fixture.hex)) }
    }

    private func check(_ fixture: Fixture, _ decode: () throws -> JSONValue) {
        let comment = Comment(rawValue: "\(fixture.testDescription): \(fixture.root["description"].string ?? "")")
        do {
            let actual = try decode()
            #expect(fixture.expectedError.isNull, "expected an error but decoded \(actual)", sourceLocation: #_sourceLocation)
            if !fixture.expected.isNull {
                let difference = firstDifference(expected: fixture.expected, actual: actual)
                #expect(difference == nil, comment.appending(difference))
            }
        } catch let error as CodecError {
            #expect(!fixture.expectedError.isNull, "unexpected \(error)")
            let difference = firstDifference(expected: fixture.expectedError, actual: Render.error(error), subset: true)
            #expect(difference == nil, comment.appending(difference))
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }
}

extension Comment {
    func appending(_ text: String?) -> Comment { Comment(rawValue: "\(rawValue) -> \(text ?? "")") }
}
