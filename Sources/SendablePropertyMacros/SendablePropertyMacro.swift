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

    private static func baseTypeName(of type: TypeSyntax) throws -> String? {
        var type = type

        // An optional type such as `Int?` or `Optional<Int>` -> `Int`.
        // An implicitly unwrapped optional type such as `Int!` isn't supported.
        while let optionalType = type.as(OptionalTypeSyntax.self) {
            type = optionalType.wrappedType
        }

        // A member type such as `Swift.Int` -> `Int`.
        if let member = type.as(MemberTypeSyntax.self) {
            return member.name.text
        }

        // An identifier type such as `Int` or `UnsafePointer<Int>` -> `UnsafePointer`.
        if let identifierType = type.as(IdentifierTypeSyntax.self) {
            return identifierType.name.text
        }

        return nil
    }

    private static func checkPropertyType(in declaration: some DeclSyntaxProtocol) throws {
        guard let varDecl = declaration.as(VariableDeclSyntax.self),
            let binding = varDecl.bindings.first,
            let typeAnnotation = binding.typeAnnotation,
            let typeName = try baseTypeName(of: typeAnnotation.type)
        else {
            throw SendablePropertyError.noTypeSpecified
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
