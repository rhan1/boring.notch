import Darwin
import Foundation

/// A Unix-domain socket that lets the `pam_facemac` module ask FaceMac to
/// recognise the user — this is how `sudo` gets face unlock.
///
/// Protocol: the client sends one line `AUTH <service> <user>`, FaceMac scans
/// and answers `OK` or `NO`, then closes. Only root may connect (PAM runs
/// inside sudo as root); the module in turn checks that the socket is served
/// by the signed FaceMac app before trusting the answer.
public final class AuthServer {
    public static var socketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FaceMac/auth.sock")
    }

    /// Asked on the main queue; must call the completion exactly once.
    public var verify: ((_ reason: String, _ completion: @escaping (Bool) -> Void) -> Void)?
    /// Called on the main queue when the client hangs up before an answer
    /// (sudo was cancelled or answered another way).
    public var cancel: (() -> Void)?

    private var listenFD: Int32 = -1
    /// Inode of the socket file we bound, so stop() never removes a newer
    /// instance's socket (an old copy quitting during a reinstall did exactly that).
    private var boundInode: ino_t = 0
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.facemac.auth")

    public init() {}

    public func start() {
        guard listenFD < 0 else { return }
        let url = Self.socketURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        unlink(url.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Log.app.error("auth socket: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            Log.app.error("auth bind/listen: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return
        }
        chmod(url.path, 0o600)
        var info = stat()
        if stat(url.path, &info) == 0 { boundInode = info.st_ino }
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        Log.app.info("auth server listening")
    }

    public func stop() {
        source?.cancel()
        source = nil
        listenFD = -1
        var info = stat()
        if boundInode != 0, stat(Self.socketURL.path, &info) == 0, info.st_ino == boundInode {
            unlink(Self.socketURL.path)
        }
        boundInode = 0
    }

    private func accept() {
        let client = Darwin.accept(listenFD, nil, nil)
        guard client >= 0 else { return }

        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == 0 else {
            Log.app.info("auth: rejected non-root client uid=\(uid, privacy: .public)")
            close(client)
            return
        }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = read(client, &buffer, buffer.count - 1)
        let line = count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.first == "AUTH" else {
            close(client)
            return
        }
        let reason = parts.dropFirst().joined(separator: " ")

        let request = Request(fd: client)
        // Watch for the client going away while the camera is still looking.
        let hangup = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        hangup.setEventHandler { [weak self] in
            var byte: UInt8 = 0
            guard read(client, &byte, 1) <= 0 else { return }
            hangup.cancel()
            DispatchQueue.main.async {
                guard request.finish() else { return }
                Log.app.info("auth: client hung up")
                self?.cancel?()
                close(client)
            }
        }
        request.hangup = hangup
        hangup.resume()

        DispatchQueue.main.async { [weak self] in
            guard let verify = self?.verify else {
                if request.finish() { Self.reply(client, false) }
                return
            }
            verify(reason) { ok in
                guard request.finish() else { return }
                Self.reply(client, ok)
            }
        }
    }

    /// One pending request; `finish()` is true exactly once.
    private final class Request {
        let fd: Int32
        var hangup: DispatchSourceRead?
        private var done = false
        init(fd: Int32) { self.fd = fd }
        func finish() -> Bool {
            guard !done else { return false }
            done = true
            hangup?.cancel()
            return true
        }
    }

    private static func reply(_ client: Int32, _ ok: Bool) {
        let answer = ok ? "OK\n" : "NO\n"
        _ = answer.withCString { write(client, $0, strlen($0)) }
        close(client)
    }
}
