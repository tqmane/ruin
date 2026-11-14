"""Semantic localization checks and read-only reference collection (stdlib only)."""
from dataclasses import dataclass
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "resources/RUINResources.bundle"
LANGUAGES = ("en", "ja", "ko", "zh-Hans", "zh-Hant")
SOURCE_SUFFIXES = {".h", ".m", ".x", ".xm", ".mm", ".swift"}
SEMANTIC_KEY = re.compile(r"[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+")
LEXER = re.compile(r'''//[^\n]*|/\*.*?\*/|@?"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[A-Za-z_]\w*|\d+|\?\?|->|\+=|-=|\*=|/=|==|!=|<=|>=|\S''', re.S)


class LocalizationError(ValueError):
    """A catalog or source construct cannot be safely validated."""


@dataclass(frozen=True)
class Token:
    text: str
    start: int


def tokenize(source):
    return [Token(m[0], m.start()) for m in LEXER.finditer(source)
            if not m[0].startswith(("//", "/*"))]


def group_pairs(tokens):
    stack, pairs = [], {}
    closing = {")": "(", "]": "[", "}": "{"}
    for i, token in enumerate(tokens):
        if token.text in closing.values():
            stack.append(i)
        elif token.text in closing:
            if not stack or tokens[stack[-1]].text != closing[token.text]:
                raise LocalizationError(f"unbalanced source delimiter at offset {token.start}")
            start = stack.pop()
            pairs[start] = i
    if stack:
        raise LocalizationError(f"unclosed source delimiter at offset {tokens[stack[-1]].start}")
    return pairs


def decode_literal(text):
    """Decode ordinary ObjC/Swift quoted literals; reject unknown escape forms."""
    raw = text[2:-1] if text.startswith('@"') else text[1:-1]
    output, i = [], 0
    escapes = dict(zip('abefnrtv\\\"\'?', '\a\b\x1b\f\n\r\t\v\\\"\'?'))
    while i < len(raw):
        char = raw[i]
        i += 1
        if char != "\\":
            output.append(char)
            continue
        if i == len(raw):
            raise LocalizationError("incomplete string escape")
        char = raw[i]
        i += 1
        if char in escapes:
            output.append(escapes[char])
        elif char == "\n":
            pass
        elif char in "01234567":
            match = re.match(r"[0-7]{0,2}", raw[i:])[0]
            output.append(chr(int(char + match, 8)))
            i += len(match)
        elif char in "xuU":
            pattern = r"[0-9a-fA-F]+" if char == "x" else rf"[0-9a-fA-F]{{{4 if char == 'u' else 8}}}"
            match = re.match(pattern, raw[i:])
            if not match:
                raise LocalizationError("invalid numeric string escape")
            try:
                output.append(chr(int(match[0], 16)))
            except ValueError as error:
                raise LocalizationError("string escape outside Unicode") from error
            i += len(match[0])
        else:
            raise LocalizationError(f"unsupported string escape \\{char}")
    return "".join(output)


def strip_parentheses(tokens, start, end, pairs):
    while start < end and tokens[start].text == "(" and pairs[start] == end - 1:
        start, end = start + 1, end - 1
    return start, end


def conditional_parts(tokens, start, end, pairs):
    question, depth, i = None, 0, start
    while i < end:
        text = tokens[i].text
        if i in pairs:
            i = pairs[i] + 1
            continue
        if text == "?":
            if question is None:
                question = i
            depth += 1
        elif text == ":" and question is not None:
            depth -= 1
            if not depth:
                return (start, question), (question + 1, i), (i + 1, end)
        i += 1
    if question is not None:
        raise LocalizationError("incomplete conditional localization expression")
    return None


