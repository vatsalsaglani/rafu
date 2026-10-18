import Foundation

// The hook helper: `rafu-agent-events <claude|codex|cursor> [spoolDirectory]`.
//
// An observer must never delay or change the agent's decision. A 1 s alarm
// ends the process whatever it is doing; every path exits 0; nothing is
// printed to stdout or stderr. See `AgentEventHelper`.
signal(SIGALRM) { _ in _exit(0) }
alarm(1)
AgentEventHelper.run(arguments: CommandLine.arguments)
exit(0)
