#!/usr/bin/env python3
"""Exercise the real loader insertion and Apple signing tools on our own Mach-O."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from macho_integrity import verify_packaged
from distribute import verify_dylib


def run(*args):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stderr}\n{result.stdout}')
    return result.stdout.strip()


def main():
    verify_dylib(ROOT / 'build/RUIN.dylib')
    print('PASS: built RUIN.dylib is a signed arm64+arm64e universal binary with authorized dependencies.')
    sdk = run('xcrun', '--sdk', 'iphoneos', '--show-sdk-path')
    with tempfile.TemporaryDirectory(prefix='ruin-packaging-') as temporary:
        directory = Path(temporary)
        source = directory / 'fixture.c'
        original = directory / 'original'
        packaged = directory / 'packaged'
        source.write_text('#include <stdio.h>\nvolatile int value = 42;\n'
                          'int main(void) { return printf("RUIN fixture: %d\\n", value) < 0; }\n')
        run('xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-isysroot', sdk,
            '-miphoneos-version-min=18.0', '-Wl,-headerpad,0x1000', source, '-o', original)
        run('codesign', '--force', '--sign', '-', '--timestamp=none', original)
        original_bytes = original.read_bytes()
        shutil.copy2(original, packaged)
        run(ROOT / 'build/insert_dylib', '--inplace', '--all-yes', '--strip-codesig',
            '@executable_path/Frameworks/RUIN.dylib', packaged)
        verify_packaged(original_bytes, packaged.read_bytes())
        run('codesign', '--force', '--sign', '-', '--timestamp=none', packaged)
        run('codesign', '--verify', '--strict', packaged)
        count = verify_packaged(original_bytes, packaged.read_bytes())
        print(f'PASS: pinned insert_dylib and Apple ad-hoc signing preserve {count} original sections.')

        library = directory / 'fixture.dylib'
        slices = []
        for arch in ('arm64', 'arm64e'):
            thin = directory / f'fixture-{arch}.dylib'
            run('xcrun', '--sdk', 'iphoneos', 'clang', '-arch', arch, '-isysroot', sdk,
                '-miphoneos-version-min=18.0', '-dynamiclib', '-Wl,-no_adhoc_codesign',
                '-Wl,-install_name,@rpath/RUIN.dylib', source, '-o', thin)
            slices.append(thin)
        run('lipo', '-create', *slices, '-output', library)
        try:
            verify_dylib(library)
        except subprocess.CalledProcessError:
            pass
        else:
            raise AssertionError('Unsigned dylib passed distribution verification')
        run('codesign', '--force', '--sign', '-', '--timestamp=none', library)
        verify_dylib(library)
        print('PASS: synthetic arm64+arm64e fixture rejects unsigned dylibs and accepts a valid ad-hoc signature.')


if __name__ == '__main__':
    main()
