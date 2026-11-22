// Prints what the kernel has charged a process so far, for scripts/idle-cost.sh:
//
//   rusage <pid>
//   cpu_ns=<user + system> idle_wakeups=<n> interrupt_wakeups=<n>
//
// The numbers come from proc_pid_rusage, the call Activity Monitor and top use. Its times
// are in Mach ticks, which are nanoseconds on Intel but not on Apple silicon, so they are
// converted with mach_timebase_info. Build: swiftc -O -o rusage Tools/IdleCost/rusage.swift
import Darwin

guard CommandLine.arguments.count == 2, let pid = pid_t(CommandLine.arguments[1]) else {
    fputs("usage: rusage <pid>\n", stderr)
    exit(2)
}

var info = rusage_info_v4()
let status = withUnsafeMutablePointer(to: &info) { pointer in
    pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
}
guard status == 0 else {
    fputs("rusage: proc_pid_rusage(\(pid)) failed: \(String(cString: strerror(errno)))\n", stderr)
    exit(1)
}

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let ticks = info.ri_user_time + info.ri_system_time
let nanoseconds = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
print("cpu_ns=\(UInt64(nanoseconds)) idle_wakeups=\(info.ri_pkg_idle_wkups) interrupt_wakeups=\(info.ri_interrupt_wkups)")
