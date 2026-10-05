#!/usr/bin/env python3
"""Enables JIT for Amethyst on an iOS 26+ device from this Mac, over USB.

    tools/amethyst-jit.py [--device UDID] [--bundle ID] [--no-launch]

Launches Amethyst (development-signed, so it can be debugged: tools/amethyst-sign.sh),
attaches Xcode's lldb to it and serves the JIT26 breakpoint protocol that StikDebug's
universal script serves on the device (Amethyst's UniversalJIT26.js and its extension):

  brk #0x69                 legacy probe; once the extension is loaded, maps x0 bytes RX
  brk #0xf00d, x16 = 0      detach
               x16 = 1      prepare region (x0 = address or 0 to allocate RX, x1 = size)
               x16 = 2      script for the on-device debugger (ignored: implemented here)
               x16 = 3      detach after the next brk #0x69 if x0 != 0
               x16 = 4      prepare a small region for patching (rewrite its bytes)

Preparing a region writes one byte to each 16 KB page through the debugger, which is what
lets the app map it executable under TXM. Start this before tapping Play in Amethyst; it
exits once Amethyst asks the debugger to detach (or keeps serving with "debug always
attached JIT" on).
"""
import argparse, os, subprocess, sys, time

sys.path.insert(0, subprocess.check_output(["xcrun", "lldb", "-P"], text=True).strip())
import lldb  # noqa: E402

PAGE = 0x4000
DEFAULT_DEVICE = "00008142-001538391E80C01C"


def log(msg):
    print(f"[amethyst-jit] {msg}", flush=True)


