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

import ContainerizationError
import Foundation

/// `User` provides utilities to ensure that a given username exists in
/// /etc/passwd (and /etc/group). Largely inspired by runc (and moby's)
/// `user` packages.
public enum User {
    public static let passwdFilePath = URL(filePath: "/etc/passwd")
    public static let groupFilePath = URL(filePath: "/etc/group")

    private static let minID: UInt32 = 0
    private static let maxID: UInt32 = 2_147_483_647

    public struct ExecUser: Sendable {
        public var uid: UInt32
        public var gid: UInt32
        public var sgids: [UInt32]
        public var home: String
        public var shell: String

        public init(uid: UInt32, gid: UInt32, sgids: [UInt32], home: String, shell: String) {
            self.uid = uid
            self.gid = gid
            self.sgids = sgids
            self.home = home
            self.shell = shell
        }
    }

    public struct User {
        public var name: String
        public var password: String
        public var uid: UInt32
        public var gid: UInt32
        public var gecos: String
        public var home: String
        public var shell: String

        /// The argument `rawString` must follow the below format.
        /// Name:Password:Uid:Gid:Gecos:Home:Shell
        init(rawString: String) throws {
            let args = rawString.split(separator: ":", omittingEmptySubsequences: false)
            guard args.count == 7 else {
                throw Error.parseError("cannot parse User from '\(rawString)'")
            }
            guard let uid = UInt32(args[2]) else {
                throw Error.parseError("cannot parse uid from '\(args[2])'")
            }
            guard let gid = UInt32(args[3]) else {
                throw Error.parseError("cannot parse gid from '\(args[3])'")
            }
            self.name = String(args[0])
            self.password = String(args[1])
            self.uid = uid
            self.gid = gid
            self.gecos = String(args[4])
            self.home = String(args[5])
            self.shell = String(args[6])
        }
    }

    struct Group {
        var name: String
        var password: String
        var gid: UInt32
        var users: [String]

        /// The argument `rawString` must follow the below format.
        /// Name:Password:Gid:user1,user2
        init(rawString: String) throws {
            let args = rawString.split(separator: ":", omittingEmptySubsequences: false)
            guard args.count == 4 else {
                throw Error.parseError("cannot parse Group from '\(rawString)'")
            }
            guard let gid = UInt32(args[2]) else {
                throw Error.parseError("cannot parse gid from '\(args[2])'")
            }
            self.name = String(args[0])
            self.password = String(args[1])
            self.gid = gid
            self.users = args[3].split(separator: ",").map { String($0) }
        }
    }
}

// MARK: Private methods

extension User {
    private static func parse(file: URL, handler: (_ line: String) throws -> Void) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.absolutePath()) else {
            throw Error.missingFile(file.absolutePath())
        }
        let content = try String(contentsOf: file, encoding: .ascii)
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            guard !line.isEmpty else {
                continue
            }
            try handler(line.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Parse the contents of the passwd file with a provided filter function.
    static func parsePasswd(passwdFile: URL, filter: ((User) -> Bool)? = nil) throws -> [User] {
        var users: [User] = []
        try self.parse(file: passwdFile) { line in
            let user = try User(rawString: line)
            if let filter {
                guard filter(user) else {
                    return
                }
            }
            users.append(user)
        }
        return users
    }

    /// Parse the contents of the group file with a provided filter function.
    static func parseGroup(groupFile: URL, filter: ((Group) -> Bool)? = nil) throws -> [Group] {
        var groups: [Group] = []
        try self.parse(file: groupFile) { line in
            let group = try Group(rawString: line)
            if let filter {
                guard filter(group) else {
                    return
                }
            }
            groups.append(group)
        }
        return groups
    }
}

// MARK: Public methods

extension User {
    /// Looks up uid in the password file specified by `passwdPath`.
    public static func lookupUid(passwdPath: URL = Self.passwdFilePath, uid: UInt32) throws -> User {
        let users = try parsePasswd(
            passwdFile: passwdPath,
            filter: { u in
                u.uid == uid
            })
        if users.count == 0 {
            throw Error.noPasswdEntries
        }
        return users[0]
    }

    /// Parses a user string in any of the following formats:
    /// "user, uid, user:group, uid:gid, uid:group, user:gid"
    /// and returns an ExecUser type from the information.
    public static func getExecUser(
        userString: String,
        defaults: ExecUser? = nil,
        passwdPath: URL = Self.passwdFilePath,
        groupPath: URL = Self.groupFilePath
    ) throws -> ExecUser {
        let defaults = defaults ?? ExecUser(uid: 0, gid: 0, sgids: [], home: "/", shell: "")

        var user = ExecUser(
            uid: defaults.uid,
            gid: defaults.gid,
            sgids: defaults.sgids,
            home: defaults.home,
            shell: defaults.shell
        )

        let parts = userString.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let userArg = parts.isEmpty ? "" : String(parts[0])
        let groupArg = parts.count > 1 ? String(parts[1]) : ""

        let uidArg = UInt32(userArg)
        let notUID = uidArg == nil
        let gidArg = UInt32(groupArg)
        let notGID = gidArg == nil

        let users: [User]
        do {
            users = try parsePasswd(passwdFile: passwdPath) { u in
                if userArg.isEmpty {
                    return u.uid == user.uid
                }
                if !notUID {
                    return uidArg! == u.uid
                }
                return u.name == userArg
            }
        } catch Error.missingFile {
            users = []
        }

        var matchedUserName = ""
        if !users.isEmpty {
            let matchedUser = users[0]
            matchedUserName = matchedUser.name
            user.uid = matchedUser.uid
            user.gid = matchedUser.gid
            user.home = matchedUser.home
            user.shell = matchedUser.shell
        } else if !userArg.isEmpty {
            if notUID {
                throw Error.noPasswdEntries
            }

            user.uid = uidArg!
            if user.uid < minID || user.uid > maxID {
                throw Error.range
            }
        }

        if !groupArg.isEmpty || !matchedUserName.isEmpty {
            let groups: [Group]
            do {
                groups = try parseGroup(groupFile: groupPath) { g in
                    if groupArg.isEmpty {
                        return g.users.contains(matchedUserName)
                    }
                    if !notGID {
                        return gidArg! == g.gid
                    }
                    return g.name == groupArg
                }
            } catch Error.missingFile {
                groups = []
            }

            if !groupArg.isEmpty {
                if !groups.isEmpty {
                    user.gid = groups[0].gid
                } else {
                    if notGID {
                        throw Error.noGroupEntries
                    }

                    user.gid = gidArg!
                    if user.gid < minID || user.gid > maxID {
                        throw Error.range
                    }
                }
            }
            user.sgids = groups.map { $0.gid }
        }
        return user
    }

    public enum Error: Swift.Error {
        case missingFile(String)
        case range
        case noPasswdEntries
        case noGroupEntries
        case parseError(String)
    }
}
