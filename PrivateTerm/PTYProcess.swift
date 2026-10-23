import Foundation
import Darwin

/// Owns one local pseudoterminal. Network connections are made only by
/// commands the user runs inside the shell (for example /usr/bin/ssh).
/// All fd reads/writes/closure execute on ioQueue; no terminal bytes are logged.
final class PTYProcess {
    private let ioQueue = DispatchQueue(label: "PrivateTerm.PTY.IO")
    private var masterFD: Int32 = -1             // Access only on ioQueue after init.
    private var pendingInput = Data()            // Access only on ioQueue.
    private var readSource: DispatchSourceRead!
    private var writeSource: DispatchSourceWrite!
    private var writeSuspended = true
    private var readSuspended = true
    private var stopped = false
    private let childPID: pid_t

    var onOutput: ((Data) -> Void)?
    var onExit: (() -> Void)?

    init?(columns: Int, rows: Int) {
        var fd: Int32 = -1
        var pid: pid_t = 0
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let result = home.withCString { path in
            pt_spawn_shell(&fd, &pid, UInt16(clamping: columns), UInt16(clamping: rows), path)
        }
        guard result == 0, fd >= 0, pid > 0 else { return nil }
        childPID = pid
        masterFD = fd

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        // Begin reading only AFTER the caller has attached its output handler.

        // The write source stays suspended until input is queued.
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: ioQueue)
        writeSource.setEventHandler { [weak self] in self?.flushWrites() }

        // Reap the shell so we do not create zombie processes.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR { }
            DispatchQueue.main.async { [weak self] in self?.onExit?() }
        }
    }

    func beginReading() {
        ioQueue.async { [self] in
            guard !stopped, readSuspended else { return }
            readSuspended = false
            readSource.resume()
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        ioQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.pendingInput.append(data)
            if self.writeSuspended {
                self.writeSuspended = false
                self.writeSource.resume()
            }
        }
    }

    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        ioQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            _ = pt_resize(self.masterFD, UInt16(clamping: columns), UInt16(clamping: rows))
        }
    }

    func stop(terminateChild: Bool = true) {
        if terminateChild { _ = kill(childPID, SIGHUP) }
        ioQueue.async { [self] in
            guard !stopped else { return }
            stopped = true
            if readSuspended {
                readSource.resume()
                readSuspended = false
            }
            readSource.cancel()
            if writeSuspended {
                // Dispatch sources must not be cancelled while suspended.
                self.writeSource.resume()
                self.writeSuspended = false
            }
            self.writeSource.cancel()
            Darwin.close(self.masterFD)
            self.masterFD = -1
            self.pendingInput.removeAll()
        }
    }

    private func readAvailable() {
        guard !stopped else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let size = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(masterFD, bytes.baseAddress, bytes.count)
        }
        if size > 0 {
            // Keep at most one chunk in the native/WebKit/xterm pipeline.
            // The renderer resumes reads after it has parsed this chunk.
            readSuspended = true
            readSource.suspend()
            onOutput?(Data(buffer.prefix(size)))
        } else if size == 0 {
            // An EOF stays readable; wait for child exit rather than spin.
            readSuspended = true
            readSource.suspend()
        } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
            // PTYs commonly report EIO when their slave closes.
            readSuspended = true
            readSource.suspend()
        }
    }

    private func flushWrites() {
        guard !stopped else { return }
        while !pendingInput.isEmpty {
            let count = pendingInput.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.write(masterFD, base, bytes.count)
            }
            if count > 0 {
                pendingInput.removeSubrange(0..<count)
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            } else {
                pendingInput.removeAll()
                break
            }
        }
        if pendingInput.isEmpty && !writeSuspended {
            writeSuspended = true
            writeSource.suspend()
        }
    }
}
