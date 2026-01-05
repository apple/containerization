//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import CArchive
import Foundation

/// Represents a single entry (e.g., a file, directory, symbolic link)
/// that is to be read/written into an archive.
public final class WriteEntry {
    let underlying: OpaquePointer

    public init(_ archive: ArchiveWriter) {
        underlying = archive_entry_new2(archive.underlying)
    }

    public init() {
        underlying = archive_entry_new()
    }

    deinit {
        archive_entry_free(underlying)
    }
}

extension WriteEntry {
    /// The size of the entry in bytes.
    public var size: Int64? {
        get {
            guard archive_entry_size_is_set(underlying) != 0 else { return nil }
            return archive_entry_size(underlying)
        }
        set {
            if let s = newValue {
                archive_entry_set_size(underlying, s)
            } else {
                archive_entry_unset_size(underlying)
            }
        }
    }

    /// The mode of the entry.
    public var permissions: mode_t {
        get {
            archive_entry_perm(underlying)
        }
        set {
            archive_entry_set_perm(underlying, newValue)
        }
    }

    /// The owner id of the entry.
    public var owner: uid_t? {
        get {
            uid_t(exactly: archive_entry_uid(underlying))
        }
        set {
            archive_entry_set_uid(underlying, Int64(newValue ?? 0))
        }
    }

    /// The group id of the entry
    public var group: gid_t? {
        get {
            gid_t(exactly: archive_entry_gid(underlying))
        }
        set {
            archive_entry_set_gid(underlying, Int64(newValue ?? 0))
        }
    }

    /// The path of file this entry hardlinks to
    public var hardlink: String? {
        get {
            guard let cstr = archive_entry_hardlink(underlying) else {
                return nil
            }
            return String(cString: cstr)
        }
        set {
            guard let newValue else {
                archive_entry_set_hardlink(underlying, nil)
                return
            }
            newValue.withCString {
                archive_entry_set_hardlink(underlying, $0)
            }
        }
    }

    /// The UTF-8 encoded path of file this entry hardlinks to
    public var hardlinkUtf8: String? {
        get {
            guard let cstr = archive_entry_hardlink_utf8(underlying) else {
                return nil
            }
            return String(cString: cstr, encoding: .utf8)
        }
        set {
            guard let newValue else {
                archive_entry_set_hardlink_utf8(underlying, nil)
                return
            }
            newValue.withCString {
                archive_entry_set_hardlink_utf8(underlying, $0)
            }
        }
    }

    /// The string representation of the permissions of the entry
    public var strmode: String? {
        if let cstr = archive_entry_strmode(underlying) {
            return String(cString: cstr)
        }
        return nil
    }

    /// The type of file this entry represents.
    public var fileType: URLFileResourceType {
        get {
            switch archive_entry_filetype(underlying) {
            case S_IFIFO: return .namedPipe
            case S_IFCHR: return .characterSpecial
            case S_IFDIR: return .directory
            case S_IFBLK: return .blockSpecial
            case S_IFREG: return .regular
            case S_IFLNK: return .symbolicLink
            case S_IFSOCK: return .socket
            default: return .unknown
            }
        }
        set {
            switch newValue {
            case .namedPipe: archive_entry_set_filetype(underlying, UInt32(S_IFIFO as mode_t))
            case .characterSpecial: archive_entry_set_filetype(underlying, UInt32(S_IFCHR as mode_t))
            case .directory: archive_entry_set_filetype(underlying, UInt32(S_IFDIR as mode_t))
            case .blockSpecial: archive_entry_set_filetype(underlying, UInt32(S_IFBLK as mode_t))
            case .regular: archive_entry_set_filetype(underlying, UInt32(S_IFREG as mode_t))
            case .symbolicLink: archive_entry_set_filetype(underlying, UInt32(S_IFLNK as mode_t))
            case .socket: archive_entry_set_filetype(underlying, UInt32(S_IFSOCK as mode_t))
            default: archive_entry_set_filetype(underlying, 0)
            }
        }
    }

