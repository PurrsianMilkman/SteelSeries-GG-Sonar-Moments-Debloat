#!/usr/bin/env python3
"""
Patch the SteelSeries GG Electron UI (resources/app.asar) into a lean Sonar + Moments client:
no account requirement, no ads/news/promos, no Engine dependency, UI-side telemetry cut.

  python patch_ui.py --src <original app.asar> --out <patched app.asar>   # build
  python patch_ui.py --src <original app.asar> --dry-run                  # only count matches
  python patch_ui.py --src <original app.asar> --extract <dir>            # unpack, to hunt new anchors
  python patch_ui.py --src <original app.asar> --roundtrip --out x.asar   # self-test (must equal the source)

Every edit is a REGULAR EXPRESSION built from stable words (property names such as `.Engine`, `.startupAllowed`,
`getIsLoginSkipped`, log strings, route paths) and CAPTURES the minifier-assigned identifiers (`a.T1`, `Dn.U`, ...), which
change between GG releases. Each edit has an expected match count; if any differs the tool aborts and writes nothing.
Run it on the ORIGINAL asar, never on one it already patched.
"""
import argparse, hashlib, json, re, struct, sys

E = r'\(0,\w+\.\w+\)'          # a redux-saga effect creator, e.g. (0,a.T1)  /  (0,a.yJ).  Note: minified code has NO space after `yield`.
CE = r'\w+\.createElement'      # React.createElement under any alias


class PatchError(Exception):
    pass


def _footer_settings_only(text):
    """sub(): keep only SONAR/MOMENTS side-nav items and, in the footer, only the Settings button."""
    def sub(m):
        fn = re.search(r'function ' + re.escape(m['set']) + r'\([^)]*\)\{.{0,900}', text, re.S)
        if not fn or 'common.settings' not in fn.group(0):
            raise PatchError(f"footer button {m['set']} is not the Settings button; the footer layout changed")
        ce = m['ce']
        return (f'{ce}({m["ul"]},null,{m["s"]}.filter(x=>x&&(x.key==="SONAR"||x.key==="MOMENTS"))),'
                f'{ce}({m["ft"]},null,{ce}({m["set"]},null))')   # ce = "<React alias>.createElement"
    return sub


def _root_saga_log(text):
    """sub(): make a saga exception visible in GG's own electron-log.txt (otherwise it dies in the renderer console)."""
    lg = re.search(r'([\w$]+)\.logMessage,"Skipping initialization for non-main window"', text)
    if not lg:
        raise PatchError("cannot find the UI logger identifier")
    L = lg.group(1)
    return lambda m: (f'catch({m["e"]}){{(0,{L}.logMessage)("[ssgg-debloat] root saga error: "+({m["e"]}&&{m["e"]}.stack||{m["e"]})),'
                      f'{m["e"]} instanceof Error&&console.error(`An error occurred in the root saga: ${{{m["e"]}.message}}`)}}')