class Jit:
    def __init__(self, process, ci):
        self.process = process
        self.ci = ci
        self.extension = False      # UniversalJIT26Extension.js sent: brk #0x69 maps memory
        self.detach_after_first = False
        self.detached = False
        self.no_detach = False
        self.on_crash = None
        self.guarded = None
        self.pending_detach = False
        self.guard_commit = False
        self.breaks = []
        self.break_names = {}

    def reg(self, frame, name):
        return frame.FindRegister(name).GetValueAsUnsigned()

    def set_reg(self, frame, name, value):
        # (SBValue writes to registers fail over a device connection; the command works)
        res = lldb.SBCommandReturnObject()
        self.process.SetSelectedThread(frame.GetThread())
        self.ci.HandleCommand(f"register write {name} {value:#x}", res)
        if not res.Succeeded():
            raise SystemExit(f"writing {name}: {res.GetError().strip()}")

    def packet(self, text):
        """Sends a raw gdb-remote packet to debugserver; returns its response."""
        res = lldb.SBCommandReturnObject()
        self.ci.HandleCommand(f'process plugin packet send "{text}"', res)
        for line in res.GetOutput().splitlines():
            if line.strip().startswith("response:"):
                return line.split(":", 1)[1].strip()
        raise SystemExit(f"packet {text}: {res.GetError().strip() or res.GetOutput().strip()}")

    def prepare(self, addr, size):
        # Raw packets, exactly as StikDebug sends them: the region must be allocated by
        # debugserver itself (_M), and each page written by it, for TXM to let it execute.
        if addr == 0:
            resp = self.packet(f"_M{size:x},rx")
            if not resp or resp.startswith("E"):
                log(f"allocating {size:#x} bytes RX failed: {resp}")
                return 0
            addr = int(resp, 16)
        t = time.time()
        pages = (size + PAGE - 1) // PAGE
        for i in range(pages):
            resp = self.packet(f"M{addr + i * PAGE:x},1:69")
            if resp != "OK":
                log(f"touching page {addr + i * PAGE:#x} failed: {resp}")
                return 0
            if i % 2048 == 2047:
                log(f"  {i + 1}/{pages} pages ({time.time() - t:.1f}s)")
            if time.time() - t > 60:
                # normally 5 s: something is wrong; never leave the app stopped
                log("preparing the region is taking too long: giving up")
                self.detach()
                return 0
        log(f"prepared {addr:#x} + {size:#x} ({pages} pages, {time.time() - t:.1f}s)")
        return addr

    def handle(self, thread):
        frame = thread.GetFrameAtIndex(0)
        pc = frame.GetPC()
        err = lldb.SBError()
        insn = self.process.ReadUnsignedFromMemory(pc, 4, err)
        if err.Fail() or (insn & 0xFFE0001F) != 0xD4200000:
            return False                    # not a brk: let the app have the signal/exception
        imm = (insn >> 5) & 0xFFFF
        x0, x1, x16 = self.reg(frame, "x0"), self.reg(frame, "x1"), self.reg(frame, "x16")
        if imm not in (0x69, 0xF00D):
            log(f"unhandled brk #{imm:#x} at {pc:#x}")
            return False
        ret = self.serve(imm, x0, x1, x16)
        # x0 first, pc last (and checked): writing pc refreshes lldb's view of the thread
        if ret is not None:
            self.set_reg(frame, "x0", ret)
        self.set_reg(frame, "pc", pc + 4)
        res = lldb.SBCommandReturnObject()
        self.ci.HandleCommand("register read x0 pc", res)
        got = dict(l.split("=")[0].split()[-1:] + [l.split("=")[1].split()[0]] for l in res.GetOutput().splitlines() if "=" in l)
        if int(got.get("pc", "0"), 16) != pc + 4 or (ret is not None and int(got.get("x0", "0"), 16) != ret):
            raise SystemExit(f"register writes did not stick: {res.GetOutput().strip()}")
        return True

    def serve(self, imm, x0, x1, x16):
        """Handles one JIT26 request; returns the new x0, or None to leave it."""
        err = lldb.SBError()
        if imm == 0x69:
            if not self.extension:
                log("legacy probe: answering as the universal script")
                return 0x690000E0
            log(f"map {x0:#x} bytes")
            addr = self.prepare(0, x0)
            if addr and self.guard_commit:
                self.guard(addr, x0)
            for off, name in self.breaks:
                res = lldb.SBCommandReturnObject()
                self.ci.HandleCommand("image list -b -h libjvm.dylib", res)
                import re
                base = int(re.search(r"0x[0-9a-fA-F]+", res.GetOutput()).group(0), 16)
                self.ci.HandleCommand(f"breakpoint set -a {base + off:#x}", res)
                self.break_names[base + off] = name
                log(f"breakpoint on {name} at {base + off:#x}")
            if self.no_detach and not self.breaks:      # watch what the app does with its memory
                for fn in ("mmap", "munmap", "vm_protect", "mach_vm_protect", "vm_remap", "mach_vm_remap"):
                    res = lldb.SBCommandReturnObject()
                    self.ci.HandleCommand(f"breakpoint set -n {fn} -s libsystem_kernel.dylib", res)
            if self.detach_after_first:
                self.detach()
            return addr

        if x16 == 0:
            self.detach()
        elif x16 == 1:
            if x0 or x1:
                return self.prepare(x0, x1)
        elif x16 == 2:
            log(f"JIT script received ({x1} bytes): extension enabled")
            self.extension = True
        elif x16 == 3:
            self.detach_after_first = x0 != 0
            log(f"detach after first brk #0x69: {self.detach_after_first}")
        elif x16 == 4:
            data = self.packet(f"m{x0:x},{x1:x}")
            resp = self.packet(f"M{x0:x},{x1:x}:{data}")
            log(f"prepared {x0:#x} + {x1:#x} for patching: {resp}")
        else:
            log(f"unknown JIT26 command {x16}")
        return None

    def guard(self, addr, size):
        """iOS 27: HotSpot commits its code cache with mprotect(RW) on the RX mapping, which
        now takes effect and leaves the code unexecutable. Skip mprotect calls on the region
        (they report success; the RW alias is where the JVM writes), and stay attached until
        all of it has been committed (-XX:InitialCodeCacheSize = the region: one call)."""
        res = lldb.SBCommandReturnObject()
        self.ci.HandleCommand("breakpoint set -n __mprotect -s libsystem_kernel.dylib", res)
        self.guard_bp = int(res.GetOutput().split("Breakpoint ")[1].split(":")[0])
        self.guarded = (addr, addr + size)
        self.committed = 0
        log(f"guarding {addr:#x} + {size:#x} against mprotect (breakpoint {self.guard_bp})")

    def on_mprotect(self, thread):
        """A stop at the __mprotect breakpoint; True if it was ours."""
        if not self.guarded or thread.GetStopReasonDataAtIndex(0) != self.guard_bp:
            return False
        f = thread.GetFrameAtIndex(0)
        a, n, prot = (f.FindRegister(r).GetValueAsUnsigned() for r in ("x0", "x1", "x2"))
        lo, hi = self.guarded
        if a < hi and a + n > lo:
            self.set_reg(f, "x0", 0)
            self.set_reg(f, "pc", f.FindRegister("lr").GetValueAsUnsigned())
            self.committed += min(a + n, hi) - max(a, lo)
            log(f"skipped mprotect({a:#x}, {n:#x}, {prot}) on the JIT region ({self.committed:#x} of {hi - lo:#x} committed)")
            if self.committed >= hi - lo:
                self.guarded = None
                res = lldb.SBCommandReturnObject()
                self.ci.HandleCommand(f"breakpoint delete {self.guard_bp}", res)
                if self.pending_detach:
                    self.detach()
        return True

    def detach(self):
        if self.guarded:
            log("asked to detach: staying until the JIT region is committed")
            self.pending_detach = True
            return
        if self.no_detach:
            log("asked to detach: staying attached (--no-detach)")
            return
        log("detaching")
        self.detached = True