    /// The date that the entry was last accessed
    public var contentAccessDate: Date? {
        get {
            Date(
                underlying,
                archive_entry_atime_is_set,
                archive_entry_atime,
                archive_entry_atime_nsec)
        }
        set {
            setDate(
                newValue,
                underlying, archive_entry_set_atime,
                archive_entry_unset_atime)
        }
    }

    /// The date that the entry was created
    public var creationDate: Date? {
        get {
            Date(
                underlying,
                archive_entry_ctime_is_set,
                archive_entry_ctime,
                archive_entry_ctime_nsec)
        }
        set {
            setDate(
                newValue,
                underlying, archive_entry_set_ctime,
                archive_entry_unset_ctime)
        }
    }

    /// The date that the entry was modified
    public var modificationDate: Date? {
        get {
            Date(
                underlying,
                archive_entry_mtime_is_set,
                archive_entry_mtime,
                archive_entry_mtime_nsec)
        }
        set {
            setDate(
                newValue,
                underlying, archive_entry_set_mtime,
                archive_entry_unset_mtime)
        }
    }

    /// The file path of the entry
    public var path: String? {
        get {
            guard let pathname = archive_entry_pathname(underlying) else {
                return nil
            }
            return String(cString: pathname)
        }
        set {
            guard let newValue else {
                archive_entry_set_pathname(underlying, nil)
                return
            }
            newValue.withCString {
                archive_entry_set_pathname(underlying, $0)
            }
        }
    }

    /// The UTF-8 encoded file path of the entry
    public var pathUtf8: String? {
        get {
            guard let pathname = archive_entry_pathname_utf8(underlying) else {
                return nil
            }
            return String(cString: pathname)
        }
        set {
            guard let newValue else {
                archive_entry_set_pathname_utf8(underlying, nil)
                return
            }
            newValue.withCString {
                archive_entry_set_pathname_utf8(underlying, $0)
            }
        }
    }

    /// The symlink target that the entry points to
    public var symlinkTarget: String? {
        get {
            guard let target = archive_entry_symlink(underlying) else {
                return nil
            }
            return String(cString: target)
        }
        set {
            guard let newValue else {
                archive_entry_set_symlink(underlying, nil)
                return
            }
            newValue.withCString {
                archive_entry_set_symlink(underlying, $0)
            }
        }
    }

    /// The extended attributes of the entry
    public var xattrs: [String: Data] {
        get {
            archive_entry_xattr_reset(self.underlying)
            var attrs: [String: Data] = [:]
            var namePtr: UnsafePointer<CChar>?
            var valuePtr: UnsafeRawPointer?
            var size: Int = 0
            while archive_entry_xattr_next(self.underlying, &namePtr, &valuePtr, &size) == 0 {
                let _name = namePtr.map { String(cString: $0) }
                let _value = valuePtr.map { Data(bytes: $0, count: size) }
                guard let name = _name, let value = _value else {
                    continue
                }
                attrs[name] = value
            }
            return attrs
        }
        set {
            archive_entry_xattr_clear(self.underlying)
            for (key, value) in newValue {
                value.withUnsafeBytes { ptr in
                    archive_entry_xattr_add_entry(self.underlying, key, ptr.baseAddress, [UInt8](value).count)
                }
            }
        }
    }

    fileprivate func setDate(
        _ date: Date?, _ underlying: OpaquePointer, _ setter: (OpaquePointer, time_t, CLong) -> Void,
        _ unset: (OpaquePointer) -> Void
    ) {
        if let d = date {
            let ti = d.timeIntervalSince1970
            let seconds = floor(ti)
            let nsec = max(0, min(1_000_000_000, ti - seconds * 1_000_000_000))
            setter(underlying, time_t(seconds), CLong(nsec))
        } else {
            unset(underlying)
        }
    }
}

extension Date {
    init?(
        _ underlying: OpaquePointer, _ isSet: (OpaquePointer) -> CInt, _ seconds: (OpaquePointer) -> time_t,
        _ nsec: (OpaquePointer) -> CLong
    ) {
        guard isSet(underlying) != 0 else { return nil }
        let ti = TimeInterval(seconds(underlying)) + TimeInterval(nsec(underlying)) * 0.000_000_001
        self.init(timeIntervalSince1970: ti)
    }
}
