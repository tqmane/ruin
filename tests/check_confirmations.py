#!/usr/bin/env python3
"""Focused host check for the production confirmation router and lifecycle helpers."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "src/interface/Confirmations.x").read_text()


def function_body(marker: str) -> str:
    start = SOURCE.index(marker)
    opening = SOURCE.index("{", start)
    depth = 0
    for index in range(opening, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[opening : index + 1]
    raise AssertionError(f"unterminated function: {marker}")


def check_production_wiring() -> None:
    handle = function_body(
        "static void RUINHandleHook(RUINConfirmationHook *hook, id self, SEL selector, id argument0"
    )
    order = [
        "RUINConfirmationGate(enabled, NO, YES)",
        "if (![NSThread isMainThread])",
        "RUINIsApprovedSendReentry(hook, self, selector, argument0)",
        "RUINClassifyHookAction(hook, self, argument0, dispatchedAction)",
        "RUINHasPendingConfirmation()",
        "RUINConfirmationClassifiedGate(actionClass, alreadyPending)",
    ]
    positions = [handle.index(token) for token in order]
    assert positions == sorted(positions), "pending suppression ran before identity classification"

    assert "@property(nonatomic, strong, nullable) UIAlertController *alert;" in SOURCE
    assert "[alert dismissViewControllerAnimated:" not in SOURCE
    assert "gApprovedInvocationDepth" not in SOURCE

    observe = function_body(
        "static void RUINObserveDismissal(RUINConfirmationPending *pending, uint64_t ticket)\n{"
    )
    for signal in (
        "RUINConfirmationObserveDismissal(",
        "presented == alert",
        "alert.isBeingDismissed",
        "alert.view.window != nil",
        "RUINScheduleDismissalObservation(pending, ticket)",
    ):
        assert signal in observe, f"production dismissal observer missing {signal}"

    for marker in (
        "static BOOL RUINReleasePending(",
        "static void RUINAbortPending(",
        "static void RUINInvokeApprovedOriginal(",
    ):
        body = function_body(marker)
        assert "pending.alert = nil" in body, f"terminal path does not release owned alert: {marker}"

    resolve = function_body("static void RUINResolve(RUINConfirmationPending *pending, BOOL approved)\n{")
    assert "decisionApproved" in SOURCE and "decisionCancelled" in SOURCE
    assert "dismissViewControllerAnimated" not in resolve

    invoke = function_body("static void RUINInvokeApprovedOriginal(")
    assert invoke.index("originalEntered") < invoke.index("pending.original)(")
    assert "@finally" in invoke and "RUINConfirmationFinishInvocation" in invoke
    assert "pending.sendComposer = RUINComposerForSendControl(self, argument0, dispatchedAction)" in handle
    validate = function_body("static BOOL RUINValidatePendingContext(")
    assert "pending.sendComposer" in validate and "RUINComposerForSendControl(" in validate


def production_shim_source() -> tuple[str, str]:
    # Compile the actual entry, boundary, permit, invocation and cleanup code against
    # the small UIKit surface in the shim; do not recreate the router in the test.
    types = SOURCE[
        SOURCE.index("typedef NS_ENUM(NSInteger, RUINConfirmationKind)") :
        SOURCE.index("@interface RUINChatSnapshot")
    ]
    markers = [
        "static BOOL RUINValidatePendingContext(",
        "static UIView *RUINComposerForSendControl(id control, id actionTarget, SEL action)\n{",
        "static void RUINCallOriginalDirect(",
        "static BOOL RUINPendingIsCurrentLocked(",
        "static BOOL RUINPendingIsCurrent(",
        "static BOOL RUINHasPendingConfirmation(",
        "static void RUINRecordStaleCallback(",
        "static BOOL RUINReleasePending(",
        "static void RUINAbortPending(",
        "static void RUINInvokeApprovedOriginal(",
        "static BOOL RUINIsApprovedSendReentry(",
        "static RUINConfirmationActionClass RUINClassifyHookAction(",
        "static void RUINHandleHook(RUINConfirmationHook *hook, id self, SEL selector, id argument0",
    ]
    functions = []
    for marker in markers:
        start = SOURCE.index(marker)
        signature = SOURCE[start : SOURCE.index("{", start)]
        functions.append(signature + function_body(marker))
    return types, "\n\n".join(functions)


def run_host_shim() -> None:
    fixture = ROOT / "tests/ConfirmationUIKitShim.m"
    with tempfile.TemporaryDirectory(prefix="ruin-confirmations-") as temporary:
        types, functions = production_shim_source()
        (Path(temporary) / "ConfirmationTypes.inc").write_text(types)
        (Path(temporary) / "ConfirmationProduction.inc").write_text(functions)
        executable = Path(temporary) / "check-confirmations"
        subprocess.run(
            [
                "xcrun",
                "--sdk",
                "macosx",
                "clang",
                "-fobjc-arc",
                "-fblocks",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-I",
                temporary,
                str(fixture),
                "-framework",
                "Foundation",
                "-o",
                str(executable),
            ],
            cwd=ROOT,
            check=True,
        )
        subprocess.run([str(executable)], cwd=ROOT, check=True)


if __name__ == "__main__":
    check_production_wiring()
    run_host_shim()
    print("confirmation production wiring and host shim passed")
