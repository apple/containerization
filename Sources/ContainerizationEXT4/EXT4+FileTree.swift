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
import OrderedCollections
import SystemPackage

extension EXT4 {
    class FileTree {
        class FileTreeNode {
            let inode: InodeNumber
            let name: String
            // Children keyed by name for O(1) lookup, preserving insertion order.
            private(set) var childrenByName: OrderedDictionary<String, Ptr<FileTreeNode>> = [:]
            var children: OrderedDictionary<String, Ptr<FileTreeNode>>.Values {
                childrenByName.values
            }
            var blocks: (start: UInt32, end: UInt32)?
            var additionalBlocks: [(start: UInt32, end: UInt32)]?
            var link: InodeNumber?
            private weak var parent: Ptr<FileTreeNode>?

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
                self.blocks = blocks
                self.additionalBlocks = additionalBlocks
                self.link = link
                self.parent = parent
                for child in children {
                    self.addChild(child)
                }
            }

            deinit {
                self.childrenByName.removeAll()
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
                let path = components.reversed().joined(separator: "/")
                return FilePath(path).lexicallyNormalized()
            }

            func addChild(_ child: Ptr<FileTreeNode>) {
                childrenByName[child.pointee.name] = child
            }

            func removeChild(named name: String) {
                childrenByName.removeValue(forKey: name)
            }
        }

        var root: Ptr<FileTreeNode>

        init(_ root: InodeNumber, _ name: String) {
            self.root = Ptr(FileTreeNode(inode: root, name: name, parent: nil))
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
                guard let childPtr = node.pointee.childrenByName[component] else {
                    return nil
                }
                node = childPtr
            }
            return node
        }
    }
}
