import Foundation
import Darwin
import ObjectiveC

private enum RUINSwiftFieldBounds {
    static let pathBytes = 1024
    static let fieldNameBytes = 128
    static let pathDepth = 8
    static let fieldCount = 128
}

private func ruinPathComponents(_ cString: UnsafePointer<CChar>?) -> [String]? {
    guard let cString else { return nil }
    let length = strnlen(cString, RUINSwiftFieldBounds.pathBytes + 1)
    guard length > 0, length <= RUINSwiftFieldBounds.pathBytes else { return nil }
    let bytes = UnsafeBufferPointer(
        start: UnsafeRawPointer(cString).assumingMemoryBound(to: UInt8.self),
        count: length
    )
    guard let path = String(bytes: bytes, encoding: .utf8) else { return nil }
    let components = path.split(separator: ".", omittingEmptySubsequences: false)
    guard !components.isEmpty, components.count <= RUINSwiftFieldBounds.pathDepth else { return nil }

    var result: [String] = []
    result.reserveCapacity(components.count)
    for component in components {
        guard !component.isEmpty, component.utf8.count <= RUINSwiftFieldBounds.fieldNameBytes else { return nil }
        result.append(String(component))
    }
    return result
}

private func ruinUnwrapOptionals(_ value: Any) -> Any? {
    var current = value
    while Mirror(reflecting: current).displayStyle == .optional {
        guard let wrapped = Mirror(reflecting: current).children.first else { return nil }
        current = wrapped.value
    }
    return current
}

private func ruinChild(named name: String, in value: Any) -> Any? {
    var mirror = Mirror(reflecting: value)
    while true {
        if let child = mirror.children.first(where: { $0.label == name }) { return child.value }
        guard let superclass = mirror.superclassMirror else { return nil }
        mirror = superclass
    }
}

private func ruinReadField(_ object: AnyObject, path: [String]) -> Any? {
    var current: Any = object
    for component in path {
        guard let unwrapped = ruinUnwrapOptionals(current),
              let child = ruinChild(named: component, in: unwrapped) else { return nil }
        current = child
    }
    guard let finalValue = ruinUnwrapOptionals(current) else { return nil }
    return finalValue
}

private func ruinFieldNames(_ object: AnyObject) -> [String] {
    var names: [String] = []
    var seen = Set<String>()
    var mirror = Mirror(reflecting: object)
    while true {
        for child in mirror.children {
            guard let name = child.label,
                  name.utf8.count <= RUINSwiftFieldBounds.fieldNameBytes,
                  seen.insert(name).inserted else { continue }
            names.append(name)
            if names.count == RUINSwiftFieldBounds.fieldCount { return names }
        }
        guard let superclass = mirror.superclassMirror else { return names }
        mirror = superclass
    }
}

@_cdecl("RUINCopySwiftField")
public func RUINCopySwiftField(_ object: AnyObject?,
                               _ fieldPath: UnsafePointer<CChar>?) -> Unmanaged<AnyObject>? {
    guard let object, let path = ruinPathComponents(fieldPath),
          let value = ruinReadField(object, path: path) else { return nil }
    return Unmanaged.passRetained(value as AnyObject)
}

@_cdecl("RUINCopySwiftFieldTypeName")
public func RUINCopySwiftFieldTypeName(_ object: AnyObject?,
                                      _ fieldPath: UnsafePointer<CChar>?) -> Unmanaged<NSString>? {
    guard let object, let path = ruinPathComponents(fieldPath),
          let value = ruinReadField(object, path: path) else { return nil }
    return Unmanaged.passRetained(String(reflecting: type(of: value)) as NSString)
}

@_cdecl("RUINCopySwiftFieldNames")
public func RUINCopySwiftFieldNames(_ object: AnyObject?) -> Unmanaged<NSArray>? {
    guard let object else { return nil }
    return Unmanaged.passRetained(ruinFieldNames(object) as NSArray)
}

@_cdecl("RUINCopySwiftFieldInfo")
public func RUINCopySwiftFieldInfo(_ object: AnyObject?,
                                  _ fieldPath: UnsafePointer<CChar>?) -> Unmanaged<NSArray>? {
    guard let object else { return nil }
    let value: Any
    if let fieldPath {
        guard let path = ruinPathComponents(fieldPath), let field = ruinReadField(object, path: path) else { return nil }
        value = field
    } else { value = object }
    var mirror = Mirror(reflecting: value)
    var rows: [[String: String]] = []
    var seen = Set<String>()
    while true {
        for child in mirror.children {
            guard let name = child.label, name.utf8.count <= RUINSwiftFieldBounds.fieldNameBytes,
                  seen.insert(name).inserted else { continue }
            rows.append(["name":name, "type":String(reflecting: type(of: child.value))])
            if rows.count >= RUINSwiftFieldBounds.fieldCount { return Unmanaged.passRetained(rows as NSArray) }
        }
        guard let parent = mirror.superclassMirror else { break }
        mirror = parent
    }
    return Unmanaged.passRetained(rows as NSArray)
}

