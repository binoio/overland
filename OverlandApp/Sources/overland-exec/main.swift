// overland-exec: reset the inherited signal state, then exec the command.
//
// Processes started through macOS's administrator authorization trampoline
// arrive with SIGINT/SIGTERM blocked in their signal mask. A blocked signal is
// never delivered, so neither gpclient's shutdown handler nor a shell trap can
// ever see the supervisor's interrupt. The mask and dispositions survive exec,
// which is why this has to happen in a helper that runs in the child itself.
//
// Usage: overland-exec <executable> [args…]
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

let args = Swift.CommandLine.arguments
guard args.count >= 2 else {
    // Glibc's `stderr` is a mutable global that strict concurrency rejects; fd 2 is the same thing.
    let usage = "usage: overland-exec <executable> [args…]\n"
    _ = usage.withCString { write(2, $0, strlen($0)) }
    exit(64)
}

var empty = sigset_t()
sigemptyset(&empty)
sigprocmask(SIG_SETMASK, &empty, nil)

for sig in 1..<Int32(NSIG) where sig != SIGKILL && sig != SIGSTOP {
    signal(sig, SIG_DFL)
}

let argv: [UnsafeMutablePointer<CChar>?] = args.dropFirst().map { strdup($0) } + [nil]
execv(args[1], argv)
perror("overland-exec: execv failed")
exit(126)
