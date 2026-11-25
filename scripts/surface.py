#!/usr/bin/env python3
"""Переключатель поверхности диалога: /pc и /telegram.

Печатает короткую сводку по репозиторию и запоминает, с какой поверхности продолжаем.
Вызывается quick-командой Hermes (без LLM, без токенов), поэтому работает и в Telegram.

    python scripts/surface.py pc
    python scripts/surface.py telegram
"""

import datetime
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
MARKER = pathlib.Path.home() / "AppData/Local/hermes/state/surface.txt"


def git(*args: str) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", str(REPO), *args],
            capture_output=True, text=True, timeout=20,
            encoding="utf-8", errors="replace",
        )
        return out.stdout.strip()
    except Exception as error:  # git нет, репозиторий недоступен — не повод падать
        return f"(git: {error})"


def head() -> str:
    return git("log", "-1", "--format=%h %s") or "—"


def dirty() -> list[str]:
    raw = git("status", "--short")
    return [line for line in raw.splitlines() if line.strip()]


def open_questions(limit: int = 4) -> list[str]:
    path = REPO / "docs" / "state.md"
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        return []
    block = text.split("## Открытые вопросы", 1)
    if len(block) < 2:
        return []
    items: list[str] = []
    for line in block[1].splitlines():
        line = line.strip()
        if line.startswith("- **"):
            title = line[4:].split("**", 1)[0].rstrip(":.")
            items.append(title)
        elif line.startswith("## "):
            break
    return items[:limit]


def main() -> int:
    target = (sys.argv[1] if len(sys.argv) > 1 else "").strip().lower()
    if target not in {"pc", "telegram"}:
        print("использование: /pc или /telegram")
        return 1

    try:
        MARKER.parent.mkdir(parents=True, exist_ok=True)
        MARKER.write_text(
            target + " " + datetime.datetime.now().isoformat(timespec="seconds") + "\n",
            encoding="utf-8",
        )
    except Exception:
        pass  # маркер — удобство, а не условие работы

    changes = dirty()
    questions = open_questions()

    if target == "pc":
        print("Поверхность: ПК")
        print("HEAD: " + head())
        if changes:
            print("Незакоммичено: " + str(len(changes)) + " файл(ов)")
            for line in changes[:6]:
                print("  " + line)
            print("На ПК первым делом: git add -A && git commit, иначе правки потеряются.")
        else:
            print("Дерево чистое — можно продолжать с ПК сразу.")
        if questions:
            print("Открыто: " + "; ".join(questions))
        print("Продолжить на ПК: открой проект и сессию этого чата (или hermes --resume).")
        print("Сводка: docs/state.md")
    else:
        print("Поверхность: Telegram")
        print("HEAD: " + head())
        print("Дерево: " + ("чистое" if not changes else f"{len(changes)} изменённых файл(ов)"))
        if questions:
            print("Открыто: " + "; ".join(questions))
        print("Сводка: docs/state.md — читаю её перед правками.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
