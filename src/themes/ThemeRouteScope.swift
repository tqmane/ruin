public enum ThemeRouteScope {
    public struct Value: Sendable {
        public let kind: Int32
        public let requestID: UInt64

        fileprivate init(kind: Int32, requestID: UInt64) {
            self.kind = kind
            self.requestID = requestID
        }
    }

    @TaskLocal public static var currentValue = Value(kind: 0, requestID: 0)

    public static var currentKind: Int32 { currentValue.kind }
    public static var currentRequestID: UInt64 { currentValue.requestID }
}

@_cdecl("RUINThemeTaskScopeWithValue")
public func RUINThemeTaskScopeWithValue(
    _ kind: Int32,
    _ body: @convention(block) () -> Int32
) -> Int32 {
    let boundedKind: Int32 = (1...3).contains(kind) ? kind : 0
    let value = ThemeRouteScope.Value(kind: boundedKind, requestID: 0)
    return ThemeRouteScope.$currentValue.withValue(value) { body() }
}

@_cdecl("RUINThemeTaskScopeCurrentKind")
public func RUINThemeTaskScopeCurrentKind() -> Int32 {
    let kind = ThemeRouteScope.currentKind
    return (1...3).contains(kind) ? kind : 0
}

@_cdecl("RUINThemeTaskScopeWithRequest")
public func RUINThemeTaskScopeWithRequest(
    _ kind: Int32,
    _ requestID: UInt64,
    _ body: @convention(block) () -> Int32
) -> Int32 {
    let value: ThemeRouteScope.Value
    if (1...3).contains(kind), requestID != 0 {
        value = ThemeRouteScope.Value(kind: kind, requestID: requestID)
    } else {
        value = ThemeRouteScope.Value(kind: 0, requestID: 0)
    }
    return ThemeRouteScope.$currentValue.withValue(value) { body() }
}

@_cdecl("RUINThemeTaskScopeCurrentRequestID")
public func RUINThemeTaskScopeCurrentRequestID() -> UInt64 {
    ThemeRouteScope.currentRequestID
}
