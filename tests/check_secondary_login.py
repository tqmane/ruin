#!/usr/bin/env python3
"""Host-only check of production SecondaryLogin Logos hooks with UIKit doubles."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/check-secondary-login'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    source = (ROOT / 'src/platform/SecondaryLogin.x').read_text()
    assert source.count('#import <UIKit/UIKit.h>') == 1
    fixture = OUT / 'SecondaryLoginUnderTest.x'
    fixture.write_text(source.replace('#import <UIKit/UIKit.h>', '#import "SecondaryLoginTestUI.h"')
                      .replace('#import <UIKit/UIGestureRecognizerSubclass.h>', ''))
    generated = OUT / 'SecondaryLoginUnderTest.m'
    with generated.open('w') as output:
        subprocess.run(['perl', 'vendor/logos/bin/logos.pl', '-c', 'generator=internal',
                        '-c', 'warnings=error', str(fixture.relative_to(ROOT))],
                       cwd=ROOT, stdout=output, check=True)
    executable = OUT / 'check_secondary_login'
    command = ['xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-fblocks', '-std=gnu11',
               '-Wall', '-Wextra', '-Werror', '-DRUIN_HOST_CHECK=1', '-I' + str(OUT), '-Itests']
    command.extend('-I' + str(path) for path in sorted({header.parent.relative_to(ROOT)
                   for header in (ROOT / 'src').glob('*/*.h')}))
    command.extend(['tests/check_secondary_login.m', *map(str, sorted(Path('src/known').glob('*.m'))), *map(str, sorted(Path('src/known/versions').glob('*.m'))), '-framework', 'Foundation',
                    '-framework', 'CoreGraphics', '-o', str(executable)])
    (OUT / 'compile-command.json').write_text(json.dumps(command, indent=2) + '\n')
    subprocess.run(command, cwd=ROOT, check=True)
    environment = os.environ.copy()
    for name in ('RUIN_SECONDARY_LOGIN', 'RUIN_OPEN_SECONDARY_LOGIN'):
        environment.pop(name, None)
    for mode in ('secondary', 'normal', 'abi'):
        subprocess.run([str(executable), mode], cwd=ROOT, env=environment, check=True, timeout=30)


if __name__ == '__main__':
    main()