def literal_options(tokens, start, end, pairs, swift=False, formats=False, resolving=()):
    start, end = strip_parentheses(tokens, start, end, pairs)
    if start == end:
        raise LocalizationError("empty localization expression")
    parts = conditional_parts(tokens, start, end, pairs)
    if parts:
        condition, yes, no = parts
        # GNU a ?: b returns a in its true branch; it must also be statically known.
        if yes[0] == yes[1]:
            yes = condition
        return literal_options(tokens, *yes, pairs, swift, formats, resolving) | literal_options(
            tokens, *no, pairs, swift, formats, resolving)
    pieces = [t.text for t in tokens[start:end]]
    if pieces and all(p.startswith(('"', '@"')) for p in pieces) and (swift or pieces[0].startswith('@"')):
        return {("literal", "".join(decode_literal(p) for p in pieces))}
    if formats and pieces[:2] == ["RUINLocalizedString", "("] and pairs[start + 1] == end - 1:
        return {("key", key) for _, key in literal_options(tokens, start + 2, end - 1, pairs, swift)}
    if formats and end == start + 1 and re.fullmatch(r"[A-Za-z_]\w*", pieces[0]):
        name = pieces[0]
        if name in resolving:
            raise LocalizationError("cyclic localized format binding")
        binding = local_format_binding(tokens, name, start, pairs)
        if binding:
            return literal_options(tokens, *binding, pairs, swift, True, (*resolving, name))
    raise LocalizationError("unanalyzed dynamic localization expression: " + " ".join(pieces[:12]))


def is_declaration(tokens, i, end):
    if i and tokens[i - 1].text == "func":
        return True
    # These are the typed declaration/definition of this API, not key-variable calls.
    prefix = [t.text for t in tokens[max(0, i - 2):i]]
    params = [t.text for t in tokens[i + 2:end] if t.text not in ("_Nonnull", "_Nullable")]
    return (prefix == ["NSString", "*"] and len(params) == 3 and params[:2] == ["NSString", "*"]
            and end + 1 < len(tokens) and tokens[end + 1].text in (";", "{", "NS_FORMAT_ARGUMENT", "__attribute__"))


def source_references(source, swift=False):
    tokens = tokenize(source)
    pairs = group_pairs(tokens)
    references = set()
    for i, token in enumerate(tokens[:-1]):
        if token.text != "RUINLocalizedString" or tokens[i + 1].text != "(":
            continue
        end = pairs[i + 1]
        if is_declaration(tokens, i, end):
            continue
        try:
            references.update(key for _, key in literal_options(tokens, i + 2, end, pairs, swift))
        except LocalizationError as error:
            line = source.count("\n", 0, token.start) + 1
            raise LocalizationError(f"line {line}: {error}") from error
    return references


def localized_literal_keys(source, swift=False):
    """Compatibility API: collect literal/conditional keys, rejecting dynamic calls."""
    return source_references(source, swift)


def source_paths(source_root):
    return sorted(p for p in Path(source_root).rglob("*") if p.suffix in SOURCE_SUFFIXES)


def collect_references(source_root=ROOT / "src"):
    """Return the complete key union, or raise; never silently omit dynamic calls.

    Key spelling is intentionally checked by validate_catalogs, so this collector
    can also be used read-only during a migration before pruning old catalogs.
    """
    references = set()
    for path in source_paths(source_root):
        try:
            references.update(source_references(path.read_text(encoding="utf-8"), path.suffix == ".swift"))
        except LocalizationError as error:
            raise LocalizationError(f"{path}: {error}") from error
    return references


def decode_strings_literal(text):
    """Decode .strings escapes; Apple \\Uhhhh denotes one UTF-16 code unit."""
    escapes = {'"':'"', "\\":"\\", "n":"\n", "r":"\r", "t":"\t"}

    def replace(match):
        escape = match[1]
        if escape.startswith("U") and len(escape) == 5:
            return chr(int(escape[1:], 16))
        if escape in escapes:
            return escapes[escape]
        raise LocalizationError(f"unsupported .strings escape \\{escape}")

    value = re.sub(r"\\(U[0-9a-fA-F]{4}|.)", replace, text[1:-1], flags=re.S)
    try:
        return value.encode("utf-16-le", errors="surrogatepass").decode("utf-16-le")
    except UnicodeDecodeError as error:
        raise LocalizationError("unpaired UTF-16 .strings escape") from error


def load_catalog(path):
    """Read UTF-8 quoted key = value; pairs and comments, rejecting duplicates."""
    try:
        source = Path(path).read_text(encoding="utf-8-sig")
    except UnicodeDecodeError as error:
        raise LocalizationError(f"{path}: catalog is not valid UTF-8") from error
    tokens, catalog = tokenize(source), {}
    for i in range(0, len(tokens), 4):
        pair = [token.text for token in tokens[i:i+4]]
        line = source.count("\n", 0, tokens[i].start) + 1
        if (len(pair) != 4 or pair[1] != "=" or pair[3] != ";" or
                any(not re.fullmatch(r'"(?:\\.|[^"\\])*"', value, re.S) for value in pair[::2])):
            raise LocalizationError(f"{path}:{line}: expected quoted key = quoted value; pair")
        try:
            key, value = (decode_strings_literal(value) for value in pair[::2])
        except LocalizationError as error:
            raise LocalizationError(f"{path}:{line}: {error}") from error
        if key in catalog:
            raise LocalizationError(f"{path}:{line}: duplicate .strings key {key!r}")
        catalog[key] = value
    return catalog


