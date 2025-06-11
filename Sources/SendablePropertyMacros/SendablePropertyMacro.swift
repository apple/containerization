//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
// All rights reserved.
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

/// A macro that allows to make a property thread-safe keeping the `Sendable` conformance of the type.
public struct SendablePropertyMacro: PeerMacro {
    private static func peerPropertyName(for propertyName: String) -> String {
        "_" + propertyName
    }

    /// The macro expansion that introduces a `Sendable`-conforming "peer" declaration for a thread-safe storage for the value of the given declaration of a variable.
    /// - Parameters:
    ///   - node: The given attribute node.
    ///   - declaration: The given declaration.
    ///   - context: The macro expansion context.
    public static func expansion(
        of node: SwiftSyntax.AttributeSyntax, providingPeersOf declaration: some SwiftSyntax.DeclSyntaxProtocol, in context: some SwiftSyntaxMacros.MacroExpansionContext
    ) throws -> [SwiftSyntax.DeclSyntax] {
        guard let varDecl = declaration.as(VariableDeclSyntax.self),
            let binding = varDecl.bindings.first,
            let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
        else {
            throw SendablePropertyError.onlyApplicableToVar
        }

        let propertyName = pattern.identifier.text
        let hasInitializer = binding.initializer != nil
        let initializerValue = binding.initializer?.value.description ?? "nil"

        var genericTypeAnnotation = ""
        if let typeAnnotation = binding.typeAnnotation {
            let typeName = typeAnnotation.type.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            genericTypeAnnotation = "<\(typeName)\(hasInitializer ? "" : "?")>"
        }

        let accessLevel = varDecl.modifiers.first(where: { ["open", "public", "internal", "fileprivate", "private"].contains($0.name.text) })?.name.text ?? "internal"

        // Create a peer property
        let peerPropertyName = self.peerPropertyName(for: propertyName)
        let peerProperty: DeclSyntax =
            """
            \(raw: accessLevel) let \(raw: peerPropertyName) = Synchronized\(raw: genericTypeAnnotation)(\(raw: initializerValue))
            """
        return [peerProperty]
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
        guard let varDecl = declaration.as(VariableDeclSyntax.self),
            let binding = varDecl.bindings.first,
            let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
        else {
            throw SendablePropertyError.onlyApplicableToVar
        }

        let propertyName = pattern.identifier.text
        let hasInitializer = binding.initializer != nil

        // Replace the property with an accessor
        let peerPropertyName = Self.peerPropertyName(for: propertyName)

        let accessorGetter: AccessorDeclSyntax =
            """
            get {
                \(raw: peerPropertyName).withLock { $0\(raw: hasInitializer ? "" : "!") }
            }
            """
        let accessorSetter: AccessorDeclSyntax =
            """
            set {
                \(raw: peerPropertyName).withLock { $0 = newValue }
            }
            """

        return [accessorGetter, accessorSetter]
    }
}