def coredevice_id(udid):
    """lldb's device commands take CoreDevice identifiers, not UDIDs."""
    import json, tempfile
    with tempfile.NamedTemporaryFile(suffix=".json") as f:
        subprocess.run(["xcrun", "devicectl", "list", "devices", "--json-output", f.name],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for d in json.load(open(f.name))["result"]["devices"]:
            if udid in (d["identifier"], d["hardwareProperties"].get("udid")):
                return d["identifier"]
    raise SystemExit(f"no device {udid}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", default=DEFAULT_DEVICE)
    ap.add_argument("--bundle", default="ca.bomberfish.amethyst")
    ap.add_argument("--name", default="AngelAuraAmethyst", help="process name")
    ap.add_argument("--no-launch", action="store_true", help="attach to the running app")
    ap.add_argument("--play", metavar="PROFILE", help="press Play on this profile (no one at the device needed)")
    ap.add_argument("--eval", action="append", default=[], metavar="EXPR",
                    help="evaluate an Objective-C expression on the main thread first (repeatable)")
    ap.add_argument("--no-detach", action="store_true",
                    help="stay attached when asked to detach, and describe crashes (debugging)")
    ap.add_argument("--guard-commit", action="store_true",
                    help="skip the JVM's mprotect(RW) of its JIT region (Java 8 built before "
                         "angelauramc-openjdk-build f03a5a05; also pass -XX:InitialCodeCacheSize=128m)")
    ap.add_argument("--break", action="append", default=[], metavar="SYMBOL",
                    help="with --no-detach: log each call of SYMBOL (arguments, callers)")
    ap.add_argument("--timeout", type=float, default=300,
                    help="detach and exit after this many seconds whatever is happening (so the "
                         "app is never left stopped under a debugger)")
    ap.add_argument("--play-delay", type=float, default=12, help="seconds to let the launcher load first")
    args = ap.parse_args()
    start = time.time()

    def watchdog():
        # last resort if lldb itself blocks: dropping the debugger connection makes
        # debugserver let go of the app
        time.sleep(args.timeout + 60)
        log("watchdog: exiting")
        os._exit(3)
    import threading
    threading.Thread(target=watchdog, daemon=True).start()

    # over Wi-Fi the 8192 page writes take minutes instead of seconds
    info = subprocess.run(["xcrun", "devicectl", "device", "info", "details", "--device", args.device],
                          capture_output=True, text=True).stdout
    if "Transport Type: wired" not in info:
        log("warning: the device is not connected over USB; preparing JIT memory will be very slow (plug it in)")
    if not args.no_launch:
        log(f"launching {args.bundle}")
        subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--device", args.device,
                        "--terminate-existing", args.bundle], check=True, stdout=subprocess.DEVNULL)
        time.sleep(4)

    # Everything is event driven: over a device connection lldb's commands return before the
    # process has changed state, and acting before its stop event arrives fails (resumes time
    # out, register writes are refused).
    debugger = lldb.SBDebugger.Create()
    debugger.SetAsync(True)
    ci = debugger.GetCommandInterpreter()
    listener = debugger.GetListener()
    event = lldb.SBEvent()

    def cmd(c, check=True):
        res = lldb.SBCommandReturnObject()
        ci.HandleCommand(c, res)
        if check and not res.Succeeded():
            raise SystemExit(f"lldb: {c}: {res.GetError().strip()}")
        return res.GetOutput()

    def wait_state(timeout=None):
        """The process's next settled state (a stop that was not auto-restarted, or the end)."""
        end = None if timeout is None else time.time() + timeout
        while end is None or time.time() < end:
            if listener.WaitForEvent(1, event) and lldb.SBProcess.EventIsProcessEvent(event):
                state = lldb.SBProcess.GetStateFromEvent(event)
                if state == lldb.eStateStopped and lldb.SBProcess.GetRestartedFromEvent(event):
                    continue
                if state in (lldb.eStateStopped, lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed):
                    return state
        return None

    # Without symbols for this iOS build cached (Xcode's iOS DeviceSupport), lldb would read
    # every system library out of the device's memory.
    cmd("settings set target.memory-module-load-level minimal")
    cmd("settings set plugin.process.gdb-remote.packet-timeout 10")   # a packet that never answers must not hang the app
    cmd(f"device select {coredevice_id(args.device)}", check=False)   # connects, yet reports failure
    log("attaching")
    cmd(f"device process attach -n {args.name}")
    if wait_state(120) != lldb.eStateStopped:
        raise SystemExit("attach failed")
    process = debugger.GetSelectedTarget().GetProcess()
    # The JVM uses signals itself; never stop for them.
    for sig in ("SIGUSR1", "SIGUSR2", "SIGPIPE") if args.no_detach else \
            ("SIGSEGV", "SIGBUS", "SIGILL", "SIGFPE", "SIGUSR1", "SIGUSR2", "SIGPIPE", "SIGSYS"):
        cmd(f"process handle {sig} -p true -s false -n false")
    log(f"attached to pid {process.GetProcessID()}; tap Play in Amethyst")

    if args.play or args.eval:
        if process.Continue().Fail():
            raise SystemExit("resume failed")
        time.sleep(args.play_delay)
        process.SendAsyncInterrupt()
        if wait_state(30) != lldb.eStateStopped:
            raise SystemExit("could not interrupt the app")
        process.SetSelectedThread(process.GetThreadAtIndex(0))   # the main thread
        debugger.SetAsync(False)
        cmd("expr --timeout 60000000 -l objc -- @import UIKit")
        for e in args.eval:
            log(f"eval {e}: {cmd(f'expr --timeout 20000000 -l objc -O -- {e}', check=False).strip()}")
        debugger.SetAsync(True)
        if not args.play:
            process.Detach()
            return 0

    if args.play:
        # Press Play from inside the app: on the main thread, set the profile field and call
        # the button's action (LauncherNavigationController -performInstallOrShowDetails:).
        name = args.play.replace("\\", "\\\\").replace('"', '\\"')
        # (and keep the screen awake while the app is in front: no one is there to unlock it)
        expr = ('[[UIApplication sharedApplication] setIdleTimerDisabled:YES]; id nav = nil; '
                'for (id vc in (id)[[[[UIApplication sharedApplication] keyWindow] rootViewController] viewControllers]) '
                '  if ((BOOL)[vc isKindOfClass:(Class)NSClassFromString(@"LauncherNavigationController")]) nav = vc; '
                f'[(id)[nav valueForKey:@"versionTextField"] setText:@"{name}"]; '
                '(void)[nav performInstallOrShowDetails:nil]; '
                '(id)[[nav valueForKey:@"versionTextField"] text]')
        debugger.SetAsync(False)
        out = cmd(f"expr --timeout 20000000 -l objc -O -- {expr}")
        debugger.SetAsync(True)
        log(f"pressed Play on {out.strip()}")

    deadline = start + args.timeout
    jit = Jit(process, ci)
    jit.no_detach = args.no_detach
    jit.guard_commit = args.guard_commit
    if args.__dict__["break"]:
        # by address once libjvm is loaded (minimal module loading leaves lldb without its
        # symbols): offsets from the local copy of the library
        lib = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "ios-amethyst", "jre8fix", "lib", "server", "libjvm.dylib")
        out = subprocess.check_output(["nm", "-C", "-arch", "arm64", lib], text=True)
        jit.breaks = []
        for sym in args.__dict__["break"]:
            hits = [l for l in out.splitlines() if l.split(" ", 2)[-1].startswith(sym)]
            if not hits:
                raise SystemExit(f"no symbol {sym} in {lib}")
            jit.breaks.append((int(hits[0].split()[0], 16), hits[0].split(" ", 2)[-1]))
        jit.heap_sym = int([l for l in out.splitlines() if l.endswith(" CodeCache::_heap")][0].split()[0], 16)
    last_pc, repeats = None, 0
    while not jit.detached:
        err = process.Continue()
        if err.Fail():
            log(f"resume failed: {err}")
            return 1
        state = None
        while state is None:
            state = wait_state(1)
            if state is None and time.time() > deadline:
                log(f"timed out after {args.timeout:.0f}s: detaching")
                process.SendAsyncInterrupt()
                wait_state(10)
                process.Detach()
                return 1
        if state != lldb.eStateStopped:
            log(f"process ended ({lldb.SBDebugger.StateAsCString(state)}, status {process.GetExitStatus()})")
            return 1
        handled = False
        for thread in process:
            if thread.GetStopReason() == lldb.eStopReasonBreakpoint and jit.on_mprotect(thread):
                handled = True
                continue
            if thread.GetStopReason() == lldb.eStopReasonBreakpoint and thread.GetFrameAtIndex(0).GetPC() in jit.break_names:
                f = thread.GetFrameAtIndex(0)
                name = jit.break_names[f.GetPC()]
                x = [f.FindRegister(f"x{i}").GetValueAsUnsigned() for i in range(4)]
                if "handle_full" in name:
                    # the code heap's bookkeeping (CodeCache::_heap -> CodeHeap)
                    res = lldb.SBCommandReturnObject()
                    ci.HandleCommand("image list -h libjvm.dylib", res)
                    import re
                    base = int(re.search(r"0x[0-9a-fA-F]+", res.GetOutput()).group(0), 16)
                    err = lldb.SBError()
                    heap = process.ReadPointerFromMemory(base + jit.heap_sym, err)
                    log(f"CodeCache::_heap = {heap:#x}: {cmd(f'x/32gx {heap:#x}', check=False).strip()}")
                if "allocate" not in name or x[0] > 0x100000:
                    callers = " < ".join(hex(thread.GetFrameAtIndex(i).GetPC()) for i in range(1, min(8, thread.GetNumFrames())))
                    log(f"{name}: x0..x3 = {', '.join(hex(v) for v in x)}  [{callers}]")
                handled = True
                continue
            if thread.GetStopReason() in (lldb.eStopReasonException, lldb.eStopReasonSignal, lldb.eStopReasonBreakpoint):
                pc = thread.GetFrameAtIndex(0).GetPC()
                repeats = repeats + 1 if pc == last_pc else 0
                last_pc = pc
                if repeats > 20 and not args.no_detach:
                    raise SystemExit(f"stuck at {pc:#x}: {thread.GetStopDescription(200)}")
                handled |= jit.handle(thread)
        if not handled:
            for t in process:
                if t.GetStopReason() not in (lldb.eStopReasonNone, lldb.eStopReasonInvalid):
                    log(f"passing stop: thread {t.GetIndexID()} {t.GetStopDescription(200)}")
                    if args.no_detach and t.GetStopReason() == lldb.eStopReasonBreakpoint:
                        f = t.GetFrameAtIndex(0)
                        regs = " ".join(f"{r}={f.FindRegister(r).GetValueAsUnsigned():#x}" for r in ("x0", "x1", "x2", "x3"))
                        callers = " < ".join(str(t.GetFrameAtIndex(i).GetSymbol().GetName() or hex(t.GetFrameAtIndex(i).GetPC()))
                                             for i in range(1, min(6, t.GetNumFrames())))
                        log(f"  {f.GetFunctionName()} {regs}  [{callers}]")
                    elif args.no_detach:
                        process.SetSelectedThread(t)
                        pc = t.GetFrameAtIndex(0).GetPC()
                        for c in (f"memory region {pc:#x}", f"x/4wx {pc:#x}", "register read pc lr x16 x17"):
                            log(f"{c}: {cmd(c, check=False).strip()}")
                        if jit.on_crash:
                            jit.on_crash(t, pc)
    process.Detach()
    log("detached; JIT stays enabled for this run of Amethyst")
    return 0


if __name__ == "__main__":
    sys.exit(main())