private func ruinMirrorKind(_ value: Any) -> String {
    switch Mirror(reflecting: value).displayStyle {
    case .class: return "class"
    case .struct: return "struct"
    case .foreignReference: return "class"
    case .enum: return "enum"
    case .collection: return "collection"
    case .dictionary: return "dictionary"
    case .set: return "set"
    case .tuple: return "tuple"
    case .optional: return "optional"
    case nil: return "other"
    @unknown default: return "other"
    }
}

@_cdecl("RUINCopySwiftFieldKind")
public func RUINCopySwiftFieldKind(_ object: AnyObject?,
                                  _ fieldPath: UnsafePointer<CChar>?) -> Unmanaged<NSString>? {
    guard let object else { return nil }
    let value: Any
    if let fieldPath {
        guard let path = ruinPathComponents(fieldPath), let field = ruinReadField(object, path: path) else { return nil }
        value = field
    } else { value = object }
    return Unmanaged.passRetained(ruinMirrorKind(value) as NSString)
}

@_cdecl("RUINCopySwiftEnumCaseName")
public func RUINCopySwiftEnumCaseName(_ object: AnyObject?,
                                     _ fieldPath: UnsafePointer<CChar>?) -> Unmanaged<NSString>? {
    guard let object, let path = ruinPathComponents(fieldPath),
          let value = ruinReadField(object, path: path) else { return nil }
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .enum, mirror.children.isEmpty else { return nil }
    let name = String(describing: value)
    guard name.utf8.count <= RUINSwiftFieldBounds.fieldNameBytes else { return nil }
    return Unmanaged.passRetained(name as NSString)
}

@_cdecl("RUINWriteReadControllerEnabled")
public func RUINWriteReadControllerEnabled(_ object: AnyObject?, _ enabled: Int32) -> Int32 {
    guard let object, enabled == 0 || enabled == 1,
          let cls = object_getClass(object),
          cls === NSClassFromString("_TtC15LineMessagingUI24ChatMarkAsReadController"),
          let ivar = class_getInstanceVariable(cls, "isEnabled"),
          let value = ruinChild(named: "isEnabled", in: object),
          type(of: value) == Bool.self, let boolean = value as? Bool else { return -1 }
    let offset = ivar_getOffset(ivar)
    guard offset >= MemoryLayout<UnsafeRawPointer>.size,
          offset < class_getInstanceSize(cls) else { return -1 }
    let location = Unmanaged.passUnretained(object).toOpaque().advanced(by: offset)
    let previous = location.load(as: UInt8.self)
    guard previous < 2, (previous == 1) == boolean else { return -1 }
    location.storeBytes(of: UInt8(enabled), as: UInt8.self)
    return Int32(previous)
}

#if RUIN_SWIFTFIELDS_TEST
@objc(_TtC15LineMessagingUI24ChatMarkAsReadController)
private final class RUINReadGateFixture: NSObject {
    var padding0: UInt64 = 0
    var padding1: UInt64 = 0
    var padding2: UInt64 = 0
    var padding3: UInt64 = 0
    var padding4: UInt64 = 0
    var padding5: UInt64 = 0
    var padding6: UInt64 = 0
    var isEnabled = true
    var sentinel: UInt64 = 0x76543210
}

private struct RUINFieldLeaf {
    let number: Int
}

private struct RUINFieldTree {
    let leaf: RUINFieldLeaf
    let optionalLeaf: RUINFieldLeaf?
    let emptyLeaf: RUINFieldLeaf?
}

private enum RUINFieldEnum {
    case audio
    case text
}

private enum RUINFieldPayloadEnum {
    case associated(String)
    case empty
}

private class RUINFieldBase {
    let inheritedField = "base"
}

private final class RUINFieldOpaque: CustomStringConvertible {
    static var descriptionCalls = 0
    var description: String {
        Self.descriptionCalls += 1
        return "must-not-be-read"
    }
}

private final class RUINFieldProbe: RUINFieldBase {
    let tree = RUINFieldTree(
        leaf: RUINFieldLeaf(number: 42),
        optionalLeaf: RUINFieldLeaf(number: 7),
        emptyLeaf: nil
    )
    let enumCase = RUINFieldEnum.audio
    let payloadEnum = RUINFieldPayloadEnum.associated("payload")
    let opaque = RUINFieldOpaque()
}

