# LINE 26.16.0 theme persistence in RUIN.dylib

## Inspected input

The supplied decrypted IPA was inspected locally. The IPA and extracted LINE
executable are not committed to this repository.

| Item | Verified value |
| --- | --- |
| Bundle | `jp.naver.line` |
| Version | `26.16.0` |
| Build | `2026.1006.1718` |
| Architecture | Thin Mach-O `arm64`, minimum iOS 18.0 |
| Executable SHA-256 | `e1ad61171b021566f4a318c93ba1260747bfb220c81a79d5a80121311787d6ad` |
| Mach-O UUID | `292883E8-E011-3583-ADF5-F02241E3277B` |

Addresses below are unslid virtual addresses in this exact executable.
`tools/macho_integrity.py` verifies the pristine input and checks that packaging
preserves every existing Mach-O section. `tests/check_theme_persistence.py`
independently compares the runtime instruction fingerprints to this input and
decodes the constructor callback and the two save-condition branches.

## What the old packaging patch changed

`StylesheetManager`'s settings-save function spans `0x105DF17F4` through
`0x105DF18A8`. It calls the instance's `isPrimaryAccount` closure, returns without
saving when that result is false, then performs a separate validity/change
check before calling the settings-service writer.

The removed packaging script changed the `TBZ w0, #0` at `0x105DF1838` into a
`NOP`. That changed LINE's executable code on disk. The replacement leaves this
instruction, the Swift closure, and the following native validity check intact.

| Evidence | Address / value |
| --- | --- |
| Class | `_TtC17LineSharedUITheme17StylesheetManager` |
| Native class metadata | `0x10CFB7798` |
| `isPrimaryAccount` field-offset slot | `0x10D33F148`, initial offset 32 bytes |
| Closure supplied by constructor | `0x100233A1C`, loaded into `x3` at `0x105DF505C` |
| Closure calls `AccountLevel.isPrimary` | `BL 0x10285E424` at `0x100233A34` |
| Save function calls closure | `BLR x9` at `0x105DF1834` |
| Primary-account branch, preserved | `TBZ w0, #0, 0x105DF1890` at `0x105DF1838` |
| Next independent check | `BL 0x105DF18A8` at `0x105DF1848` |
| Validity/change branch, preserved | `TBZ w0, #0, 0x105DF1890` at `0x105DF184C` |

The native Objective-C metadata also exposes `currentStylesheet`,
`setCurrentStylesheet:`, `savedCurrentStylesheetURL`,
`loadAndApplyStylesheetFrom:resourceBundle:` and
`checkReachabilitySavedCurrentStylesheet`. Hooking only these Objective-C
entry points would miss direct Swift calls to the save function. The selected
adapter works at the verified defaults boundary reached by the Swift closure.

## Dylib implementation

`ThemeShop.x` uses Logos with `generator=internal` to hook the concrete
`NSUserDefaults` class's `integerForKey:` and `objectForKey:`. This shares the
existing narrow theme-shop eligibility adapter and adds a separate stylesheet
persistence scope. The group is installed once at startup through
`RUINInstallThemeFeatures` → `RUINInstallNativeThemeValidation` →
`RUINInstallThemePersistenceAdapter`.

For the stylesheet save, the complete native return-PC chain must be:

| Order | Return PC | Meaning |
| --- | --- | --- |
| 1, mode read only | `0x10694677C` | `integerForKey:` caller |
| 2, mode read only | `0x10692E638` | Native user-default value getter |
| 1, object read only | `0x10692E7DC` | `objectForKey:` caller |
| Next | `0x10285E8A0` | Account default read |
| Next | `0x10285E1C0` | Account-level value |
| Next | `0x10285E440` | `AccountLevel.isPrimary` |
| Next | `0x100233A38` | The constructor-supplied Swift closure |
| Last | `0x105DF1838` | The stylesheet-save gate |

The exact keys must also match. For this synchronous chain only, the mode read
returns plaintext mode 0, and the account-value read returns `NSNumber(0)`.
The latter is accepted only if the native getter's live frame actually contains
mode 0. This prevents the projected return value from entering LINE's migration
writer. Reentrant defaults calls, preflight reads, unrelated callers, missing
frames, changed instruction sites, and a different UUID fall through to
`%orig` unchanged.

The Logos hook captures the return address and frame pointer in its entry
function, before handing that frame to the verifier. `noinline` and
`disable_tail_calls` preserve this boundary. Helper and block frames therefore
do not become extra entries in the native chain. ASLR is handled by subtracting
the main image's slide.

This changes returned values for one verified caller. It does not store a new
account role, rewrite Swift object fields, create executable-memory trampolines,
call `mprotect`, or alter LINE's code pages. The original second check and
settings-service write run normally. All feature behavior is compiled into
`RUIN.dylib`; packaging only adds the dylib and its load command and performs
normal signing/bundle setup.

## Validation and limits

The read-only IPA verifier checks all 23 runtime instruction fingerprints, the
UUID, the Swift closure target and the unchanged primary/validity branches:

```sh
python3 tests/check_theme_persistence.py /path/to/pristine-LINE.ipa
```

The `check_theme_shop` macOS fixture exercises all three defaults scopes with
stored modes 0, 1 and 2, verifies that stored role/mode values are unchanged,
checks reentry/exception cleanup, and rejects every one-frame address mutation
and truncated persistence chain. It tests the same projection helpers used by
the Logos hooks. The binary comparison and host fixtures establish the recovered
path and guard behavior; they do not prove a live LINE session on an iPhone.

An on-device restart/apply/reset check is still required to confirm persistence
in the running app. Diagnostics separate adapter installation from observed
mode/role projections under `stylesheetPersistence` and
`secondaryStylesheetPersistenceAdapter`. A counter indicates that the expected
native path was reached; it is not a claim that the visual theme survived a
restart.