def load_catalogs(bundle=BUNDLE):
    return {language: load_catalog(Path(bundle) / f"{language}.lproj/Localizable.strings") for language in LANGUAGES}


def format_signature(text):
    """Return vararg types in argument-index order, not presentation order.

    Fixed flags/width/precision do not consume arguments. Stars consume int;
    positional uses may reorder/reuse matching arguments but cannot mix modes,
    skip indices, or reuse an index with conflicting types. Unsupported forms
    (including %n) fail explicitly. This is a format contract, not C typechecking.
    """
    arguments, mode, next_index, i = {}, None, 1, 0

    def argument(index, kind):
        nonlocal mode, next_index
        current = "positional" if index is not None else "sequential"
        if mode is not None and current != mode:
            raise LocalizationError("mixed positional and sequential format arguments")
        mode = current
        if index is None:
            index, next_index = next_index, next_index + 1
        if index < 1:
            raise LocalizationError("format argument indices must start at 1")
        if index in arguments and arguments[index] != kind:
            raise LocalizationError(f"conflicting format types for argument {index}")
        arguments[index] = kind

    def index_at(position):
        match = re.match(r"([0-9]+)\$", text[position:])
        return (int(match[1]), position + len(match[0])) if match else (None, position)

    while i < len(text):
        if text[i] != "%":
            i += 1
            continue
        i += 1
        if i < len(text) and text[i] == "%":
            i += 1
            continue
        index, i = index_at(i)
        while i < len(text) and text[i] in "-+ #0'":
            i += 1
        for precision in (False, True):
            if precision:
                if i >= len(text) or text[i] != ".":
                    break
                i += 1
            if i < len(text) and text[i] == "*":
                star, i = index_at(i + 1)
                argument(star, "int")
            else:
                while i < len(text) and text[i].isdigit():
                    i += 1
        length = ""
        for candidate in ("hh", "ll", "h", "l", "j", "z", "t", "L", "q"):
            if text.startswith(candidate, i):
                length, i = candidate, i + len(candidate)
                break
        if i >= len(text):
            raise LocalizationError("incomplete format directive")
        conversion, i = text[i], i + 1
        if conversion in "diuoxX" and length in ("", "hh", "h", "l", "ll", "q", "j", "z", "t"):
            length = "ll" if length == "q" else length
            kind = ("int" if conversion in "di" else "unsigned int") + (":" + length if length else "")
        elif conversion == "@" and not length:
            kind = "object"
        elif conversion in "fFeEgGaA" and length in ("", "l", "L"):
            kind = "long double" if length == "L" else "double"
        elif conversion in "cCsSp" and not length:
            kind = {"c":"int", "C":"unichar", "s":"char *", "S":"unichar *", "p":"void *"}[conversion]
        elif conversion in "cs" and length == "l":
            kind = "wint_t" if conversion == "c" else "wchar_t *"
        else:
            raise LocalizationError(f"unsupported format directive %{length}{conversion}")
        argument(index, kind)
    if arguments and max(arguments) != len(arguments):
        raise LocalizationError("positional format has missing argument indices")
    return tuple(arguments[index] for index in range(1, len(arguments) + 1))


def validate_catalogs(catalogs, references):
    if set(catalogs) != set(LANGUAGES):
        raise LocalizationError("expected exactly the five supported language catalogs")
    english = catalogs["en"]
    if not english:
        raise LocalizationError("English catalog is empty")
    for key in set(english) | set(references):
        if not isinstance(key, str) or not SEMANTIC_KEY.fullmatch(key):
            raise LocalizationError(f"invalid semantic key {key!r}")
    missing = set(references) - set(english)
    unused = set(english) - set(references)
    if missing or unused:
        raise LocalizationError(f"missing referenced keys: {sorted(missing)}; unused catalog keys: {sorted(unused)}")
    for language, catalog in catalogs.items():
        if set(catalog) != set(english):
            raise LocalizationError(f"{language}: missing translations {sorted(set(english)-set(catalog))}; extra keys {sorted(set(catalog)-set(english))}")
        for key, value in catalog.items():
            if not isinstance(value, str) or not value.strip():
                raise LocalizationError(f"{language}/{key}: empty or non-string translation")
            try:
                if format_signature(value) != format_signature(english[key]):
                    raise LocalizationError("format signature mismatch against English")
            except LocalizationError as error:
                raise LocalizationError(f"{language}/{key}: {error}") from error


