import Foundation
import Darwin
import TermIMSCore

// herdr (https://github.com/ogulcancelik/herdr) is a tmux-style agent
// multiplexer that runs *inside* a host terminal. All its panes share the
// host terminal's single pty, so the host's focused-tab process tree only ever
// shows the `herdr` client — it cannot tell us which program is in the focused
// pane. herdr instead exposes an authoritative local socket API (newline-
// delimited JSON-RPC over an AF_UNIX socket). We ask it directly which program
// runs in ITS focused pane.
//
// Wire facts (from herdr's API schema, protocol 17):
//   - API socket: $XDG_CONFIG_HOME/herdr/herdr.sock, else ~/.config/herdr/herdr.sock
//     (named sessions live under .../herdr/sessions/<name>/herdr.sock).
//   - Framing: one request line, one response line, each `<json>\n`.
//   - `pane.current` / `pane.process_info` with empty params → focused pane.
enum HerdrClient {
    /// Snapshot of herdr's currently focused pane for rule matching + change
    /// detection. Nil when no reachable server / focused pane is found.
    struct FocusedPane {
        /// Stable id (`w1:p9`); used to detect intra-herdr tab/pane switches.
        let paneID: String?
        /// herdr agent label (`claude`, `cursor`, `pi`, …) when detected.
        let agent: String?
        /// Pane / agent title as herdr reports it (often includes OSC 2 glyphs
        /// like `✳ …`). Prefer this over the host terminal's window title,
        /// which typically just says `herdr`.
        let title: String?
        /// Process-name candidates for Process Name rules: agent label first,
        /// then foreground process names / argv0 basenames.
        let candidates: [String]

        /// Compact fingerprint for poll-based change detection.
        /// Title is intentionally omitted: agents like Claude Code animate the
        /// pane title (braille spinner), which would re-resolve every poll tick.
        /// Pane / agent / process set is enough to catch real focus changes.
        var fingerprint: String {
            let procs = candidates.joined(separator: ",")
            return "\(paneID ?? "")|\(agent ?? "")|\(procs)"
        }
    }

