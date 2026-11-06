import Foundation

/// A process that keeps a drive busy.
public struct Holder: Sendable, Hashable {
    public let pid: Int32
    public let name: String

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }
}

public enum EjectResult: Sendable, Equatable {
    case ejected
    /// The drive is in use. `holders` may be empty when macOS did not say who.
    case busy(holders: [Holder], message: String)
    case failed(message: String)
}

public enum Ejector {
    /// Unmounts every volume on the drive and ejects the device, the same thing
    /// Finder does. With `force`, volumes are unmounted even while files are open.
    public static func eject(_ drive: Drive, force: Bool = false) -> EjectResult {
        if force {
            let u = DiskUtil.run(["unmountDisk", "force", drive.id])
            if u.status != 0 { return .failed(message: clean(u.output)) }
        }
        let r = DiskUtil.run(["eject", drive.id])
        if r.status == 0 { return .ejected }
        var holders = Set(parseDissenters(r.output))
        for v in drive.volumes { holders.formUnion(openFileHolders(on: v.mountPoint.path)) }
        let looksBusy = !holders.isEmpty || r.output.localizedCaseInsensitiveContains("dissent")
            || r.output.localizedCaseInsensitiveContains("busy") || r.output.localizedCaseInsensitiveContains("in use")
        let list = holders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return looksBusy ? .busy(holders: list, message: clean(r.output)) : .failed(message: clean(r.output))
    }

    /// Processes with files open on the file system mounted at `mountPoint`.
    /// lsof only sees this user's processes; diskutil names system ones.
    public static func openFileHolders(on mountPoint: String) -> [Holder] {
        let r = Shell.run("/usr/sbin/lsof", ["-w", "-F", "pc", "--", mountPoint])
        return parseLsof(r.output)
    }

    /// Parses `lsof -F pc` output: "p123" starts a process, "cName" names it.
    public static func parseLsof(_ text: String) -> [Holder] {
        var out: [Holder] = []
        var seen = Set<Int32>()
        var pid: Int32?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value)
            case "c":
                if let p = pid, !seen.contains(p) {
                    seen.insert(p)
                    out.append(Holder(pid: p, name: value))
                }
            default: break
            }
        }
        return out
    }

    /// Parses diskutil's "dissented by PID 1234 (/path/to/program)" lines.
    public static func parseDissenters(_ text: String) -> [Holder] {
        let pattern = #"PID (\d+) \(([^)]*)\)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [Holder] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let pid = Int32(ns.substring(with: m.range(at: 1))) else { continue }
            let path = ns.substring(with: m.range(at: 2))
            let name = path.isEmpty ? "PID \(pid)" : (path as NSString).lastPathComponent
            if !out.contains(where: { $0.pid == pid }) { out.append(Holder(pid: pid, name: name)) }
        }
        return out
    }

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
