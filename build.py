#!/usr/bin/env python3
"""
Build GG-Debloat-123.bat from src/header.bat + src/payload.template.ps1.

The regular expressions live in ONE place: dev/patch_ui.py (PATCHES). This script converts them to .NET regex
syntax and writes them into the C# table of the payload, so the Python dev tool and the shipped PowerShell tool
cannot drift apart. Users never need Python; only maintainers run this.

  python build.py --setup-sha256 <sha256 of the official installer> --orig-asar-sha256 <...> --patched-asar-sha256 <...>
"""
import argparse, importlib.util, os, re, sys

ROOT = os.path.dirname(os.path.abspath(__file__))

spec = importlib.util.spec_from_file_location("patch_ui", os.path.join(ROOT, "dev", "patch_ui.py"))
patch_ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch_ui)


def to_dotnet(rx: str) -> str:
    rx = re.sub(r"\(\?P<(\w+)>", r"(?<\1>", rx)      # (?P<n>...) -> (?<n>...)
    rx = re.sub(r"\(\?P=(\w+)\)", r"\\k<\1>", rx)    # (?P=n)     -> \k<n>
    assert "(?P" not in rx, rx
    return rx


def cs_string(s: str) -> str:
    return '@"' + s.replace('"', '""') + '"'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--setup-sha256", required=True)
    ap.add_argument("--orig-asar-sha256", required=True)
    ap.add_argument("--patched-asar-sha256", required=True)
    ap.add_argument("--out", default=os.path.join(ROOT, "GG-Debloat-123.bat"))
    a = ap.parse_args()

    rows = []
    for pid, rx, repl, expect, why in patch_ui.PATCHES:
        rows.append(f'      new P({cs_string(pid)}, {cs_string(to_dotnet(rx))}, {-1 if expect is None else expect}, {cs_string(why)}),')
    table = "\n".join(rows)

    payload = open(os.path.join(ROOT, "src", "payload.template.ps1"), encoding="utf-8").read()
    payload = payload.replace("//@@PATCH_TABLE@@", table)
    for k, v in (("@@SETUP_SHA256@@", a.setup_sha256), ("@@ORIG_ASAR_SHA256@@", a.orig_asar_sha256),
                 ("@@PATCHED_ASAR_SHA256@@", a.patched_asar_sha256)):
        assert re.fullmatch(r"[0-9A-F]{64}", v.upper()), (k, v)
        payload = payload.replace(k, v.upper())
    assert "@@" not in payload, "unreplaced placeholder"
    header = open(os.path.join(ROOT, "src", "header.bat"), encoding="utf-8").read()
    assert header.rstrip().endswith("#<PAYLOAD>")
    text = header.rstrip("\r\n") + "\n" + payload
    # the payload must be plain ASCII so cmd/PowerShell never disagree about encoding
    bad = [c for c in text if ord(c) > 126]
    assert not bad, f"non-ASCII characters in the output: {set(bad)}"
    text = text.replace("\r\n", "\n").replace("\n", "\r\n")
    with open(a.out, "w", encoding="ascii", newline="") as f:
        f.write(text)
    print("wrote", a.out, len(text), "bytes;", len(rows), "edits")


if __name__ == "__main__":
    main()
