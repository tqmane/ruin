# Logos build dependency

The unmodified `bin/` directory and `LICENSE.md` are from
[theos/logos](https://github.com/theos/logos) at commit
`365a4e7028234e90bc2cbc724e5c87607130d3b3`.

Logos runs at build time through Perl. RUIN selects the `internal` generator,
so the dylib does not link Substrate or libhooker. Generated Objective-C stays
under `build/logos/` and is not committed.

The upstream license and its exception for projects generated using Logos are
preserved in `LICENSE.md`. No changes were made to the upstream sources.
