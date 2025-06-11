//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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
/// /etc/passwd (and /etc/group).
public enum User {
    private static let passwdFile = "/etc/passwd"
    private static let groupFile = "/etc/group"

    public struct ExecUser: Sendable {
        public var uid: UInt32
        public var gid: UInt32
        public var sgids: [UInt32]
        public var home: String
    }

    private struct User {
        let name: String
        let password: String
        let uid: UInt32
        let gid: UInt32
        let gecos: String
        let home: String
        let shell: String

        /// The argument `rawString` must follow the below format.
        /// Name:Password:Uid:Gid:Gecos:Home:Shell
        init(rawString: String) throws {
            let args = rawString.split(separator: ":", omittingEmptySubsequences: false)
            guard args.count == 7 else {
                throw ContainerizationError.init(.invalidArgument, message: "Cannot parse User from '\(rawString)'")
            }
            guard let uid = UInt32(args[2]) else {
                throw ContainerizationError.init(.invalidArgument, message: "Cannot parse uid from '\(args[2])'")
            }
            guard let gid = UInt32(args[3]) else {
                throw ContainerizationError.init(.invalidArgument, message: "Cannot parse gid from '\(args[3])'")
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

    private struct Group {
        let name: String
        let password: String
        let gid: UInt32
        let users: [String]

        /// The argument `rawString` must follow the below format.
        /// Name:Password:Gid:user1,user2
        init(rawString: String) throws {
            let args = rawString.split(separator: ":", omittingEmptySubsequences: false)
            guard args.count == 4 else {
                throw ContainerizationError.init(.invalidArgument, message: "Cannot parse Group from '\(rawString)'")
            }
            guard let gid = UInt32(args[2]) else {
                throw ContainerizationError.init(.invalidArgument, message: "Cannot parse gid from '\(args[2])'")
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
    /// Parse the contents of the passwd file
    private static func parsePasswd(passwdFile: URL) throws -> [User] {
        var users: [User] = []
        try self.parse(file: passwdFile) { line in
            let user = try User(rawString: line)
            users.append(user)
        }
        return users
    }

    /// Parse the contents of the group file
    private static func parseGroup(groupFile: URL) throws -> [Group] {
        var groups: [Group] = []
        try self.parse(file: groupFile) { line in
            let group = try Group(rawString: line)
            groups.append(group)
        }
        return groups
    }

    private static func parse(file: URL, handler: (_ line: String) throws -> Void) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.absolutePath()) else {
            throw ContainerizationError(.notFound, message: "File \(file.absolutePath()) does not exist")
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
}

// MARK: Public methods

extension User {
    public static func parseUser(root: String, userString: String) throws -> ExecUser {
        let defaultUser = ExecUser(uid: 0, gid: 0, sgids: [], home: "/")
        guard !userString.isEmpty else {
            return defaultUser
        }

        let passwdPath = URL(filePath: root).appending(path: Self.passwdFile)
        let groupPath = URL(filePath: root).appending(path: Self.groupFile)
        let parts = userString.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)

        let userArg = String(parts[0])
        let userIdArg = Int(userArg)

        guard FileManager.default.fileExists(atPath: passwdPath.absolutePath()) else {
            guard let userIdArg else {
                throw ContainerizationError(.internalError, message: "Cannot parse username \(userArg)")
            }
            let uid = UInt32(userIdArg)
            guard parts.count > 1 else {
                return ExecUser(uid: uid, gid: uid, sgids: [], home: "/")
            }
            guard let gid = UInt32(String(parts[1])) else {
                throw ContainerizationError(.internalError, message: "Cannot parse user group from \(userString)")
            }
            return ExecUser(uid: uid, gid: gid, sgids: [], home: "/")
        }

        let registeredUsers = try parsePasswd(passwdFile: passwdPath)
        guard registeredUsers.count > 0 else {
            throw ContainerizationError(.internalError, message: "No users configured in passwd file.")
        }
        let matches = registeredUsers.filter { registeredUser in
            // Check for a match (either uid/name) against the configured users from the passwd file.
            // We have to check both the uid and the name cause we dont know the type of `userString`
            registeredUser.name == userArg || registeredUser.uid == (userIdArg ?? -1)
        }
        guard let match = matches.first else {
            // We did not find a matching uid/username in the passwd file
            throw ContainerizationError(.internalError, message: "Cannot find User '\(userArg)' in passwd file.")
        }

        var user = ExecUser(uid: match.uid, gid: match.gid, sgids: [match.gid], home: match.home)

        guard !match.name.isEmpty else {
            return user
        }
        let matchedUser = match.name
        var groupArg = ""
        var groupIdArg: Int? = nil
        if parts.count > 1 {
            groupArg = String(parts[1])
            groupIdArg = Int(groupArg)
        }

        let registeredGroups: [Group] = {
            do {
                // Parse the <root>/etc/group file for a list of registered groups.
                // If the file is missing / malformed, we bail out
                return try parseGroup(groupFile: groupPath)
            } catch {
                return []
            }
        }()
        guard registeredGroups.count > 0 else {
            return user
        }
        let matchingGroups = registeredGroups.filter { registeredGroup in
            if !groupArg.isEmpty {
                return registeredGroup.gid == (groupIdArg ?? -1) || registeredGroup.name == groupArg
            }
            return registeredGroup.users.contains(matchedUser) || registeredGroup.gid == match.gid
        }
        guard matchingGroups.count > 0 else {
            throw ContainerizationError(.internalError, message: "Cannot find Group '\(groupArg)' in groups file.")
        }
        // We have found a list of groups that match the group specified in the argument `userString`.
        // Set the matched groups as the supplement groups for the user
        if !groupArg.isEmpty {
            // Reassign the user's group only we were explicitly asked for a group
            user.gid = matchingGroups.first!.gid
            user.sgids = matchingGroups.map { group in
                group.gid
            }
        } else {
            user.sgids.append(
                contentsOf: matchingGroups.map { group in
                    group.gid
                })
        }
        return user
    }
}