private func ruinTestRead(_ object: AnyObject, _ path: String) -> AnyObject? {
    path.withCString { RUINCopySwiftField(object, $0)?.takeRetainedValue() }
}

private func ruinTestEnumCaseName(_ object: AnyObject, _ path: String) -> String? {
    path.withCString { RUINCopySwiftEnumCaseName(object, $0)?.takeRetainedValue() as String? }
}

@main
private struct RUINSwiftFieldsHostCheck {
    static func main() {
        let probe = RUINFieldProbe()
        precondition(ruinTestRead(probe, "inheritedField") as? String == "base")
        precondition((ruinTestRead(probe, "tree.leaf.number") as? NSNumber)?.intValue == 42)
        precondition((ruinTestRead(probe, "tree.optionalLeaf.number") as? NSNumber)?.intValue == 7)
        precondition(ruinTestRead(probe, "tree.emptyLeaf.number") == nil)
        precondition(ruinTestRead(probe, "tree.missing") == nil)
        let numberType = "tree.optionalLeaf.number".withCString {
            RUINCopySwiftFieldTypeName(probe, $0)?.takeRetainedValue()
        }
        precondition(numberType == "Swift.Int")
        let missingType = "tree.emptyLeaf.number".withCString {
            RUINCopySwiftFieldTypeName(probe, $0)?.takeRetainedValue()
        }
        precondition(missingType == nil)
        let rawInfo = "tree.leaf".withCString {
            RUINCopySwiftFieldInfo(probe, $0)?.takeRetainedValue() as? [[String:String]]
        }
        precondition(rawInfo?.first?["name"] == "number" && rawInfo?.first?["type"] == "Swift.Int")
        let rootKind = RUINCopySwiftFieldKind(probe, nil)?.takeRetainedValue() as String?
        let structKind = "tree".withCString { RUINCopySwiftFieldKind(probe, $0)?.takeRetainedValue() as String? }
        let numberKind = "tree.leaf.number".withCString { RUINCopySwiftFieldKind(probe, $0)?.takeRetainedValue() as String? }
        let objectKind = "opaque".withCString { RUINCopySwiftFieldKind(probe, $0)?.takeRetainedValue() as String? }
        precondition(rootKind == "class" && structKind == "struct" && numberKind == "other" && objectKind == "class")

        precondition(ruinTestEnumCaseName(probe, "enumCase") == "audio")
        precondition(ruinTestEnumCaseName(probe, "payloadEnum") == nil)
        precondition(ruinTestEnumCaseName(probe, "tree.leaf.number") == nil)
        precondition(ruinTestEnumCaseName(RUINFieldBase(), "enumCase") == nil)
        let nilObjectEnumName = "enumCase".withCString {
            RUINCopySwiftEnumCaseName(nil, $0)?.takeRetainedValue() as String?
        }
        precondition(nilObjectEnumName == nil)
        precondition(RUINCopySwiftEnumCaseName(probe, nil) == nil)
        precondition(ruinTestEnumCaseName(probe, "missingEnum") == nil)

        let descriptionCalls = RUINFieldOpaque.descriptionCalls
        let opaque = ruinTestRead(probe, "opaque")
        precondition(opaque === probe.opaque)
        precondition(RUINFieldOpaque.descriptionCalls == descriptionCalls)

        let gate = RUINReadGateFixture()
        let gateOffset = withUnsafePointer(to: &gate.isEnabled) { Int(bitPattern: $0) - Int(bitPattern: Unmanaged.passUnretained(gate).toOpaque()) }
        precondition(gateOffset != 56)
        precondition(class_getInstanceVariable(object_getClass(gate), "isEnabled").map(ivar_getOffset) == gateOffset)
        precondition(RUINWriteReadControllerEnabled(probe, 0) == -1)
        precondition(RUINWriteReadControllerEnabled(gate, 2) == -1)
        precondition(RUINWriteReadControllerEnabled(gate, 0) == 1 && !gate.isEnabled)
        precondition(RUINWriteReadControllerEnabled(gate, 1) == 0 && gate.isEnabled)
        precondition(gate.sentinel == 0x76543210 && gate.padding4 == 0)

        let names = RUINCopySwiftFieldNames(probe)?.takeRetainedValue() as? [String]
        precondition(names?.contains("tree") == true && names?.contains("inheritedField") == true)
        precondition(names?.contains("must-not-be-read") == false)
        precondition(RUINFieldOpaque.descriptionCalls == descriptionCalls)
    }
}
#endif
