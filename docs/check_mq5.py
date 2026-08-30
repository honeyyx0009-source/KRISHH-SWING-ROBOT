"""
Static validator for KRISHH_SwingRobot.mq5

No MQL5 compiler runs on Linux, so this catches the classes of mistake a
compiler would have caught:

  1. unbalanced braces / parentheses / brackets
  2. calls to functions that are neither defined in the file nor a known
     MQL5 built-in  (i.e. typos in function names)
  3. use of Inp* / g_* identifiers that were never declared (typos)
  4. declared-but-never-used functions and inputs (dead code)
  5. Print/PrintFormat/StringFormat/Comment format specifier counts that do
     not match the number of arguments supplied
  6. struct fields referenced that the struct does not declare

Usage:  python3 docs/check_mq5.py
Exit code 0 = clean, 1 = problems found.
"""

import re
import sys
from pathlib import Path

MQ5 = Path(__file__).resolve().parent.parent / "MQL5" / "Experts" / "KRISHH" / "KRISHH_SwingRobot.mq5"

# MQL5 built-ins and Standard Library members this EA is allowed to call.
BUILTINS = {
    # timeseries / indicators
    "iMA", "iADX", "iATR", "iRSI", "iMACD", "iClose", "iBarShift",
    "CopyBuffer", "CopyHigh", "CopyLow", "CopyClose", "CopyOpen", "CopyTime",
    "IndicatorRelease",
    # arrays
    "ArraySetAsSeries", "ArrayResize", "ArraySize",
    # math
    "MathMax", "MathMin", "MathAbs", "MathFloor",
    "NormalizeDouble",
    # strings
    "StringFormat", "StringSplit", "StringTrimLeft", "StringTrimRight",
    "StringToDouble", "DoubleToString", "IntegerToString", "EnumToString",
    # symbol / account
    "SymbolInfoDouble", "SymbolInfoInteger", "SymbolInfoString",
    "AccountInfoDouble", "AccountInfoInteger",
    # positions / orders
    "PositionsTotal", "PositionGetTicket", "PositionSelectByTicket",
    "PositionGetDouble", "PositionGetInteger", "PositionGetString",
    "OrderCalcMargin",
    # terminal globals
    "GlobalVariableSet", "GlobalVariableGet", "GlobalVariableCheck",
    "GlobalVariableDel",
    # time
    "TimeCurrent", "TimeToStruct",
    # output
    "Print", "PrintFormat", "Comment",
    # casts that look like calls
    "datetime", "int", "double", "long", "ulong", "string", "bool", "uint",
}

# CTrade members used via the `trade.` object
CTRADE_MEMBERS = {
    "SetExpertMagicNumber", "SetDeviationInPoints", "SetTypeFillingBySymbol",
    "SetAsyncMode", "LogLevel", "Buy", "Sell", "PositionModify",
    "PositionClose", "ResultRetcode", "ResultRetcodeDescription", "ResultPrice",
}

KEYWORDS = {
    "if", "else", "for", "while", "do", "switch", "case", "return", "break",
    "continue", "sizeof", "struct", "class", "enum", "input", "const", "static",
    "void", "new", "delete", "operator", "template", "typename", "default",
    "group",
}

problems = []
warnings = []


