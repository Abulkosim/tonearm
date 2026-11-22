// Asks a running app whether its main thread answers, for scripts/live-launch.sh:
//
//   ping <pid> [timeout seconds, default 5]
//   ok 12.3 ms (answered -1708)
//
// It sends the app an Apple Event no app handles ('TnRm'/'ping'). AppKit takes Apple Events
// off the main thread's run loop and answers one it has no handler for with "not handled"
// (errAEEventNotHandled, -1708). So any answer means the main thread turned its run loop
// within the timeout. A hung main thread can't answer, and the send times out (-1712).
//
// Before sending, it asks macOS whether this process may send Apple Events to the app at
// all, without prompting. Otherwise a missing permission would look like a hang, or a
// consent prompt nobody clicks would.
//
// Exit 0: answered. 1: no answer within the timeout. 2: anything else (no such process,
// not permitted, bad arguments), with the reason on stderr.
import CoreServices
import Foundation

func fourCC(_ text: String) -> FourCharCode {
    text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
}

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("ping: \(message)\n".utf8))
    exit(code)
}

let args = CommandLine.arguments
guard args.count == 2 || args.count == 3, let pid = pid_t(args[1]) else {
    fail("usage: ping <pid> [timeout seconds]", 2)
}
let timeout = args.count == 3 ? TimeInterval(args[2]) ?? 0 : 5
guard timeout > 0 else { fail("bad timeout \(args[2])", 2) }

let target = NSAppleEventDescriptor(processIdentifier: pid)
let event = NSAppleEventDescriptor.appleEvent(
    withEventClass: fourCC("TnRm"), eventID: fourCC("ping"), targetDescriptor: target,
    returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))

guard let address = target.aeDesc else { fail("no address for pid \(pid)", 2) }
let permission = AEDeterminePermissionToAutomateTarget(
    address, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
switch Int(permission) {
case Int(noErr): break
case Int(procNotFound): fail("no process \(pid)", 2)
case Int(errAEEventNotPermitted): fail("not permitted to send Apple Events to pid \(pid) (-1743)", 2)
case Int(errAEEventWouldRequireUserConsent): fail("sending Apple Events to pid \(pid) needs consent (-1744)", 2)
default: fail("permission check for pid \(pid) failed: \(permission)", 2)
}

let start = DispatchTime.now().uptimeNanoseconds
var status = 0
do {
    let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
    status = Int(reply.paramDescriptor(forKeyword: fourCC("errn"))?.int32Value ?? 0)
} catch let error as NSError {
    status = error.code
}
let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

switch status {
case Int(noErr), Int(errAEEventNotHandled):
    print(String(format: "ok %.1f ms", ms) + " (answered \(status))")
case Int(errAETimeout):
    fail("no answer from pid \(pid) in \(Int(ms)) ms: its main thread is not running its run loop", 1)
default:
    fail("sending to pid \(pid) failed with \(status) after \(Int(ms)) ms", 2)
}
