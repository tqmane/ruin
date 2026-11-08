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

private func ruinMirrorDisplayKind(_ mirror: Mirror) -> String {
    switch mirror.displayStyle {
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

private func ruinMirrorKind(_ value: Any) -> String {
    ruinMirrorDisplayKind(Mirror(reflecting: value))
}

// Recognize standard Swift containers without casting their contents to [Any]
// or bridging them to Foundation. App-defined customMirror getters stay opaque.
private protocol RUINMetadataArray {}
extension Array: RUINMetadataArray {}
private protocol RUINMetadataOptional {}
extension Optional: RUINMetadataOptional {}

private func ruinMetadataUnwrap(_ value: Any) -> Any? {
    var current = value
    while current is any RUINMetadataOptional {
        guard let child = Mirror(reflecting: current).children.first else { return nil }
        current = child.value
    }
    return current
}

private func ruinMetadataMirror(_ value: Any) -> Mirror? {
    guard value is any RUINMetadataArray || !(value is any CustomReflectable) else { return nil }
    return Mirror(reflecting: value)
}

private func ruinReadMetadataPath(_ object: AnyObject, _ path: [String]) -> (value: Any?, status: String) {
    var value: Any = object
    for component in path {
        guard let raw = ruinMetadataUnwrap(value) else { return (nil, "missing_or_nil") }
        guard let mirror = ruinMetadataMirror(raw) else { return (nil, "reflection_omitted") }
        var level: Mirror? = mirror
        var childValue: Any?
        while let current = level {
            if let child = current.children.first(where: { $0.label == component }) {
                childValue = child.value
                break
            }
            level = current.superclassMirror
        }
        guard let childValue else { return (nil, "missing_or_nil") }
        value = childValue
    }
    return (ruinMetadataUnwrap(value), "missing_or_nil")
}

private struct RUINArrayMetadataBudget {
    var nodes = 256
    var fields = 2048
    var truncated = false
}

private func ruinArrayValueMetadata(_ value: Any, depth: Int,
                                   budget: inout RUINArrayMetadataBudget) -> [String: Any] {
    budget.nodes -= 1
    var row: [String: Any] = ["declaredType": String(reflecting: type(of: value))]
    guard let raw = ruinMetadataUnwrap(value) else {
        row["present"] = false
        return row
    }
    row["present"] = true
    row["type"] = String(reflecting: type(of: raw))
    guard let mirror = ruinMetadataMirror(raw) else {
        row["opaque"] = true
        return row
    }
    let kind = ruinMirrorDisplayKind(mirror)
    row["kind"] = kind
    guard depth < 2 else {
        if !mirror.children.isEmpty { row["truncated"] = true; budget.truncated = true }
        return row
    }
    if raw is any RUINMetadataArray {
        var elements: [[String: Any]] = []
        for child in mirror.children {
            guard elements.count < 64, budget.nodes > 0 else {
                row["truncated"] = true; budget.truncated = true; break
            }
            var element = ruinArrayValueMetadata(child.value, depth: depth + 1, budget: &budget)
            element["index"] = elements.count
            elements.append(element)
        }
        row["elements"] = elements
        return row
    }
    // Enum child labels reveal the active case, rather than a stored property
    // name. Collections/dictionaries/sets must not expose keys or user values.
    guard kind == "class" || kind == "struct" || kind == "tuple" else { return row }
    var fields: [[String: Any]] = []
    var seen = Set<String>()
    var current: Mirror? = mirror
    while let level = current {
        for child in level.children {
            guard let name = child.label, name.utf8.count <= RUINSwiftFieldBounds.fieldNameBytes,
                  seen.insert(name).inserted else { continue }
            guard fields.count < 48, budget.nodes > 0, budget.fields > 0 else {
                row["truncated"] = true; budget.truncated = true
                row["fields"] = fields
                return row
            }
            budget.fields -= 1
            var field = ruinArrayValueMetadata(child.value, depth: depth + 1, budget: &budget)
            field["name"] = name
            fields.append(field)
        }
        current = level.superclassMirror
    }
    row["fields"] = fields
    return row
}

/** Raw Array reflection only: no element escapes Swift and no value is serialized. */
@_cdecl("RUINCopySwiftArrayMetadata")
public func RUINCopySwiftArrayMetadata(_ object: AnyObject?,
                                       _ fieldPath: UnsafePointer<CChar>?) -> Unmanaged<NSDictionary>? {
    guard let object, let path = ruinPathComponents(fieldPath) else { return nil }
    let resolved = ruinReadMetadataPath(object, path)
    guard let raw = resolved.value else {
        var result: [String: Any] = ["status": resolved.status]
        if resolved.status == "missing_or_nil" { result["present"] = false }
        return Unmanaged.passRetained(result as NSDictionary)
    }
    var result: [String: Any] = ["type": String(reflecting: type(of: raw)), "present": true]
    guard raw is any RUINMetadataArray else {
        result["status"] = "not_supported_array"
        return Unmanaged.passRetained(result as NSDictionary)
    }
    var budget = RUINArrayMetadataBudget()
    var elements: [[String: Any]] = []
    for child in Mirror(reflecting: raw).children {
        guard elements.count < 64, budget.nodes > 0 else { budget.truncated = true; break }
        var element = ruinArrayValueMetadata(child.value, depth: 0, budget: &budget)
        element["index"] = elements.count
        elements.append(element)
    }
    result["status"] = "captured"
    result["elements"] = elements
    result["truncated"] = budget.truncated
    return Unmanaged.passRetained(result as NSDictionary)
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
          let value = ruinReadMetadataPath(object, path).value,
          !(value is any CustomStringConvertible), !(value is any CustomDebugStringConvertible),
          !(value is any TextOutputStreamable), let mirror = ruinMetadataMirror(value),
          mirror.displayStyle == .enum, mirror.children.isEmpty else { return nil }
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

private protocol RUINArrayRowFixture {}

private enum RUINArrayFixtureEffects {
    static var closures = 0
    static var getters = 0
    static var lazyLoads = 0
    static var customMirrors = 0
}

private struct RUINArrayNativeArgument {
    let secret = "PRIVATE_NATIVE_ARGUMENT"
    let number = 678901
}

private struct RUINArrayItemFixture: RUINArrayRowFixture {
    let title = "PRIVATE_ROW_TITLE"
    let argument = RUINArrayNativeArgument()
    let action: (() -> Void)? = { RUINArrayFixtureEffects.closures += 1 }
    let emptyAction: (() -> Void)? = nil
    let map = ["PRIVATE_MAP_KEY": "PRIVATE_MAP_VALUE"]
    let payload = RUINFieldPayloadEnum.associated("PRIVATE_ENUM_PAYLOAD")
    let described = RUINFieldOpaque()
}

private final class RUINArrayLazyFixture: RUINArrayRowFixture {
    lazy var lazyValue: Int = { RUINArrayFixtureEffects.lazyLoads += 1; return 12345 }()
    var computed: Int { RUINArrayFixtureEffects.getters += 1; return 12345 }
}

private final class RUINArrayCustomFixture: RUINArrayRowFixture, CustomReflectable {
    var customMirror: Mirror {
        RUINArrayFixtureEffects.customMirrors += 1
        return Mirror(self, children: ["PRIVATE_CUSTOM_LABEL": "PRIVATE_CUSTOM_VALUE"])
    }
}

private struct RUINArraySectionFixture {
    let rows: [any RUINArrayRowFixture] = [RUINArrayItemFixture()]
}

private struct RUINArrayModelFixture {
    let cellConfigurators: [any RUINArrayRowFixture] = [
        RUINArrayItemFixture(), RUINArrayLazyFixture(), RUINArrayCustomFixture()
    ]
    let sections = [RUINArraySectionFixture()]
    let empty: [RUINArrayNativeArgument] = []
    let absent: [RUINArrayNativeArgument]? = nil
    let many = Array(repeating: RUINArrayNativeArgument(), count: 65)
    let map = ["PRIVATE_ROOT_KEY": "PRIVATE_ROOT_VALUE"]
}

private final class RUINArrayOwnerFixture {
    let viewModel = RUINArrayModelFixture()
}

private struct RUINArrayWideFixture {
    let f0 = 0, f1 = 1, f2 = 2, f3 = 3, f4 = 4, f5 = 5, f6 = 6
    let f7 = 7, f8 = 8, f9 = 9, f10 = 10, f11 = 11, f12 = 12, f13 = 13
    let f14 = 14, f15 = 15, f16 = 16, f17 = 17, f18 = 18, f19 = 19, f20 = 20
    let f21 = 21, f22 = 22, f23 = 23, f24 = 24, f25 = 25, f26 = 26, f27 = 27
    let f28 = 28, f29 = 29, f30 = 30, f31 = 31, f32 = 32, f33 = 33, f34 = 34
    let f35 = 35, f36 = 36, f37 = 37, f38 = 38, f39 = 39, f40 = 40, f41 = 41
    let f42 = 42, f43 = 43, f44 = 44, f45 = 45, f46 = 46, f47 = 47, f48 = 48
}

private final class RUINArrayBoundsFixture {
    let wide = [RUINArrayWideFixture()]
    let manyWide = Array(repeating: RUINArrayWideFixture(), count: 64)
}

private enum RUINDescribedEnum: CustomStringConvertible {
    case only
    var description: String { RUINArrayFixtureEffects.getters += 1; return "PRIVATE_ENUM_DESCRIPTION" }
}

private final class RUINBannerErrorFixture {
    let errorType = RUINFieldEnum.text
}

private final class RUINBannerEnumFixture {
    let bannerType = RUINFieldEnum.audio
    let describedCase = RUINDescribedEnum.only
    lazy var errorView: RUINBannerErrorFixture = {
        RUINArrayFixtureEffects.lazyLoads += 1
        return RUINBannerErrorFixture()
    }()
}

private func ruinTestArrayMetadata(_ owner: AnyObject, _ path: String) -> [String: Any] {
    path.withCString { RUINCopySwiftArrayMetadata(owner, $0)?.takeRetainedValue() as? [String: Any] } ?? [:]
}

private func ruinCheckArrayMetadata() {
    let owner = RUINArrayOwnerFixture()
    let metadata = ruinTestArrayMetadata(owner, "viewModel.cellConfigurators")
    precondition(metadata["status"] as? String == "captured" && metadata["present"] as? Bool == true)
    let elements = metadata["elements"] as! [[String: Any]]
    precondition(elements.count == 3 && elements[0]["index"] as? Int == 0)
    precondition((elements[0]["type"] as? String)?.hasSuffix("RUINArrayItemFixture") == true)
    let fields = elements[0]["fields"] as! [[String: Any]]
    let action = fields.first { $0["name"] as? String == "action" }!
    precondition(action["present"] as? Bool == true && (action["type"] as? String)?.contains("->") == true)
    precondition(fields.first { $0["name"] as? String == "emptyAction" }?["present"] as? Bool == false)
    let argument = fields.first { $0["name"] as? String == "argument" }!
    precondition((argument["type"] as? String)?.hasSuffix("RUINArrayNativeArgument") == true)
    precondition((argument["fields"] as? [[String: Any]])?.count == 2)
    precondition(elements[2]["opaque"] as? Bool == true)
    let lazyFields = elements[1]["fields"] as! [[String: Any]]
    precondition(lazyFields.contains { ($0["name"] as? String)?.contains("lazyValue") == true && $0["present"] as? Bool == false })
    precondition(!lazyFields.contains { $0["name"] as? String == "computed" })
    let json = String(data: try! JSONSerialization.data(withJSONObject: metadata), encoding: .utf8)!
    precondition(!json.contains("PRIVATE_") && !json.contains("678901"))
    precondition(!json.contains("__SwiftValue"))
    let section = (ruinTestArrayMetadata(owner, "viewModel.sections")["elements"] as! [[String: Any]])[0]
    let rows = (section["fields"] as! [[String: Any]])[0]
    let nested = (rows["elements"] as! [[String: Any]])[0]
    precondition((nested["type"] as? String)?.hasSuffix("RUINArrayItemFixture") == true)
    precondition(nested["truncated"] as? Bool == true && nested["fields"] == nil)
    let many = ruinTestArrayMetadata(owner, "viewModel.many")
    precondition((many["elements"] as? [Any])?.count == 64 && many["truncated"] as? Bool == true)
    let empty = ruinTestArrayMetadata(owner, "viewModel.empty")
    precondition((empty["elements"] as? [Any])?.isEmpty == true && empty["truncated"] as? Bool == false)
    precondition(ruinTestArrayMetadata(owner, "viewModel.absent")["status"] as? String == "missing_or_nil")
    precondition(ruinTestArrayMetadata(owner, "viewModel.missing")["status"] as? String == "missing_or_nil")
    precondition(ruinTestArrayMetadata(owner, "viewModel.map")["status"] as? String == "not_supported_array")
    precondition(ruinTestArrayMetadata(owner, "viewModel..empty").isEmpty)
    precondition(ruinTestArrayMetadata(owner, String(repeating: "x", count: 129)).isEmpty)
    precondition(ruinTestArrayMetadata(RUINArrayCustomFixture(), "anything")["status"] as? String == "reflection_omitted")
    precondition(RUINCopySwiftArrayMetadata(owner, nil) == nil)
    precondition("viewModel.empty".withCString { RUINCopySwiftArrayMetadata(nil, $0) } == nil)
    let bounds = RUINArrayBoundsFixture()
    let wide = ruinTestArrayMetadata(bounds, "wide")
    let wideElement = (wide["elements"] as! [[String: Any]])[0]
    precondition((wideElement["fields"] as? [Any])?.count == 48 && wide["truncated"] as? Bool == true)
    func nodeCount(_ row: [String: Any]) -> Int {
        1 + ["elements", "fields"].reduce(0) { total, key in
            total + (row[key] as? [[String: Any]] ?? []).reduce(0) { $0 + nodeCount($1) }
        }
    }
    let manyWide = ruinTestArrayMetadata(bounds, "manyWide")
    precondition(manyWide["truncated"] as? Bool == true && nodeCount(manyWide) <= 257)
    let banner = RUINBannerEnumFixture()
    precondition(ruinTestEnumCaseName(banner, "bannerType") == "audio")
    precondition(ruinTestEnumCaseName(banner, "$__lazy_storage_$_errorView.errorType") == nil)
    banner.errorView = RUINBannerErrorFixture()
    precondition(ruinTestEnumCaseName(banner, "$__lazy_storage_$_errorView.errorType") == "text")
    precondition(ruinTestEnumCaseName(banner, "describedCase") == nil)
    precondition(RUINArrayFixtureEffects.closures == 0 && RUINArrayFixtureEffects.getters == 0)
    precondition(RUINArrayFixtureEffects.lazyLoads == 0 && RUINArrayFixtureEffects.customMirrors == 0)
    precondition(RUINFieldOpaque.descriptionCalls == 0)
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
        ruinCheckArrayMetadata()
        print("PASS: Swift stored-field/Array metadata, bounds and no callback/getter/lazy/description execution")
    }
}
#endif