def strip_comments_and_strings(text):
    """Replace comments with spaces and string literals with "" placeholders."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j == -1 else j
            out.append(" " * (j - i))
            i = j
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j == -1 else j + 2
            out.append("".join(ch if ch == "\n" else " " for ch in text[i:j]))
            i = j
        elif c == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    j += 1
                    break
                j += 1
            out.append('""')
            i = j
        elif c == "'":
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == "'":
                    j += 1
                    break
                j += 1
            out.append("'x'")
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def check_balance(code):
    pairs = {"}": "{", ")": "(", "]": "["}
    stack = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch in "{([":
            stack.append((ch, line))
        elif ch in ")}]":
            if not stack:
                problems.append(f"line {line}: stray closing '{ch}'")
                continue
            open_ch, open_line = stack.pop()
            if open_ch != pairs[ch]:
                problems.append(
                    f"line {line}: '{ch}' closes '{open_ch}' opened on line {open_line}"
                )
    for open_ch, open_line in stack:
        problems.append(f"line {open_line}: '{open_ch}' never closed")


def main():
    if not MQ5.exists():
        print(f"NOT FOUND: {MQ5}")
        return 1

    raw = MQ5.read_text()
    code = strip_comments_and_strings(raw)

    print("=" * 78)
    print(f"Static check: {MQ5.name}  ({len(raw.splitlines())} lines)")
    print("=" * 78)

    # ---- 1. bracket balance ----
    check_balance(code)

    # ---- 2. declarations ----
    # function definitions/prototypes: <type> Name(...)
    func_def = re.compile(
        r"^\s*(?:void|bool|int|double|long|ulong|string|datetime|uint)\s+"
        r"([A-Za-z_]\w*)\s*\(", re.M)
    declared_funcs = set(func_def.findall(code))

    # inputs
    input_decl = re.compile(
        r"^\s*input\s+(?:group\s+)?[\w:]+\s+([A-Za-z_]\w*)\s*=", re.M)
    inputs = set(input_decl.findall(code))

    # globals: simple top-level declarations
    global_decl = re.compile(
        r"^\s*(?:double|int|bool|string|datetime|ulong|long|CTrade)\s+"
        r"([A-Za-z_][\w]*)\s*(?:\[\s*\]|=|;|,)", re.M)
    globals_found = set(global_decl.findall(code))
    # multi declarations on one line: double cHigh[], cLow[], ...
    for m in re.finditer(r"^\s*(?:double|datetime|int)\s+([^;{}()]+);", code, re.M):
        for part in m.group(1).split(","):
            name = part.strip().replace("[]", "").split("=")[0].strip()
            if re.fullmatch(r"[A-Za-z_]\w*", name):
                globals_found.add(name)

    # struct fields
    struct_fields = set()
    sm = re.search(r"struct\s+SetupInfo\s*\{(.*?)\}\s*;", code, re.S)
    if sm:
        for line in sm.group(1).splitlines():
            fm = re.match(r"\s*(?:int|double|string|bool)\s+([A-Za-z_]\w*)\s*;", line)
            if fm:
                struct_fields.add(fm.group(1))

    print(f"functions declared : {len(declared_funcs)}")
    print(f"inputs declared    : {len(inputs)}")
    print(f"globals declared   : {len(globals_found)}")
    print(f"SetupInfo fields   : {sorted(struct_fields)}")
    print("-" * 78)

    # ---- 3. calls to unknown functions ----
    called = set()
    for m in re.finditer(r"(\.?)\b([A-Za-z_]\w*)\s*\(", code):
        dot, name = m.group(1), m.group(2)
        if dot == ".":
            continue          # method call, handled separately
        if name in KEYWORDS:
            continue
        called.add(name)

    known = declared_funcs | BUILTINS | {"OnInit", "OnDeinit", "OnTick"}
    unknown = sorted(called - known)
    if unknown:
        for u in unknown:
            problems.append(f"call to unknown function '{u}()'")

    # method calls on `trade`
    for m in re.finditer(r"\btrade\.([A-Za-z_]\w*)\s*\(", code):
        if m.group(1) not in CTRADE_MEMBERS:
            problems.append(f"unknown CTrade member 'trade.{m.group(1)}()'")

    # ---- 4. unknown Inp*/g_* identifiers ----
    for m in re.finditer(r"\b(Inp[A-Za-z_]\w*)\b", code):
        if m.group(1) not in inputs:
            problems.append(f"undeclared input identifier '{m.group(1)}'")
    for m in re.finditer(r"\b(g_[A-Za-z_]\w*)\b", code):
        if m.group(1) not in globals_found:
            problems.append(f"undeclared global identifier '{m.group(1)}'")

    # ---- 5. struct field access ----
    for m in re.finditer(r"\bs\.([A-Za-z_]\w*)\b", code):
        if struct_fields and m.group(1) not in struct_fields:
            problems.append(f"SetupInfo has no field '{m.group(1)}'")

    # ---- 6. dead code ----
    for f in sorted(declared_funcs):
        if f in ("OnInit", "OnDeinit", "OnTick"):
            continue
        # count occurrences outside its own definition line
        uses = len(re.findall(rf"\b{f}\s*\(", code))
        if uses <= 1:
            warnings.append(f"function '{f}()' is declared but never called")
    for i in sorted(inputs):
        if len(re.findall(rf"\b{i}\b", code)) <= 1:
            warnings.append(f"input '{i}' is declared but never used")

    # ---- 7. format specifier vs argument count ----
    # work on the original text so we can still see the format strings
    fmt_call = re.compile(
        r"\b(PrintFormat|StringFormat)\s*\(\s*(\"(?:[^\"\\]|\\.)*\"(?:\s*\n\s*\"(?:[^\"\\]|\\.)*\")*)",
        re.S)
    for m in fmt_call.finditer(raw):
        fname = m.group(1)
        fstr = m.group(2)
        literal = "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', fstr))
        # count real conversion specifiers, skipping %%
        specs = re.findall(r"%(?!%)[-+ #0]*[\d.*]*(?:I64|ll|l|h)?[diufFeEgGxXocsp]", literal)
        nspec = len(specs)

        # find the matching close paren for this call
        start = m.start()
        open_idx = raw.index("(", start)
        depth = 0
        end = open_idx
        in_str = False
        while end < len(raw):
            ch = raw[end]
            if in_str:
                if ch == "\\":
                    end += 2
                    continue
                if ch == '"':
                    in_str = False
            else:
                if ch == '"':
                    in_str = True
                elif ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                    if depth == 0:
                        break
            end += 1
        body = raw[open_idx + 1:end]

        # split top-level commas
        args, depth, in_str, cur = [], 0, False, ""
        i = 0
        while i < len(body):
            ch = body[i]
            if in_str:
                cur += ch
                if ch == "\\":
                    cur += body[i + 1] if i + 1 < len(body) else ""
                    i += 2
                    continue
                if ch == '"':
                    in_str = False
            else:
                if ch == '"':
                    in_str = True
                    cur += ch
                elif ch in "([":
                    depth += 1
                    cur += ch
                elif ch in ")]":
                    depth -= 1
                    cur += ch
                elif ch == "," and depth == 0:
                    args.append(cur)
                    cur = ""
                else:
                    cur += ch
            i += 1
        if cur.strip():
            args.append(cur)

        nargs = max(0, len(args) - 1)   # first arg is the format string
        line_no = raw[:start].count("\n") + 1
        if nspec != nargs:
            problems.append(
                f"line {line_no}: {fname} has {nspec} format specifier(s) "
                f"but {nargs} argument(s)"
            )

    # ---- report ----
    if warnings:
        print("WARNINGS")
        for w in warnings:
            print(f"  ! {w}")
        print("-" * 78)

    if problems:
        print("PROBLEMS")
        for p in problems:
            print(f"  X {p}")
        print("-" * 78)
        print(f"FAILED: {len(problems)} problem(s), {len(warnings)} warning(s)")
        return 1

    print("brackets balanced        : OK")
    print("all calls resolve        : OK")
    print("all Inp*/g_* declared    : OK")
    print("struct field access      : OK")
    print("printf arg counts match  : OK")
    print("-" * 78)
    print(f"PASSED with {len(warnings)} warning(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
