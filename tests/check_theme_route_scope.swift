actor ScopeTestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@_silgen_name("RUINThemeRouteScopeHostBridgeCheck")
private func hostBridgeCheck() -> Int32

@main
struct CheckThemeRouteScope {
    static func main() async {
        precondition(RUINThemeTaskScopeCurrentKind() == 0)
        precondition(RUINThemeTaskScopeCurrentRequestID() == 0)
        precondition(hostBridgeCheck() == 0)

        let requestID: UInt64 = 0xfedc_ba98_7654_3210
        let gate = ScopeTestGate()
        var inheritedTask: Task<(Int32, UInt64), Never>?
        var detachedTask: Task<(Int32, UInt64), Never>?
        let original = RUINThemeTaskScopeWithRequest(2, requestID) {
            precondition(RUINThemeTaskScopeCurrentKind() == 2)
            precondition(RUINThemeTaskScopeCurrentRequestID() == requestID)
            inheritedTask = Task {
                await gate.wait()
                return (RUINThemeTaskScopeCurrentKind(), RUINThemeTaskScopeCurrentRequestID())
            }
            detachedTask = Task.detached {
                await gate.wait()
                return (RUINThemeTaskScopeCurrentKind(), RUINThemeTaskScopeCurrentRequestID())
            }

            let nested = RUINThemeTaskScopeWithRequest(3, 303) {
                RUINThemeTaskScopeCurrentKind() == 3 &&
                        RUINThemeTaskScopeCurrentRequestID() == 303
                    ? 3
                    : -1
            }
            let kindOnly = RUINThemeTaskScopeWithValue(1) {
                RUINThemeTaskScopeCurrentKind() == 1 &&
                        RUINThemeTaskScopeCurrentRequestID() == 0
                    ? 1
                    : -1
            }
            let invalidKind = RUINThemeTaskScopeWithRequest(99, 404) {
                RUINThemeTaskScopeCurrentKind() == 0 &&
                        RUINThemeTaskScopeCurrentRequestID() == 0
                    ? 0
                    : -1
            }
            let invalidID = RUINThemeTaskScopeWithRequest(2, 0) {
                RUINThemeTaskScopeCurrentKind() == 0 &&
                        RUINThemeTaskScopeCurrentRequestID() == 0
                    ? 0
                    : -1
            }
            precondition(nested == 3 && kindOnly == 1 && invalidKind == 0 && invalidID == 0)
            precondition(RUINThemeTaskScopeCurrentKind() == 2)
            precondition(RUINThemeTaskScopeCurrentRequestID() == requestID)
            return 123456789
        }

        precondition(original == 123456789 && RUINThemeTaskScopeCurrentKind() == 0)
        precondition(RUINThemeTaskScopeCurrentRequestID() == 0)

        await gate.open()
        let inherited = await inheritedTask!.value
        let detached = await detachedTask!.value
        let later = await Task {
            (RUINThemeTaskScopeCurrentKind(), RUINThemeTaskScopeCurrentRequestID())
        }.value
        precondition(inherited.0 == 2 && inherited.1 == requestID)
        precondition(detached.0 == 0 && detached.1 == 0 && later.0 == 0 && later.1 == 0)
        print("PASS: C block contract; request IDs; nested restore; invalid zeroing; child retains distinct ID after scope exit; detached/later isolation")
    }
}