# (id, regex, replacement str-or-callable-factory, expected matches (None = at least 1), why)
# A replacement may be a plain string with \g<name> groups, or a function text->(match->str) for edits needing a check.
PATCHES = [
    # --- start-up: never wait for things only the Engine/the core's startup gate can provide -------------------------
    ("init-no-engine-wait",
     rf'let (?P<v>\w+)=yield{E}\((?P<ch>\w+)\);for\(;(?P=v)\.payload\.app!==\w+\.\w+\.Engine\|\|!(?P=v)\.payload\.isEnabled;\)(?P=v)=yield{E}\((?P=ch)\);',
     "", 1, "UI init blocked until an 'Engine enabled' event"),
    ("init-no-startup-allowed-wait",
     rf'let (?P<v>\w+)=yield{E}\((?P<ch>\w+)\);for\(;!(?P=v)\.startupAllowed;\)(?P=v)=yield{E}\((?P=ch)\);',
     "", 1, "core grants /startup/allowed only after the Engine reports device pre-connection"),
    ("init-settings-nonblocking",
     rf'let (?P<v>\w+)=yield{E}\(\[(?P<s>\w+\.\w+)\.fulfilled,(?P=s)\.rejected\]\);for\(;(?P=s)\.rejected\.match\((?P=v)\);\)'
     rf'yield{E}\(\w+\.logMessage,"Failed to load settings, retrying\.\.\."\),yield{E}\(500\),yield{E}\(\(0,(?P=s)\)\(\)\),'
     rf'(?P=v)=yield{E}\(\[(?P=s)\.fulfilled,(?P=s)\.rejected\]\);',
     "", 1, "second settings wait never completed with the Engine off; the fetch still runs and fills the store"),
    ("init-no-pinnable-tabs-wait",
     rf'yield{E}\(\[{E}\(\w+\.\w+\.fulfilled\),{E}\(\w+\.\w+\.fulfilled\)\]\),',
     "", None, "(123+) waits for getPinnableTabs/getAppsTray 'fulfilled'; a rejected core call would hang start-up"),
    ("init-no-login-screen",
     rf'(?P<c>\w+)=!\w+&&!\w+;(?=if\((?P=c)\)\{{const \w+=yield{E}\(\w+\.getRouter\);yield{E}\(\w+\.navigate,\w+\.LOGIN\)\}})',
     lambda m: f'{m["c"]}=!1;', 1, "never route to the login screen at start-up"),
    ("route-restore-no-device-wait",
     rf'if\(yield(?P<e1>{E})\(\w+\.\w+\),yield(?P<e2>{E})\((?P<sel>\w+\.\w+)\)\)return void\(0,(?P<r>\w+)\.getRouter\)\(\)\.navigate\((?P<R>\w+)\.NEWS\);'
     rf'(?=let \w+;try\{{\w+=yield{E}\(\w+\.\w+\),""===\w+&&\(\w+=\w+\.HOME\))',
     lambda m: f'if(yield {m["e2"]}({m["sel"]}))return void(0,{m["r"]}.getRouter)().navigate({m["R"]}.SONAR);',
     1, "restoring the last route waited for the Engine's device list"),
    ("logout-saga-keeps-sonar-on",
     rf'try\{{yield{E}\({E}\(\{{app:\w+\.\w+\.Sonar,isEnabled:!1\}}\)\);const (?P<e>\w+)=yield(?P<call>{E})\((?P<c>\w+\.\w+)\);'
     rf'(?P=e)&&\(yield(?P<put>{E})\(\(0,(?P<s>\w+)\.setUser\)\((?P=e)\)\),yield{E}\(\(0,\w+\.getRouter\)\(\)\.navigate,\w+\.LOGIN\)\)\}}',
     lambda m: f'try{{const {m["e"]}=yield {m["call"]}({m["c"]});{m["e"]}&&(yield {m["put"]}((0,{m["s"]}.setUser)({m["e"]})))}}catch({m["e"]}){{}}',
     1, "signed-out start-up fires the logout action, which switched Sonar OFF and navigated to /login"),
    ("dbg-root-saga-error",
     r'catch\((?P<e>\w+)\)\{(?P=e) instanceof Error&&console\.error\(`An error occurred in the root saga: \$\{(?P=e)\.message\}`\)\}',
     _root_saga_log, 1, "a saga exception otherwise only reaches the renderer console"),

    # --- account gates --------------------------------------------------------------------------------------------
    ("guard-always-pass",
     r'(?P<n>\w+)=(?P<e>\w+)\.isLoggedIn\|\|(?P=e)\.isLoginSkipped,(?P=n)\?(?P=e)\.children',
     lambda m: f'{m["n"]}=!0,{m["n"]}?{m["e"]}.children', 1, "route guard bounced signed-out users to /login"),
    ("sonar-no-signin-splash",
     r'isLoginSkipped:\(0,\w+\.getIsLoginSkipped\)\(\w+\),(?=sonarDataFetched:)',
     "isLoginSkipped:!1,", 1, "Sonar page showed a sign-in promo splash instead of the mixer"),
    ("moments-no-signin-splash",
     r'isLoginSkipped:\(0,\w+\.getIsLoginSkipped\)\(\w+\),(?=isScanningClips:)',
     "isLoginSkipped:!1,", 1, "Moments page showed a sign-in prompt instead of the clips"),
    ("moments-nav-no-lock",
     r'\(0,\w+\.\w+\)\(\w+\.getIsLoginSkipped\)(?=,\{iso:)',
     "!1", 1, "Moments side-nav entry showed a locked state when signed out"),

    # --- landing page: Sonar, not News; drop News/Giveaways/Loadouts routes --------------------------------------
    ("router-fallback-sonar",
     rf'(path:"\*",element:{CE}\(\w+\.\w+,\{{to:\w+\.)NEWS(\}}\))',
     lambda m: f'{m[1]}SONAR{m[2]}', 1, "unknown routes fell back to News"),
    ("router-home-sonar",
     r'function\((?P<e>\w+),(?P<t>\w+)\)\{return (?P=t)\?(?P<R>\w+)\.NEWS:(?P=e)===\w+\.\w+\.QUICKSET\?(?P=R)\.QUICKSET:(?P=R)\.NEWS\}',
     lambda m: f'function({m["e"]},{m["t"]}){{return {m["R"]}.SONAR}}', 1, "'home' redirected to News/Loadouts"),
    ("route-news-off", r'path:"news/\*"', 'path:"__off_news/*"', 1, "News page (ads/promos)"),
    ("route-giveaways-off", r'path:"giveaways/\*"', 'path:"__off_giveaways/*"', 1, "Giveaways page (ads)"),
    ("route-quickset-off", r'path:"quickset/\*"', 'path:"__off_quickset/*"', 1, "Loadouts page (needs Engine)"),
    ("state-default-app-sonar", r'(activeApplication:\w+\.\w+\.)NEWS(,skipLoginModalOpen)',
     lambda m: f'{m[1]}SONAR{m[2]}', None, "initial activeApplication (module is duplicated across chunks)"),
    ("state-default-home-sonar", r'(homeApp:\w+\.\w+\.)NEWS(\})',
     lambda m: f'{m[1]}SONAR{m[2]}', None, "initial homeApp (module is duplicated across chunks)"),

    # --- side nav: only Sonar + Moments; footer: only Settings --------------------------------------------------
    ("nav-sonar-moments-only",
     rf'(?P<ce>{CE})\((?P<ul>\w+),null,(?P<s>\w+)\),(?P=ce)\((?P<ft>\w+),null,(?P=ce)\(\w+,null\),(?P=ce)\(\w+,null\),(?P=ce)\(\w+,null\),(?P=ce)\((?P<set>\w+),null\)\)',
     _footer_settings_only, 1, "nav items except SONAR/MOMENTS; footer Account(sign-in nag)/Discord/Feedback buttons"),

    # --- promos inside the apps we keep + UI-side telemetry ---------------------------------------------------------
    ("sonar-no-contentful-toast",
     rf'\w+&&!\w+&&\w+&&(?={CE}\(\w+,\{{contentfulData:\w+,onClickDismiss:\w+,inAppToastDismissed:\w+,className:"InAppToast"\}}\))',
     "!1&&", 1, "Sonar in-app promo toast (Contentful)"),
    ("moments-no-promo-flyout",
     r'activePromos:(?:\(0,\w+\.\w+\)|\w+)\((?P<e>\w+)\),flyoutContent:\w+\((?P=e)\),',
     "activePromos:[],flyoutContent:void 0,", 1, "Moments promo flyout"),
    ("renderer-sentry-off",
     r'dsn:"https://[0-9a-f]+@[a-z0-9]+\.ingest\.sentry\.io/\d+"',
     'dsn:""', None, "the UI's own Sentry crash-report DSN: an empty DSN makes the SDK a no-op"),
]


