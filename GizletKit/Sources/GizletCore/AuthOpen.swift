import Foundation

/// Opens a device with administrator authorization through macOS's
/// `/usr/libexec/authopen`, which asks for it with the system dialog and
/// passes back only the open file descriptor over a socket. Nothing else
/// runs with elevated rights, and the right covers that one device.
public enum AuthOpen {
    public static func open(_ path: String, flags: Int32 = O_RDWR) throws -> Int32 {
        var sockets: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw FlashError.authorization("Cannot ask for authorization (\(errno))") }
        defer { close(sockets[0]) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
        process.arguments = ["-stdoutpipe", "-o", String(flags), path]
        process.standardOutput = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: false)
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            close(sockets[1])
            throw FlashError.authorization("Cannot run authopen: \(error.localizedDescription)")
        }
        close(sockets[1])
        let descriptor = receiveDescriptor(sockets[0])
        process.waitUntilExit()
        guard process.terminationStatus == 0, let descriptor else {
            if let descriptor { close(descriptor) }
            throw FlashError.authorization("Administrator authorization was not given; nothing was written")
        }
        return descriptor
    }

    /// Reads one SCM_RIGHTS message and returns the descriptor it carries.
    static func receiveDescriptor(_ socket: Int32) -> Int32? {
        // CMSG_SPACE(sizeof(int)) on Darwin: a 12-byte header, then the int.
        let headerLength = MemoryLayout<cmsghdr>.size
        let controlLength = headerLength + MemoryLayout<Int32>.size
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlLength, alignment: 4)
        defer { control.deallocate() }
        control.initializeMemory(as: UInt8.self, repeating: 0, count: controlLength)
        var data = [UInt8](repeating: 0, count: 256)
        return data.withUnsafeMutableBytes { buffer -> Int32? in
            var vector = iovec(iov_base: buffer.baseAddress, iov_len: buffer.count)
            return withUnsafeMutablePointer(to: &vector) { vectorPointer -> Int32? in
                var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: vectorPointer, msg_iovlen: 1,
                                     msg_control: control, msg_controllen: socklen_t(controlLength), msg_flags: 0)
                var received: Int
                repeat { received = recvmsg(socket, &message, 0) } while received < 0 && errno == EINTR
                guard received > 0, message.msg_controllen >= socklen_t(controlLength) else { return nil }
                let header = control.load(as: cmsghdr.self)
                guard header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS else { return nil }
                return control.load(fromByteOffset: headerLength, as: Int32.self)
            }
        }
    }
}
