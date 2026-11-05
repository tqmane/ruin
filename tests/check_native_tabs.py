#!/usr/bin/env python3
import subprocess
import sys
from pathlib import Path


root = Path(__file__).resolve().parents[1]
binary = Path(sys.argv[1])
source = (root / "src/interface/InterfaceFeatures.m").read_text()
header = (root / "src/interface/InterfaceFeatures.h").read_text()
shopping_controller = "_TtC17LineTWCommerceTab27TWCommerceTabViewController"

assert "RUINNativeTabIdentifiers" in header
assert "RUINInterfaceTabShopping" in header and "RUINInterfaceTabShopping" in source
assert "RUINHideShoppingTabDefaultsKey" in header
assert 'RUINHideShoppingTabDefaultsKey = @"RUINInterfaceHideShoppingTab"' in source
assert "case RUINTabShoppingKind: return [defaults boolForKey:RUINHideShoppingTabDefaultsKey]" in source
assert "RUINInterfaceTabSettings" in header and "RUINInterfaceTabSettings" in source
strings = subprocess.run(["strings", "-a", str(binary)], check=True, capture_output=True, text=True).stdout
assert shopping_controller in strings
