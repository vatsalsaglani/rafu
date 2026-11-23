import Foundation
import RafuObjCSupport
import Testing

@Suite("Objective-C exception guard")
struct MeetingObjCExceptionGuardTests {
    @Test("An NSException in the block becomes a thrown error, and the process continues")
    func exceptionBecomesError() throws {
        var thrown: (any Error)?
        do {
            try RafuObjCExceptionGuard.perform {
                NSException(
                    name: .internalInconsistencyException,
                    reason: "required condition is false: format.sampleRate == hwFormat.sampleRate"
                ).raise()
            }
        } catch {
            thrown = error
        }
        let error = try #require(thrown as NSError?)
        #expect(error.domain == RafuObjCExceptionErrorDomain)
        #expect(error.domain == "RafuObjCException")
        #expect(error.code == 1)
        #expect(
            error.userInfo[RafuObjCExceptionNameKey] as? String
                == NSExceptionName.internalInconsistencyException.rawValue)
        #expect(
            (error.userInfo[RafuObjCExceptionReasonKey] as? String)?.contains("hwFormat") == true)

        // The process is still running: a second guarded call works.
        var ran = false
        try RafuObjCExceptionGuard.perform { ran = true }
        #expect(ran)
    }

    @Test("A clean block runs once and returns normally")
    func cleanBlock() throws {
        var count = 0
        try RafuObjCExceptionGuard.perform { count += 1 }
        #expect(count == 1)
    }
}
