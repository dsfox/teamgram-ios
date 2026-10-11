#!/usr/bin/env python3
"""ice9's brand laid over upstream's text files at build time (#194).

Upstream's Localizable.strings, InfoPlist.strings and AppIntentVocabulary.plist
stay in the tree exactly as upstream ships them, so a carry takes them whole.
Telegram/BUILD runs this on each of them and the app is built from the result:

  - brand.json's replacements, in order: on the values of a .strings file, on
    the whole text of a .plist;
  - brand.json's removals, by file name and language;
  - an overrides file in the same .strings format: an entry for a key upstream
    has replaces it where it stands, any other is added at the end.

Only the standard library: Bazel runs it with the host's python3, and
tests/test_ios_brand.py runs it the same way on the tree's files.

    brand.py --rules brand.json --language en [--overrides overrides/en.lproj/Localizable.strings] IN OUT
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re


class BrandRules:
    """What brand.json says: literal replacements in order, and keys to drop."""

    def __init__(self, replacements: list[tuple[str, str]], removals: dict[str, dict[str, list[str]]]):
        self.replacements = replacements
        self.removals = removals

    @classmethod
    def load(cls, path: pathlib.Path) -> "BrandRules":
        data = json.loads(path.read_text(encoding="utf-8"))
        return cls([(old, new) for old, new in data["replace"]], data.get("remove", {}))

    def branded(self, text: str) -> str:
        for old, new in self.replacements:
            text = text.replace(old, new)
        return text

    def removed(self, file_name: str, language: str) -> set[str]:
        table = self.removals.get(file_name, {})
        return set(table.get("*", [])) | set(table.get(language, []))


class StringsFile:
    """A .strings file as text: entries are found and rewritten where they
    stand, so comments, blank lines and upstream's order survive."""

    # An entry may span lines: a value holds literal newlines in a few places.
    ENTRY = re.compile(r'^[ \t]*"((?:[^"\\]|\\.)*)"(\s*=\s*)"((?:[^"\\]|\\.)*)"[ \t]*;[ \t]*(?:\r?\n)?', re.M | re.S)

    def __init__(self, text: str):
        self.text = text

    def entries(self) -> dict[str, str]:
        return {match.group(1): match.group(3) for match in self.ENTRY.finditer(self.text)}

    def branded(self, rules: BrandRules, removed: set[str], overrides: dict[str, str]) -> "StringsFile":
        seen: set[str] = set()

        def rewrite(match: re.Match) -> str:
            key, separator, value = match.group(1), match.group(2), match.group(3)
            seen.add(key)
            if key in overrides:
                value = overrides[key]
            elif key in removed:
                return ""
            else:
                value = rules.branded(value)
            return f'"{key}"{separator}"{value}";\n'

        text = self.ENTRY.sub(rewrite, self.text)
        added = [f'"{key}" = "{value}";\n' for key, value in overrides.items() if key not in seen]
        if added and not text.endswith("\n"):
            text += "\n"
        return StringsFile(text + "".join(added))


class BrandedFile:
    """One file of upstream's, branded for one language."""

    def __init__(self, source: pathlib.Path, language: str, rules: BrandRules, overrides: pathlib.Path | None):
        self.source = source
        self.language = language
        self.rules = rules
        self.overrides = StringsFile(overrides.read_text(encoding="utf-8")).entries() if overrides else {}

    def text(self) -> str:
        original = self.source.read_text(encoding="utf-8")
        if self.source.suffix == ".plist":
            return self.rules.branded(original)
        removed = self.rules.removed(self.source.name, self.language)
        return StringsFile(original).branded(self.rules, removed, self.overrides).text


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--rules", type=pathlib.Path, required=True)
    parser.add_argument("--language", required=True)
    parser.add_argument("--overrides", type=pathlib.Path)
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    arguments = parser.parse_args()
    branded = BrandedFile(arguments.source, arguments.language, BrandRules.load(arguments.rules), arguments.overrides)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(branded.text(), encoding="utf-8")


if __name__ == "__main__":
    main()
