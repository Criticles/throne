"""Грубая проверка: баланс скобок в Swift-файлах без компилятора.

Это не парсер Swift, а страховка от опечаток вроде потерянной скобки:
строки и комментарии вырезаются конечным автоматом, затем проверяется стек.
"""
import pathlib
import sys

PAIRS = {"{": "}", "(": ")", "[": "]"}
CLOSE = {v: k for k, v in PAIRS.items()}


def strip_code(src: str) -> str:
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            i = src.find("\n", i)
            if i == -1:
                break
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j == -1 else j + 2
            continue
        if src.startswith('"""', i):
            j = src.find('"""', i + 3)
            out.append('""')
            i = n if j == -1 else j + 3
            continue
        if src.startswith('#"', i):
            j = src.find('"#', i + 2)
            out.append('""')
            i = n if j == -1 else j + 2
            continue
        if c == '"':
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == '"':
                    break
                j += 1
            out.append('""')
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def check(path: pathlib.Path) -> bool:
    code = strip_code(path.read_text(encoding="utf-8"))
    stack = []
    for pos, ch in enumerate(code):
        if ch in PAIRS:
            stack.append((ch, pos))
        elif ch in CLOSE:
            if not stack or stack[-1][0] != CLOSE[ch]:
                line = code.count("\n", 0, pos) + 1
                print(f"FAIL {path}: лишняя '{ch}' на строке {line}")
                return False
            stack.pop()
    if stack:
        ch, pos = stack[-1]
        line = code.count("\n", 0, pos) + 1
        print(f"FAIL {path}: не закрыта '{ch}' со строки {line}")
        return False
    return True


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "ios")
    files = sorted(root.rglob("*.swift"))
    bad = 0
    for path in files:
        if not check(path):
            bad += 1
    print(f"проверено файлов: {len(files)}, с ошибками: {bad}")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
