import Foundation

enum DelayedDiag {
    private static let lock = NSLock()
    private static var seq = 0

    static func log(_ message: String) {
        lock.lock()
        seq += 1
        let n = seq
        lock.unlock()
        let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
        print("DIAG#\(n) t=\(ms) th=\(pthread_mach_thread_np(pthread_self())) \(message)")
        fflush(stdout)
    }

    static func fsState(_ path: String) -> String {
        "ino=\(inode(path)) names=[\(xattrNames(path))] excl=\(excludeXattr(path))"
    }

    private static func inode(_ path: String) -> String {
        var st = stat()
        return stat(path, &st) == 0 ? String(st.st_ino) : "nostat"
    }

    private static func xattrNames(_ path: String) -> String {
        let size = listxattr(path, nil, 0, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard listxattr(path, &buf, size, 0) > 0 else { return "err" }
        return buf.split(separator: 0).map { chunk in
            String(cString: Array(chunk) + [0])
        }.joined(separator: ",")
    }

    private static func excludeXattr(_ path: String) -> String {
        let name = "com.apple.metadata:com_apple_backup_excludeItem"
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return "absent" }
        var buf = [UInt8](repeating: 0, count: size)
        guard getxattr(path, name, &buf, size, 0, 0) > 0 else { return "readerr" }
        return "present(" + buf.map { String(format: "%02x", $0) }.joined() + ")"
    }

    static func freshRead(_ path: String) -> String {
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        return String(describing: values?.isExcludedFromBackup)
    }
}
