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

import Foundation
import SystemPackage

extension EXT4 {
    class FileTree {
        class FileTreeNode {
            let inode: InodeNumber
            let name: String
            var children: [Ptr<FileTreeNode>] = []
            var blocks: (start: UInt32, end: UInt32)?
            var additionalBlocks: [(start: UInt32, end: UInt32)]?
            var link: InodeNumber?
            private var parent: Ptr<FileTreeNode>?

            init(
                inode: InodeNumber,
                name: String,
                parent: Ptr<FileTreeNode>?,
                children: [Ptr<FileTreeNode>] = [],
                blocks: (start: UInt32, end: UInt32)? = nil,
                additionalBlocks: [(start: UInt32, end: UInt32)]? = nil,
                link: InodeNumber? = nil
            ) {
                self.inode = inode
                self.name = name
                self.children = children
                self.blocks = blocks
                self.additionalBlocks = additionalBlocks
                self.link = link
                self.parent = parent
            }

            deinit {
                self.children.removeAll()
                self.children = []
                self.blocks = nil
                self.additionalBlocks = nil
                self.link = nil
            }

            var path: FilePath? {
                var components: [String] = [self.name]
                var _ptr = self.parent
                while let ptr = _ptr {
                    components.append(ptr.pointee.name)
                    _ptr = ptr.pointee.parent
                }
                guard let last = components.last else {
                    return nil
                }
                guard components.count > 1 else {
                    return FilePath(last)
                }
                components = components.dropLast()
                let path = components.reversed().joined(separator: "/")
                guard let data = path.data(using: .utf8) else {
                    return nil
                }
                guard let dataPath = String(data: data, encoding: .utf8) else {
                    return nil
                }
                return FilePath(dataPath).pushing(FilePath(last)).lexicallyNormalized()
            }
        }

        var root: Ptr<FileTreeNode>

        init(_ root: InodeNumber, _ name: String) {
            self.root = Ptr<FileTreeNode>.allocate(capacity: 1)
            self.root.initialize(to: FileTreeNode(inode: root, name: name, parent: nil))
        }

        func lookup(path: FilePath) -> Ptr<FileTreeNode>? {
            var components: [String] = path.items
            var node = self.root
            if components.first == "/" {
                components = Array(components.dropFirst())
            }
            if components.count == 0 {
                return node
            }
            for component in components {
                var found = false
                for childPtr in node.pointee.children {
                    let child = childPtr.pointee
                    if child.name == component {
                        node = childPtr
                        found = true
                        break
                    }
                }
                guard found else {
                    return nil
                }
            }
            return node
        }
    }
}
