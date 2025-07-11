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

import Foundation
import SwiftCompilerPlugin
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// A macro that allows to make a property of a supported type thread-safe keeping the `Sendable` conformance of the type.
public struct SendablePropertyMacro: PeerMacro {
    private static let allowedTypes: Set<String> = [
        "Int", "UInt", "Int16", "UInt16", "Int32", "UInt32", "Int64", "UInt64", "Float", "Double", "Bool", "UnsafeRawPointer", "UnsafeMutableRawPointer", "UnsafePointer",
        "UnsafeMutablePointer",
    ]

    private static func checkPropertyType(in declaration: some DeclSyntaxProtocol) throws {
        guard let varDecl = declaration.as(VariableDeclSyntax.self),
            let binding = varDecl.bindings.first,
            let typeAnnotation = binding.typeAnnotation,
            let id = typeAnnotation.type.as(IdentifierTypeSyntax.self)
        else {
            // Nothing to check.
            return
        }

        var typeName = id.name.text
        // Allow optionals of the allowed types.
        if typeName.prefix(9) == "Optional<" && typeName.suffix(1) == ">" {
            typeName = String(typeName.dropFirst(9).dropLast(1))
        }
        // Allow generics of the allowed types.
        if typeName.contains("<") {
            typeName = String(typeName.prefix { $0 != "<" })
        }

        guard allowedTypes.contains(typeName) else {
            throw SendablePropertyError.notApplicableToType
        }
    }

    /// The macro expansion that introduces a `Sendable`-conforming "peer" declaration for a thread-safe storage for the value of the given declaration of a variable.
    /// - Parameters:
    ///   - node: The given attribute node.
    ///   - declaration: The given declaration.
    ///   - context: The macro expansion context.
    public static func expansion(
        of node: SwiftSyntax.AttributeSyntax, providingPeersOf declaration: some SwiftSyntax.DeclSyntaxProtocol, in context: some SwiftSyntaxMacros.MacroExpansionContext
    ) throws -> [SwiftSyntax.DeclSyntax] {
        try checkPropertyType(in: declaration)
        return try SendablePropertyMacroUnchecked.expansion(of: node, providingPeersOf: declaration, in: context)
    }
}

extension SendablePropertyMacro: AccessorMacro {
    /// The macro expansion that adds `Sendable`-conforming accessors to the given declaration of a variable.
    /// - Parameters:
    ///   - node: The given attribute node.
    ///   - declaration: The given declaration.
    ///   - context: The macro expansion context.
    public static func expansion(
        of node: SwiftSyntax.AttributeSyntax, providingAccessorsOf declaration: some SwiftSyntax.DeclSyntaxProtocol, in context: some SwiftSyntaxMacros.MacroExpansionContext
    ) throws -> [SwiftSyntax.AccessorDeclSyntax] {
        try checkPropertyType(in: declaration)
        return try SendablePropertyMacroUnchecked.expansion(of: node, providingAccessorsOf: declaration, in: context)
    }
}
