import Foundation
import Testing
@testable import MoePeek

struct VisionCPUFallbackTests {
    @Test func acceleratedSuccessDoesNotRunCPU() throws {
        var cpuAttempts = 0

        let result = try VisionCPUFallback.run<String>(
            isCancelled: { false },
            accelerated: { "gpu" },
            cpuFallback: {
                cpuAttempts += 1
                return "cpu"
            }
        )

        #expect(result == "gpu")
        #expect(cpuAttempts == 0)
    }

    @Test func acceleratedFailureRetriesCPUOnce() throws {
        var cpuAttempts = 0

        let result: String = try VisionCPUFallback.run(
            isCancelled: { false },
            accelerated: { () throws -> String in throw FallbackTestError.accelerated },
            cpuFallback: { () throws -> String in
                cpuAttempts += 1
                return "cpu"
            }
        )

        #expect(result == "cpu")
        #expect(cpuAttempts == 1)
    }

    @Test func cancellationDoesNotRetryOnCPU() {
        var cpuAttempts = 0

        #expect(throws: CancellationError.self) {
            let _: String = try VisionCPUFallback.run(
                isCancelled: { false },
                accelerated: { () throws -> String in throw CancellationError() },
                cpuFallback: { () throws -> String in
                    cpuAttempts += 1
                    return "cpu"
                }
            )
        }

        #expect(cpuAttempts == 0)
    }

    @Test func cpuFailurePreservesBothErrors() {
        do {
            _ = try VisionCPUFallback.run(
                isCancelled: { false },
                accelerated: { throw FallbackTestError.accelerated },
                cpuFallback: { throw FallbackTestError.cpu }
            )
            Issue.record("Expected the CPU fallback to fail")
        } catch let error as AppleOCREngine.RecognitionError {
            guard case .cpuFallbackFailed(let primary, let fallback) = error else {
                Issue.record("Expected both accelerated and CPU errors")
                return
            }
            #expect(primary.localizedDescription == "Accelerated failure")
            #expect(fallback.localizedDescription == "CPU failure")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private enum FallbackTestError: LocalizedError {
    case accelerated
    case cpu

    var errorDescription: String? {
        switch self {
        case .accelerated: "Accelerated failure"
        case .cpu: "CPU failure"
        }
    }
}