def expression_end(tokens, start, end, pairs, terminator):
    i = start
    while i < end:
        if tokens[i].text == terminator:
            return i
        i = pairs[i] + 1 if i in pairs else i + 1
    return end


def local_format_binding(tokens, name, use, pairs):
    """Resolve an initialized local NSString, with no intervening reassignment."""
    def scope(index):
        return tuple(sorted(i for i, end in pairs.items() if tokens[i].text == "{" and i < index < end))

    visible = scope(use)
    candidates = [i for i in range(2, use - 1)
                  if [t.text for t in tokens[i-2:i+2]] == ["NSString", "*", name, "="]
                  and visible[:len(scope(i))] == scope(i)]
    if not candidates:
        return None
    declaration = max(candidates, key=lambda i: (len(scope(i)), i))
    end = expression_end(tokens, declaration + 2, use, pairs, ";")
    if end == use:
        return None
    for i in range(end + 1, use - 1):
        if tokens[i].text == name and tokens[i+1].text in ("=", "+=", "-=", "*=", "/="):
            raise LocalizationError(f"localized format binding {name!r} was reassigned")
    return declaration + 2, end


def validate_format_calls(source, english, swift=False):
    """Check NSString localized-format arity, including simple local NSString flow."""
    tokens = tokenize(source)
    pairs = group_pairs(tokens)
    for i, token in enumerate(tokens[:-1]):
        if token.text not in ("stringWithFormat", "stringByAppendingFormat") or tokens[i+1].text != ":":
            continue
        brackets = [start for start, end in pairs.items() if tokens[start].text == "[" and start < i < end]
        if not brackets:
            continue
        end = pairs[max(brackets)]
        stop = expression_end(tokens, i + 2, end, pairs, ",")
        start, format_end = strip_parentheses(tokens, i + 2, stop, pairs)
        localized = any(t.text == "RUINLocalizedString" for t in tokens[start:format_end])
        if format_end == start + 1:
            binding = local_format_binding(tokens, tokens[start].text, start, pairs)
            localized = binding is not None and any(t.text == "RUINLocalizedString" for t in tokens[binding[0]:binding[1]])
        if not localized:
            continue
        options = literal_options(tokens, start, format_end, pairs, swift, formats=True)
        count, argument_start = 0, stop + 1
        while argument_start < end:
            next_stop = expression_end(tokens, argument_start, end, pairs, ",")
            if next_stop == argument_start:
                raise LocalizationError("empty NSString format argument")
            count += 1
            argument_start = next_stop + 1
        for kind, value in options:
            if kind == "key" and value not in english:
                raise LocalizationError(f"missing format key {value!r}")
            expected = len(format_signature(english[value] if kind == "key" else value))
            if count != expected:
                line = source.count("\n", 0, token.start) + 1
                raise LocalizationError(f"line {line}: format arity for {value!r}: expected {expected}, got {count}")


def validate_repository(root=ROOT):
    root = Path(root)
    catalogs = load_catalogs(root / "resources/RUINResources.bundle")
    references = collect_references(root / "src")
    validate_catalogs(catalogs, references)
    for path in source_paths(root / "src"):
        try:
            validate_format_calls(path.read_text(encoding="utf-8"), catalogs["en"], path.suffix == ".swift")
        except LocalizationError as error:
            raise LocalizationError(f"{path}: {error}") from error
    return references