# ---------------------------------------------------------------------------------------------------------------------
def read_asar(path):
    raw = open(path, "rb").read()
    a, b, c, jl = struct.unpack("<4I", raw[:16])
    assert a == 4, "not an asar"
    header = json.loads(raw[16:16 + jl])
    base = 16 + ((jl + 3) & ~3)  # data section starts after the header padded to 4 bytes
    files, order, meta = {}, [], {}

    def walk(node, prefix):
        for name, ent in node["files"].items():
            p = prefix + "/" + name
            if "files" in ent:
                walk(ent, p)
            else:
                meta[p] = ent
                if not ent.get("unpacked"):
                    off = int(ent["offset"])
                    files[p] = raw[base + off: base + off + ent["size"]]
                    order.append(p)
    walk(header, "")
    order.sort(key=lambda p: int(meta[p]["offset"]))  # keep the original on-disk packing order
    return header, files, order, meta


def write_asar(header, files, order, out):
    off, entries = 0, {}

    def walk(node, prefix):
        for name, ent in node["files"].items():
            p = prefix + "/" + name
            if "files" in ent:
                walk(ent, p)
            else:
                entries[p] = ent
    walk(header, "")
    for p in order:
        entries[p]["size"] = len(files[p])
        entries[p]["offset"] = str(off)
        off += len(files[p])
    js = json.dumps(header, separators=(",", ":")).encode("utf-8")
    pad = (-len(js)) % 4
    padded = len(js) + pad
    hdr = struct.pack("<4I", 4, padded + 8, padded + 4, len(js)) + js + b"\0" * pad
    with open(out, "wb") as f:
        f.write(hdr)
        for p in order:
            f.write(files[p])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--roundtrip", action="store_true")
    ap.add_argument("--extract", metavar="DIR")
    args = ap.parse_args()

    header, files, order, meta = read_asar(args.src)
    if args.extract:
        import os
        for p, data in files.items():
            dest = os.path.join(args.extract, *p.strip("/").split("/"))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as fh:
                fh.write(data)
        print(f"extracted {len(files)} files to {args.extract}")
        return
    js_paths = [p for p in order if p.startswith("/render/") and p.endswith(".js")]
    text = {p: files[p].decode("utf-8") for p in js_paths}
    print(f"asar: {len(order)} packed files, {len(js_paths)} render bundles; sha256 "
          f"{hashlib.sha256(open(args.src, 'rb').read()).hexdigest()[:16]}")

    if args.roundtrip:
        write_asar(header, files, order, args.out)
        print("roundtrip written", args.out)
        return

    ok = True
    for pid, rx, repl, expect, why in PATCHES:
        # minified identifiers may contain '$' (e.g. `$H`), which \w does not match
        cre = re.compile(rx.replace(r'\w+', r'[\w$]+'))
        per = {}
        for p in js_paths:
            t = text[p]
            if not cre.search(t):
                continue
            try:
                # str -> template; fn(match)->str -> plain; fn(text)->fn(match) -> factory (edits that must check the file first)
                sub = repl
                if callable(repl) and repl.__code__.co_varnames[:1] == ("text",):
                    sub = repl(t)
                new, n = cre.subn(sub, t)
            except PatchError as e:
                print(f"  [ ABORT] {pid}: {e}")
                ok = False
                continue
            text[p], per[p] = new, n
        total = sum(per.values())
        good = (total >= 1) if expect is None else (total == expect)
        status = "ok" if good else (f"MISMATCH(expected {expect})" if expect is not None else "MISSING")
        print(f"  [{status:>6}] {pid:<30} x{total}  {', '.join(p.split('/')[-1] + ':' + str(n) for p, n in per.items())}  - {why}")
        if not good and expect is not None:
            ok = False
    if not ok:
        print("ABORT: at least one edit did not match as expected; nothing written.")
        sys.exit(2)
    if args.dry_run:
        print("dry-run complete; nothing written")
        return
    for p in js_paths:
        files[p] = text[p].encode("utf-8")
    write_asar(header, files, order, args.out)
    print("patched asar written:", args.out)


if __name__ == "__main__":
    main()
