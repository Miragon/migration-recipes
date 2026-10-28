#!/usr/bin/env python3
"""Check relative Markdown links and #anchors in this repository.

Usage: python3 tools/check-links.py [root]
Exit code 1 if a relative link points to a missing file or a missing anchor.
External (http/https/mailto) links are not checked.
"""
import os
import re
import sys
import unicodedata

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), ".."))
SKIP_DIRS = {".git", "node_modules", "target", "build", ".context", ".idea"}

LINK_RE = re.compile(r"(?<!!)\[(?:[^\]\[]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
IMG_RE = re.compile(r"!\[[^\]]*\]\(\s*<?([^)\s>]+)>?\s*\)")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
ANCHOR_RE = re.compile(r"<a\s+(?:id|name)=\"([^\"]+)\"", re.I)
FENCE_RE = re.compile(r"^\s*(```|~~~)")


def github_slug(text):
    text = re.sub(r"<[^>]+>", "", text)            # inline HTML
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)  # links -> text
    text = text.replace("`", "")
    text = text.strip().lower()
    out = []
    for ch in text:
        cat = unicodedata.category(ch)
        if ch in "-_ ":
            out.append("-" if ch == " " else ch)
        elif cat[0] in ("L", "N") or cat == "Mn":
            out.append(ch)
        # everything else (punctuation, symbols, emoji) is dropped
    return "".join(out)


def anchors_of(path, cache={}):
    if path in cache:
        return cache[path]
    anchors, counts, in_fence = set(), {}, False
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if FENCE_RE.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            for a in ANCHOR_RE.findall(line):
                anchors.add(a)
            m = HEADING_RE.match(line)
            if m:
                slug = github_slug(m.group(2))
                n = counts.get(slug, 0)
                anchors.add(slug if n == 0 else f"{slug}-{n}")
                counts[slug] = n + 1
    cache[path] = anchors
    return anchors


def md_files():
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for f in filenames:
            if f.endswith(".md"):
                yield os.path.join(dirpath, f)


def main():
    errors = 0
    for md in sorted(md_files()):
        in_fence = False
        with open(md, encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, 1):
                if FENCE_RE.match(line):
                    in_fence = not in_fence
                    continue
                if in_fence:
                    continue
                stripped = re.sub(r"`[^`]*`", "", line)  # ignore inline code
                for target in LINK_RE.findall(stripped) + IMG_RE.findall(stripped):
                    if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):
                        continue  # external
                    path_part, _, frag = target.partition("#")
                    dest = md if path_part == "" else os.path.normpath(os.path.join(os.path.dirname(md), path_part))
                    rel = os.path.relpath(md, ROOT)
                    if not os.path.exists(dest):
                        print(f"{rel}:{lineno}: missing file -> {target}")
                        errors += 1
                        continue
                    if frag and dest.endswith(".md") and os.path.isfile(dest):
                        if frag not in anchors_of(dest) and frag.lower() not in anchors_of(dest):
                            print(f"{rel}:{lineno}: missing anchor -> {target}")
                            errors += 1
    print(f"\n{errors} broken link(s)" if errors else "All relative links and anchors resolve.")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