class LocalizationTests(unittest.TestCase):
    def test_repository(self):
        self.assertTrue(validate_repository())

    def catalogs(self, values=None):
        return {language: dict(values or {"reader.title":"Readers"}) for language in LANGUAGES}

    def test_reference_union_and_declarations(self):
        source = r'''
            NSString *RUINLocalizedString(NSString *key);
            NSString *RUINLocalizedString(NSString *key) { return key; }
            static inline NSString *RUINLocalizedString(NSString *key) NS_FORMAT_ARGUMENT(1);
            // RUINLocalizedString(@"ignored.comment")
            id text = @"RUINLocalizedString(@\"ignored.string\")";
            RUINLocalizedString([value isEqual:@"ignored.condition"]
                ? @"reader.title" : (other ? @"reader.empty" : @"reader.error"));
            RUINLocalizedString((@"reader." "joined"));
        '''
        expected = {"reader.title","reader.empty","reader.error","reader.joined"}
        self.assertEqual(localized_literal_keys(source),expected)
        self.assertEqual(localized_literal_keys('RUINLocalizedString(flag ? "reader.title" : "reader.empty")',True),
                         {"reader.title","reader.empty"})
        with tempfile.TemporaryDirectory() as directory:
            Path(directory,"sample.x").write_text(source)
            self.assertEqual(collect_references(directory),expected)

    def test_dynamic_keys_fail_instead_of_disappearing(self):
        for expression in ('key', '[keys firstObject]', 'makeKey(@"reader.title")',
                           'flag ? @"reader.title" : key', '@"reader.title", other', '"reader.title"'):
            with self.subTest(expression=expression), self.assertRaisesRegex(LocalizationError,"dynamic"):
                localized_literal_keys(f"RUINLocalizedString({expression});")

    def test_escaped_literals(self):
        self.assertEqual(localized_literal_keys(r'RUINLocalizedString(@"reader\x2etitle");'),{"reader.title"})
        with self.assertRaisesRegex(LocalizationError,"unsupported string escape"):
            localized_literal_keys(r'RUINLocalizedString(@"reader.\(dynamic)");')

    def test_missing_translation_and_nonempty_values(self):
        catalogs = self.catalogs()
        del catalogs["ko"]["reader.title"]
        with self.assertRaisesRegex(LocalizationError,"ko: missing translations"):
            validate_catalogs(catalogs,{"reader.title"})
        for value in ("", " \n", 12):
            catalogs = self.catalogs(); catalogs["ja"]["reader.title"] = value
            with self.assertRaisesRegex(LocalizationError,"empty or non-string"):
                validate_catalogs(catalogs,{"reader.title"})

    def test_missing_conditional_branch_and_unused(self):
        refs = localized_literal_keys('RUINLocalizedString(flag ? @"reader.title" : @"reader.empty");')
        with self.assertRaisesRegex(LocalizationError,"missing referenced keys.*reader.empty"):
            validate_catalogs(self.catalogs(),refs)
        with self.assertRaisesRegex(LocalizationError,"unused catalog keys.*reader.title"):
            validate_catalogs(self.catalogs(),set())

    def test_semantic_key_contract(self):
        for key in ("既読者一覧", "readerTitle", "reader.titleCase", "Reader.title", "reader", "reader..title", "reader.1title"):
            with self.subTest(key=key), self.assertRaisesRegex(LocalizationError,"invalid semantic key"):
                validate_catalogs(self.catalogs({key:"Readers"}),{key})
        validate_catalogs(self.catalogs({"read_control.reader_2.title":"Readers"}),{"read_control.reader_2.title"})

    def test_strings_pairs_comments_and_utf8(self):
        source = r'''
            // "ignored.comment" = "No";
            /* "ignored.block" = "No"; */
            "reader.title" /* between tokens */ = "既読者一覧 한국어 简体 繁體 😀";
            "reader.escaped" = "line\nnext\ttab\rquote\"slash\\ // literal /* literal */";
        '''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory,"Localizable.strings")
            path.write_text("\ufeff"+source, encoding="utf-8")
            self.assertEqual(load_catalog(path), {
                "reader.title":"既読者一覧 한국어 简体 繁體 😀",
                "reader.escaped":'line\nnext\ttab\rquote"slash\\ // literal /* literal */',
            })

    def test_strings_unicode_escapes_are_utf16_units(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory,"Localizable.strings")
            path.write_text(r'"reader.title" = "\U65e5\U672c \UD83D\UDE00 café \\U0041";'
                            r'"reader.units" = "\U0001F600";', encoding="utf-8")
            self.assertEqual(load_catalog(path), {
                "reader.title":"日本 😀 café \\U0041",
                "reader.units":"\x01F600",  # Four digits consumed, not C's eight-digit scalar.
            })
            self.assertEqual(decode_literal(r'"\U0001F600"'), "😀")

    def test_duplicate_strings_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory,"Localizable.strings")
            for second in ('"reader.title"', r'"reader.\U0074itle"'):
                path.write_text('"reader.title" = "A"; '+second+' = "B";', encoding="utf-8")
                with self.subTest(second=second), self.assertRaisesRegex(LocalizationError,"duplicate .strings key"):
                    load_catalog(path)

    def test_malformed_strings_and_non_string_values(self):
        malformed = (
            '"reader.title" = "A"', '"reader.title" "A";', '"reader.title" = ;',
            '"reader.title" = 1;', 'reader.title = "A";', '{"reader.title" = "A";}',
            '"reader.title" = ("A");', '"reader.title" = "A;',
            '"reader.title" = "A"; /* unclosed',
            r'"reader.title" = "\x41";', r'"reader.title" = "\U12g4";',
            r'"reader.title" = "\UD83D";', r'"reader.title" = "\UDE00";',
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory,"Localizable.strings")
            for source in malformed:
                path.write_text(source, encoding="utf-8")
                with self.subTest(source=source), self.assertRaises(LocalizationError):
                    load_catalog(path)
            path.write_bytes(b'"reader.title" = "\xff";')
            with self.assertRaisesRegex(LocalizationError,"not valid UTF-8"):
                load_catalog(path)

    def test_english_format_contract_and_reordering(self):
        values = {"reader.count":"%ld readers: %@ (100%%)"}
        catalogs = self.catalogs(values)
        catalogs["ja"]["reader.count"] = "%2$@: %1$ld"
        validate_catalogs(catalogs,set(values))
        for bad in ("%lu %@", "%ld", "%@ %ld", "%ld %@ %@"):
            catalogs["ja"]["reader.count"] = bad
            with self.subTest(bad=bad), self.assertRaisesRegex(LocalizationError,"format signature mismatch"):
                validate_catalogs(catalogs,set(values))

    def test_format_width_precision_lengths_and_escapes(self):
        self.assertEqual(format_signature("100%% %08.3ld %@"),("int:l","object"))
        self.assertEqual(format_signature("%%%lu"),("unsigned int:l",))
        self.assertEqual(format_signature("%*.*f %@"),("int","int","double","object"))
        self.assertEqual(format_signature("%3$*1$.*2$f %4$@"),("int","int","double","object"))
        self.assertEqual(format_signature("%1$@ / %1$@"),("object",))
        self.assertEqual(format_signature("%hhd %hd %lld %jd %zu %td"),
                         ("int:hh","int:h","int:ll","int:j","unsigned int:z","int:t"))
        for bad in ("%", "%n", "%Q", "%1$@ %ld", "%*2$d", "%0$@", "%2$@", "%1$@ %1$ld", "%l@", "%5%"):
            with self.subTest(bad=bad), self.assertRaises(LocalizationError):
                format_signature(bad)

    def test_direct_conditional_and_fallback_format_arity(self):
        english = {"reader.one":"%@", "reader.other":"%ld %@", "reader.percent":"100%%"}
        validate_format_calls('[NSString stringWithFormat:RUINLocalizedString(@"reader.other"), (long)n, [names objectAtIndex:0]];',english)
        validate_format_calls('[text stringByAppendingFormat:(RUINLocalizedString(@"reader.one") ?: @"%@"), block(1,2)];',english)
        validate_format_calls('[NSString stringWithFormat:RUINLocalizedString(@"reader.percent")];',english)
        for source in ('[NSString stringWithFormat:RUINLocalizedString(@"reader.other"), n];',
                       '[text stringByAppendingFormat:RUINLocalizedString(@"reader.one"), a, b];',
                       '[NSString stringWithFormat:RUINLocalizedString(flag ? @"reader.one" : @"reader.other"), a];'):
            with self.subTest(source=source), self.assertRaisesRegex(LocalizationError,"format arity"):
                validate_format_calls(source,english)

    def test_local_nsstring_format_flow(self):
        english = {"compatibility.partial.message":"LINE %@ / %@"}
        source = 'void Show(void) { NSString *format = RUINLocalizedString(@"compatibility.partial.message"); '
        validate_format_calls(source+'[NSString stringWithFormat:format, version, build]; }',english)
        with self.assertRaisesRegex(LocalizationError,"format arity"):
            validate_format_calls(source+'[NSString stringWithFormat:format, version]; }',english)
        with self.assertRaisesRegex(LocalizationError,"reassigned"):
            validate_format_calls(source+'format = other; [NSString stringWithFormat:format, version, build]; }',english)


if __name__ == "__main__":
    unittest.main()