    /// Authoritative view of herdr's focused pane, or nil when unreachable.
    static func focusedPane(tabCwd: String?) -> FocusedPane? {
        guard let path = socketPath(tabCwd: tabCwd) else { return nil }

        var paneID: String?
        var agent: String?
        var title: String?
        var candidates: [String] = []

        if let cur = request(socketPath: path,
                             line: #"{"id":"termims-cur","method":"pane.current","params":{}}"#),
           let root = try? JSONSerialization.jsonObject(with: cur),
           (root as? [String: Any])?["error"] == nil {
            var ids: [String] = []
            collectStringValues(root, key: "pane_id", into: &ids)
            paneID = ids.first

            var agents: [String] = []
            collectStringValues(root, key: "agent", into: &agents)
            agent = agents.first
            if let agent { candidates.append(agent) }

            // Prefer the glyph-bearing title so Claude-style title rules still
            // match; fall back to the stripped form.
            var titles: [String] = []
            collectStringValues(root, key: "terminal_title", into: &titles)
            if titles.isEmpty {
                collectStringValues(root, key: "terminal_title_stripped", into: &titles)
            }
            title = titles.first
        }

        if let info = request(socketPath: path,
                              line: #"{"id":"termims-proc","method":"pane.process_info","params":{}}"#),
           let names = processNames(fromReplyJSON: info) {
            candidates.append(contentsOf: names)
        }

        var seen = Set<String>()
        let unique = candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
        // A reachable pane.current with only an id (idle shell, no agent) is
        // still useful — return an empty-candidate snapshot so the caller can
        // stop matching host-side `herdr` and fall through to terminal default.
        if unique.isEmpty && paneID == nil && title == nil { return nil }
        return FocusedPane(paneID: paneID, agent: agent, title: title, candidates: unique)
    }

    // MARK: - Socket discovery

    private static var configBase: String {
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty { return xdg + "/herdr" }
        return NSHomeDirectory() + "/.config/herdr"
    }

    private static func socketPath(forSession session: String?) -> String {
        guard let session, !session.isEmpty else { return configBase + "/herdr.sock" }
        return configBase + "/sessions/" + session + "/herdr.sock"
    }

    /// Socket of the session hosted by the *focused* terminal tab.
    ///
    /// herdr runs one server per session and each tracks a single focused
    /// pane, so asking the wrong session reports a pane the user is not
    /// looking at. `tabCwd` is what the terminal reports for its focused tab;
    /// a client inherits the cwd of the shell that launched it, which is what
    /// tells the sessions apart. Returns nil when the client cannot be
    /// identified, so the caller holds instead of guessing.
    static func socketPath(tabCwd: String?) -> String? {
        let fm = FileManager.default
        var clients = runningClients()

        func resolve(_ candidates: [HerdrSession.Client]) -> String? {
            guard let client = HerdrSession.select(clients: candidates, tabCwd: tabCwd) else { return nil }
            let path = socketPath(forSession: client.session)
            return fm.fileExists(atPath: path) ? path : nil
        }

        // The launch cwd is already in hand — try it before paying for a
        // socket round trip per session.
        if let path = resolve(clients) { return path }

        // Still undecided. Ask each session for its focused pane's cwd: herdr
        // forwards that to the host terminal, so a tab hosting herdr usually
        // reports the pane's directory rather than the client's launch one.
        if clients.count > 1, let tabCwd, !tabCwd.isEmpty {
            clients = clients.map { client in
                let path = socketPath(forSession: client.session)
                guard fm.fileExists(atPath: path) else { return client }
                return HerdrSession.Client(pid: client.pid,
                                           session: client.session,
                                           cwd: client.cwd,
                                           paneCwd: focusedPaneCwd(socketPath: path))
            }
            if let path = resolve(clients) { return path }
        }
        // No client resolved. A single socket on disk is still unambiguous;
        // several are not.
        if clients.isEmpty {
            let defaultSocket = socketPath(forSession: nil)
            let named = ((try? fm.contentsOfDirectory(atPath: configBase + "/sessions")) ?? [])
                .map { socketPath(forSession: $0) }
                .filter { fm.fileExists(atPath: $0) }
            let all = (fm.fileExists(atPath: defaultSocket) ? [defaultSocket] : []) + named
            if all.count == 1 { return all[0] }
        }
        return nil
    }


    /// Working directory of a session's focused pane. Used to tell sessions
    /// apart when their launch directories cannot.
    private static func focusedPaneCwd(socketPath path: String) -> String? {
        guard let data = request(socketPath: path,
                                 line: #"{"id":"termims-cwd","method":"pane.current","params":{}}"#),
              let root = try? JSONSerialization.jsonObject(with: data),
              (root as? [String: Any])?["error"] == nil else { return nil }
        var cwds: [String] = []
        collectStringValues(root, key: "cwd", into: &cwds)
        return CanonicalPath.of(cwds.first)
    }

    /// Live herdr *clients* — the in-terminal processes. The headless server
    /// has no controlling tty and is skipped: it cannot say which session the
    /// user is looking at.
    static func runningClients() -> [HerdrSession.Client] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return [] }
        let actual = size / MemoryLayout<kinfo_proc>.stride

        var clients: [HerdrSession.Client] = []
        for i in 0..<actual {
            let kp = procs[i]
            let comm = withUnsafePointer(to: kp.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard comm == "herdr" else { continue }
            let pid = kp.kp_proc.p_pid
            guard let argv = processArgv(pid) else { continue }
            // A process with no controlling terminal reports NODEV (-1), not 0.
            let tdev = kp.kp_eproc.e_tdev
            let hasTty = tdev != 0 && tdev != -1
            guard HerdrSession.isClient(argv: argv, hasControllingTty: hasTty) else { continue }
            clients.append(HerdrSession.Client(pid: pid,
                                               session: HerdrSession.name(fromArgv: argv),
                                               cwd: processCWD(pid)))
        }
        return clients
    }

    private static func processCWD(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let raw = withUnsafePointer(to: info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return CanonicalPath.of(raw)
    }

    private static func processArgv(_ pid: Int32) -> [String]? {
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMib, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: Int(argmax))
        var size = Int(argmax)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }

        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return nil }

        var cursor = MemoryLayout<Int32>.size
        while cursor < size && buf[cursor] != 0 { cursor += 1 }
        while cursor < size && buf[cursor] == 0 { cursor += 1 }

        var argv: [String] = []
        var parsed: Int32 = 0
        while parsed < argc && cursor < size {
            let start = cursor
            while cursor < size && buf[cursor] != 0 { cursor += 1 }
            if cursor > start, let s = String(bytes: buf[start..<cursor], encoding: .utf8) {
                argv.append(s)
            }
            cursor += 1
            parsed += 1
        }
        return argv.isEmpty ? nil : argv
    }

    // MARK: - Request / response (single newline-delimited line each way)

    private static func request(socketPath: String, line: String, timeout: TimeInterval = 0.4) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < capacity else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { c in
                for (i, b) in pathBytes.enumerated() { c[i] = CChar(bitPattern: b) }
                c[pathBytes.count] = 0
            }
        }

        var tv = timeval(tv_sec: Int(timeout),
                         tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        var payload = Array(line.utf8)
        payload.append(0x0A)  // '\n'
        let sent = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == payload.count else { return nil }

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count < 1_000_000 {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(0x0A) { break }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Response parsing

    private static func processNames(fromReplyJSON data: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let obj = root as? [String: Any], obj["error"] != nil { return nil }
        var names: [String] = []
        collectForegroundProcessNames(root, into: &names)
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique
    }

    private static func collectStringValues(_ node: Any, key: String, into out: inout [String]) {
        if let dict = node as? [String: Any] {
            for (k, value) in dict {
                if k == key, let s = value as? String, !s.isEmpty { out.append(s) }
                collectStringValues(value, key: key, into: &out)
            }
        } else if let arr = node as? [Any] {
            for value in arr { collectStringValues(value, key: key, into: &out) }
        }
    }

    private static func collectForegroundProcessNames(_ node: Any, into names: inout [String]) {
        if let dict = node as? [String: Any] {
            if let procs = dict["foreground_processes"] as? [[String: Any]] {
                for p in procs {
                    if let name = p["name"] as? String, !name.isEmpty {
                        names.append(name)
                    }
                    if let argv0 = p["argv0"] as? String {
                        let base = (argv0 as NSString).lastPathComponent
                        if !base.isEmpty { names.append(base) }
                    }
                }
            }
            for (_, value) in dict { collectForegroundProcessNames(value, into: &names) }
        } else if let arr = node as? [Any] {
            for value in arr { collectForegroundProcessNames(value, into: &names) }
        }
    }
}
