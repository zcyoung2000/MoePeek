import Testing
@testable import MoePeek

struct OCRRecognitionLeaseTests {
    @Test func concurrentCapturesCannotClaimTheSameSlot() async {
        let slot = RecognitionSlot()
        let claims = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0 ..< 100 {
                group.addTask { slot.claim() }
            }
            var claims = 0
            for await claimed in group where claimed { claims += 1 }
            return claims
        }
        #expect(claims == 1)
    }

    @Test func cancellationBeforeStartPreventsALateOperationFromStarting() {
        let slot = RecognitionSlot()
        #expect(slot.claim())
        let lease = RecognitionLease(slot: slot)

        lease.releaseIfNotStarted()

        #expect(slot.claim())
        #expect(!lease.markStarted())
        lease.release()
        #expect(!slot.claim())
    }

    @Test func cancellationAfterStartKeepsTheSlotUntilVisionReturns() {
        let slot = RecognitionSlot()
        #expect(slot.claim())
        let lease = RecognitionLease(slot: slot)
        #expect(lease.markStarted())

        lease.releaseIfNotStarted()

        #expect(!slot.claim())
        lease.release()
        #expect(slot.claim())
    }

    @Test func completedLeaseCannotReleaseTheNextCapturesSlot() {
        let slot = RecognitionSlot()
        #expect(slot.claim())
        let lease = RecognitionLease(slot: slot)
        #expect(lease.markStarted())
        lease.release()
        #expect(slot.claim())

        lease.release()
        lease.releaseIfNotStarted()

        #expect(!slot.claim())
    }
}
