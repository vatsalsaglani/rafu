import Foundation
import RafuCore

// The hook helper: `rafu-agent-events <claude|codex|cursor> [spoolDirectory]`
// and, for Claude Code's `PermissionRequest` only,
// `rafu-agent-events claude <spoolDirectory> --answer`.
//
// An observer must never delay or change the agent's decision. In the normal
// mode a 1 s alarm ends the process whatever it is doing; every path exits 0;
// nothing is printed to stdout or stderr. The answer mode waits for Rafu's
// answer for up to `AgentAnswerChannel.waitSeconds` and prints a decision only
// when the person chose one in Rafu; its alarm is the last resort. See
// `AgentEventHelper`.
signal(SIGALRM) { _ in _exit(0) }
if AgentEventHelper.isAnswerMode(CommandLine.arguments) {
    alarm(UInt32(AgentAnswerChannel.alarmSeconds))
} else {
    alarm(1)
}
AgentEventHelper.run(arguments: CommandLine.arguments)
exit(0)
