# GG-Debloat payload. PowerShell 5.1 + embedded C#. It lives after the "#<PAYLOAD>" marker of GG-Debloat-123.bat.
# Generated from src/payload.template.ps1 by build.py - edit the template, not the .bat.
param([string]$Here)
$ErrorActionPreference = 'Stop'

# ---- the ONE release this patch supports -------------------------------------------------------------------------
$SupportedVersion  = '123.0.0'
$SetupName         = 'SteelSeriesGG123.0.0Setup.exe'
$SetupSha256       = '@@SETUP_SHA256@@'        # the official installer
$OrigAsarSha256    = '@@ORIG_ASAR_SHA256@@'    # resources\app.asar exactly as that installer writes it
$PatchedAsarSha256 = '@@PATCHED_ASAR_SHA256@@' # what the patch must produce (checked before anything is installed)
$GG   = 'C:\Program Files\SteelSeries\GG'
$Work = Join-Path $env:ProgramData 'GG-Debloat'
$Procs = @('SteelSeriesGGEZ','SteelSeriesGG','SteelSeriesGGClient','SteelSeriesEngine','SteelSeriesPrism','SteelSeriesSonar',
           'SteelSeriesMoments','SteelSeriesCaptureSvc','SteelSeriesCVGameSense')
$FwGroup = 'SSGG-Debloat'

$flag = @{}
foreach ($a in $args) { $flag[($a -replace '^[-/]+', '').ToLower()] = $true }
$Undo      = $flag.ContainsKey('undo')
$SelfTest  = $flag.ContainsKey('selftest')
$AllowMom  = $flag.ContainsKey('allow-moments-network')
$NoPause   = $flag.ContainsKey('nopause') -or $env:GGD_NOPAUSE

function Say($m)  { Write-Host $m }
function Done($c) { if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }; exit $c }
function Fail($m) { Write-Host ''; Write-Host "STOPPED: $m" -ForegroundColor Red; Done 1 }
function Sha($p)  { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToUpper() }
trap { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; Done 1 }

if (-not $Here) { $Here = (Get-Location).Path }
$Here = $Here.TrimEnd('\'); if ($Here -match '^[A-Za-z]:$') { $Here += '\' }

Say ''
Say "SteelSeries GG $SupportedVersion - Sonar + Moments only (no telemetry, no account, no ads)"
Say 'Unofficial; not affiliated with SteelSeries. Supports ONLY GG 123.0.0.'
Say ''

# ---- elevate (Program Files, the firewall and services need admin) ----------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $SelfTest) {
  Say 'Administrator rights are needed; a Windows prompt will ask for them...'
  $fl = ($args | Where-Object { $_ -notmatch '^[-/]elevated$' } | ForEach-Object { $_ }) -join ' '
  $argl = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Here `"$Here`" $fl -elevated"
  $p = Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList $argl -Wait -PassThru
  exit $p.ExitCode
}

# keep a log of this run (also useful when asking for help): C:\ProgramData\GG-Debloat\last-run.log
try { New-Item -ItemType Directory -Force $Work | Out-Null; Start-Transcript -Path (Join-Path $Work 'last-run.log') -Force | Out-Null } catch { }

$cs = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace GgDebloat {
  public sealed class P {
    public string Id, Rx, Why; public int Expect;   // Expect -1 = at least one match
    public P(string id, string rx, int expect, string why) { Id = id; Rx = rx; Expect = expect; Why = why; }
  }

  public static class Patcher {
    public static readonly List<P> Table = new List<P> {
//@@PATCH_TABLE@@
    };
    public static List<string> Log = new List<string>();

    sealed class Entry { public Dictionary<string, object> D; public string Path; public bool Unpacked; public long Size; public long Offset; public int Idx; }

    static void Walk(Dictionary<string, object> node, string prefix, List<Entry> list) {
      var files = (Dictionary<string, object>)node["files"];
      foreach (var kv in files) {
        string p = prefix + "/" + kv.Key;
        var ent = (Dictionary<string, object>)kv.Value;
        if (ent.ContainsKey("files")) { Walk(ent, p, list); continue; }
        var e = new Entry { D = ent, Path = p };
        e.Unpacked = ent.ContainsKey("unpacked") && (bool)ent["unpacked"];
        e.Size = Convert.ToInt64(ent["size"]);
        e.Offset = ent.ContainsKey("offset") ? long.Parse((string)ent["offset"]) : 0;
        list.Add(e);
      }
    }

    static void Json(StringBuilder sb, object o) {
      var d = o as Dictionary<string, object>;
      if (d != null) {
        sb.Append('{'); bool first = true;
        foreach (var kv in d) { if (!first) sb.Append(','); first = false; Str(sb, kv.Key); sb.Append(':'); Json(sb, kv.Value); }
        sb.Append('}'); return;
      }
      if (o is string) { Str(sb, (string)o); return; }
      if (o is bool) { sb.Append((bool)o ? "true" : "false"); return; }
      if (o == null) { sb.Append("null"); return; }
      sb.Append(Convert.ToString(o, System.Globalization.CultureInfo.InvariantCulture));
    }
    static void Str(StringBuilder sb, string s) {     // same escaping as Python json.dumps(ensure_ascii=True)
      sb.Append('"');
      foreach (char c in s) {
        if (c == '"') sb.Append("\\\""); else if (c == '\\') sb.Append("\\\\");
        else if (c == '\n') sb.Append("\\n"); else if (c == '\r') sb.Append("\\r"); else if (c == '\t') sb.Append("\\t");
        else if (c == '\b') sb.Append("\\b"); else if (c == '\f') sb.Append("\\f");
        else if (c < 0x20 || c > 0x7e) sb.Append("\\u").Append(((int)c).ToString("x4"));
        else sb.Append(c);
      }
      sb.Append('"');
    }

    static string G(Match m, string n) { return m.Groups[n].Value; }

    // one evaluator per edit; some need the whole file text to check what they are about to change
    static Func<Match, string> Make(string id, string text) {
      switch (id) {
        case "init-no-engine-wait": case "init-no-startup-allowed-wait": case "init-settings-nonblocking": case "init-no-pinnable-tabs-wait":
          return m => "";
        case "init-no-login-screen": return m => G(m, "c") + "=!1;";
        case "route-restore-no-device-wait":
          return m => "if(yield " + G(m, "e2") + "(" + G(m, "sel") + "))return void(0," + G(m, "r") + ".getRouter)().navigate(" + G(m, "R") + ".SONAR);";
        case "logout-saga-keeps-sonar-on":
          return m => { string e = G(m, "e"); return "try{const " + e + "=yield " + G(m, "call") + "(" + G(m, "c") + ");" + e + "&&(yield " + G(m, "put") + "((0," + G(m, "s") + ".setUser)(" + e + ")))}catch(" + e + "){}"; };
        case "dbg-root-saga-error": {
          var lg = Regex.Match(text, "([\\w$]+)\\.logMessage,\"Skipping initialization for non-main window\"");
          if (!lg.Success) throw new Exception("cannot find the UI logger identifier");
          string L = lg.Groups[1].Value;
          return m => { string e = G(m, "e"); return "catch(" + e + "){(0," + L + ".logMessage)(\"[ssgg-debloat] root saga error: \"+(" + e + "&&" + e + ".stack||" + e + ")),"
              + e + " instanceof Error&&console.error(`An error occurred in the root saga: ${" + e + ".message}`)}"; };
        }
        case "guard-always-pass": return m => G(m, "n") + "=!0," + G(m, "n") + "?" + G(m, "e") + ".children";
        case "sonar-no-signin-splash": case "moments-no-signin-splash": return m => "isLoginSkipped:!1,";
        case "moments-nav-no-lock": return m => "!1";
        case "router-fallback-sonar": case "state-default-app-sonar": case "state-default-home-sonar":
          return m => m.Groups[1].Value + "SONAR" + m.Groups[2].Value;
        case "router-home-sonar": return m => "function(" + G(m, "e") + "," + G(m, "t") + "){return " + G(m, "R") + ".SONAR}";
        case "route-news-off": return m => "path:\"__off_news/*\"";
        case "route-giveaways-off": return m => "path:\"__off_giveaways/*\"";
        case "route-quickset-off": return m => "path:\"__off_quickset/*\"";
        case "nav-sonar-moments-only":
          return m => {
            var fn = Regex.Match(text, "function " + Regex.Escape(G(m, "set")) + "\\([^)]*\\)\\{.{0,900}", RegexOptions.Singleline);
            if (!fn.Success || fn.Value.IndexOf("common.settings", StringComparison.Ordinal) < 0)
              throw new Exception("footer button " + G(m, "set") + " is not the Settings button; the footer layout changed");
            string ce = G(m, "ce");
            return ce + "(" + G(m, "ul") + ",null," + G(m, "s") + ".filter(x=>x&&(x.key===\"SONAR\"||x.key===\"MOMENTS\"))),"
                 + ce + "(" + G(m, "ft") + ",null," + ce + "(" + G(m, "set") + ",null))";
          };
        case "sonar-no-contentful-toast": return m => "!1&&";
        case "moments-no-promo-flyout": return m => "activePromos:[],flyoutContent:void 0,";
        case "renderer-sentry-off": return m => "dsn:\"\"";
      }
      throw new Exception("no evaluator for edit " + id);
    }

    // Reads srcAsar, applies every edit, writes dstAsar. Returns true only if EVERY edit matched its expected count.
    public static bool Run(string srcAsar, string dstAsar) {
      Log.Clear();
      byte[] raw = File.ReadAllBytes(srcAsar);
      if (BitConverter.ToUInt32(raw, 0) != 4) throw new Exception("not an asar file");
      int jl = (int)BitConverter.ToUInt32(raw, 12);
      string hdrText = Encoding.UTF8.GetString(raw, 16, jl);
      var ser = new JavaScriptSerializer(); ser.MaxJsonLength = int.MaxValue; ser.RecursionLimit = 10000;
      var header = (Dictionary<string, object>)ser.DeserializeObject(hdrText);
      long baseOff = 16 + ((jl + 3) & ~3);
      var all = new List<Entry>(); Walk(header, "", all);
      var packed = all.FindAll(e => !e.Unpacked);
      // keep the original on-disk order; List.Sort is not stable and zero-byte files share an offset, so tie-break on position
      for (int i = 0; i < packed.Count; i++) packed[i].Idx = i;
      packed.Sort((a, b) => { int c = a.Offset.CompareTo(b.Offset); return c != 0 ? c : a.Idx.CompareTo(b.Idx); });
      var data = new Dictionary<string, byte[]>();
      foreach (var e in packed) { var b = new byte[e.Size]; Buffer.BlockCopy(raw, (int)(baseOff + e.Offset), b, 0, (int)e.Size); data[e.Path] = b; }

      var utf8 = new UTF8Encoding(false, true);
      var js = new List<string>(); var text = new Dictionary<string, string>();
      foreach (var e in packed) if (e.Path.StartsWith("/render/", StringComparison.Ordinal) && e.Path.EndsWith(".js", StringComparison.Ordinal)) {
        js.Add(e.Path); text[e.Path] = utf8.GetString(data[e.Path]);
      }
      Log.Add(string.Format("asar: {0} packed files, {1} render bundles", packed.Count, js.Count));

      bool ok = true;
      foreach (var p in Table) {
        var rx = new Regex(p.Rx.Replace("\\w+", "[\\w$]+"), RegexOptions.CultureInvariant);   // minified names may contain '$'
        int total = 0; var per = new List<string>();
        foreach (var path in js) {
          string t = text[path];
          if (!rx.IsMatch(t)) continue;
          var f = Make(p.Id, t); int n = 0;
          text[path] = rx.Replace(t, m => { n++; return f(m); });
          total += n; per.Add(path.Substring(path.LastIndexOf('/') + 1) + ":" + n);
        }
        bool good = p.Expect < 0 ? total >= 1 : total == p.Expect;
        Log.Add(string.Format("  [{0}] {1} x{2} {3}", good ? "ok" : "MISMATCH(expected " + p.Expect + ")", p.Id, total, string.Join(", ", per.ToArray())));
        if (!good) ok = false;
      }
      if (!ok) return false;
      foreach (var path in js) data[path] = utf8.GetBytes(text[path]);

      long off = 0;
      foreach (var e in packed) { e.D["size"] = data[e.Path].Length; e.D["offset"] = off.ToString(); off += data[e.Path].Length; }
      var sb = new StringBuilder(); Json(sb, header);
      byte[] js2 = Encoding.UTF8.GetBytes(sb.ToString());
      int pad = (4 - (js2.Length % 4)) % 4, padded = js2.Length + pad;
      using (var fs = new FileStream(dstAsar, FileMode.Create, FileAccess.Write)) {
        var w = new BinaryWriter(fs);
        w.Write((uint)4); w.Write((uint)(padded + 8)); w.Write((uint)(padded + 4)); w.Write((uint)js2.Length);
        w.Write(js2); w.Write(new byte[pad]);
        foreach (var e in packed) w.Write(data[e.Path]);
        w.Flush();
      }
      return true;
    }
  }

  // minimal SQLite access through the copy of SQLite that ships with Windows 10/11 (no extra files needed)
  public static class Db {
    const string L = "winsqlite3.dll";
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_open_v2(byte[] f, out IntPtr db, int flags, IntPtr vfs);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_close(IntPtr db);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_exec(IntPtr db, byte[] sql, IntPtr cb, IntPtr arg, out IntPtr err);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int n, out IntPtr stmt, IntPtr tail);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_step(IntPtr stmt);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr sqlite3_column_text(IntPtr stmt, int i);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr sqlite3_errmsg(IntPtr db);
    static byte[] Z(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }
    static string U(IntPtr p) {
      if (p == IntPtr.Zero) return null;
      int n = 0; while (Marshal.ReadByte(p, n) != 0) n++;
      var b = new byte[n]; Marshal.Copy(p, b, 0, n); return Encoding.UTF8.GetString(b);
    }
    static IntPtr Open(string path) {
      IntPtr db; int rc = sqlite3_open_v2(Z(path), out db, 2 /*READWRITE*/, IntPtr.Zero);
      if (rc != 0) throw new Exception("cannot open " + path + " (sqlite " + rc + ")");
      return db;
    }
    public static void Exec(string path, string sql) {
      IntPtr db = Open(path);
      try { IntPtr err; int rc = sqlite3_exec(db, Z(sql), IntPtr.Zero, IntPtr.Zero, out err);
            if (rc != 0) throw new Exception("sqlite: " + U(sqlite3_errmsg(db)) + " in: " + sql); }
      finally { sqlite3_close(db); }
    }
    public static List<string[]> Query(string path, string sql) {
      var rows = new List<string[]>(); IntPtr db = Open(path);
      try {
        IntPtr st; if (sqlite3_prepare_v2(db, Z(sql), -1, out st, IntPtr.Zero) != 0) throw new Exception("sqlite: " + U(sqlite3_errmsg(db)));
        try { while (sqlite3_step(st) == 100) { int n = sqlite3_column_count(st); var r = new string[n]; for (int i = 0; i < n; i++) r[i] = U(sqlite3_column_text(st, i)); rows.Add(r); } }
        finally { sqlite3_finalize(st); }
      } finally { sqlite3_close(db); }
      return rows;
    }
  }
}
'@
Add-Type -TypeDefinition $cs -ReferencedAssemblies 'System.Web.Extensions' -Language CSharp

# ---- helpers ------------------------------------------------------------------------------------------------------
function Stop-GG {
  foreach ($n in $Procs) { Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } }
  for ($i = 0; $i -lt 40; $i++) { if (@(Get-Process -Name $Procs -ErrorAction SilentlyContinue).Count -eq 0) { break }; Start-Sleep -Milliseconds 500 }
}
function Get-InstalledGGVersion { $v = Join-Path $GG 'version.json'; if (Test-Path $v) { ((Get-Content $v -Raw) | ConvertFrom-Json).version } else { $null } }
function Copy-Retry($from, $to) {
  for ($i = 1; $i -le 10; $i++) { try { Copy-Item -LiteralPath $from -Destination $to -Force -ErrorAction Stop; return } catch { Start-Sleep -Seconds 1 } }
  throw "could not write $to (is GG still running?)"
}
$DbDir = 'C:\ProgramData\SteelSeries\GG\db'

# =====================================================================================================================
if ($Undo) {
  Say 'UNDO: restoring the original GG 123.0.0 UI, removing the firewall blocks, re-enabling the updater.'
  Stop-GG
  $orig = Join-Path $Work "backup\app.asar.$SupportedVersion.orig"
  if (Test-Path $orig) {
    if ((Sha $orig) -ne $OrigAsarSha256) { Fail 'the saved original app.asar is damaged; reinstall GG with the official installer instead.' }
    Copy-Retry $orig "$GG\resources\app.asar"; Say '  original app.asar restored'
  } else { Say '  no saved original found (nothing to restore; reinstall GG to be sure)' }
  Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule; Say '  firewall blocks removed'
  $svc = Get-Service -Name 'SteelSeriesGGUpdateServiceProxy' -ErrorAction SilentlyContinue
  if ($svc) { Set-Service -Name $svc.Name -StartupType Manual; Say '  update service -> Manual' }
  $bk = Get-ChildItem (Join-Path $Work 'backup') -Directory -Filter 'db-*' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
  if ($bk) { Get-ChildItem $bk.FullName -File | ForEach-Object { Copy-Item $_.FullName (Join-Path $DbDir $_.Name) -Force }; Say "  databases restored from $($bk.Name) (the state before the first patch)" }
  Say ''; Say 'Done. Start GG from the Start menu.'
  Done 0
}

# ---- 1. the installer ---------------------------------------------------------------------------------------------
$Setup = Join-Path $Here $SetupName
$haveSetup = Test-Path -LiteralPath $Setup
if ($haveSetup) {
  Say "Checking $SetupName ..."
  $h = Sha $Setup
  if ($h -ne $SetupSha256) { Fail "this is not the official GG 123.0.0 installer.`n  expected SHA-256 $SetupSha256`n  got      $h" }
  Say '  installer verified (SHA-256 matches the official 123.0.0 build)'
} else {
  $other = Get-ChildItem -LiteralPath $Here -Filter 'SteelSeriesGG*Setup*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($other) { Fail "found $($other.Name), but this patch supports ONLY $SetupName." }
  Say "  ($SetupName is not next to this file; fine if GG 123.0.0 is already installed)"
}

# ---- 2. make sure GG 123.0.0 is installed ----------------------------------------------------------------------------
$ver = Get-InstalledGGVersion
if ($ver -ne $SupportedVersion) {
  if ($SelfTest) { Say "SELFTEST: GG $SupportedVersion is not installed here (found: $ver); skipping the patch test."; Done 0 }
  if (-not $haveSetup) { Fail "GG $SupportedVersion is not installed (found: $(if ($ver) { $ver } else { 'nothing' })). Put $SetupName next to this file and run it again." }
  Say "Installing GG $SupportedVersion (silent) ..."
  Stop-GG
  $p = Start-Process -FilePath $Setup -ArgumentList '/S' -Wait -PassThru
  $ver = Get-InstalledGGVersion
  if ($ver -ne $SupportedVersion) {
    Say '  the silent install did not finish; opening the normal installer - please click through it.'
    $p = Start-Process -FilePath $Setup -Wait -PassThru
    $ver = Get-InstalledGGVersion
  }
  if ($ver -ne $SupportedVersion) { Fail "GG $SupportedVersion did not install (version now: $ver)." }
  Say "  GG $SupportedVersion installed"
}
Say "GG $SupportedVersion found."

# ---- 3. the UI ------------------------------------------------------------------------------------------------------
$asar = Join-Path $GG 'resources\app.asar'
if ($SelfTest -and $env:GGD_ASAR) { $asar = $env:GGD_ASAR; Say "  (self-test using $asar)" }   # maintainers: test against a saved stock asar
$cur = Sha $asar
$Tmp = Join-Path $env:TEMP ('gg-debloat-' + [guid]::NewGuid().ToString('N'))   # scratch space; created only when patching, always removed
$newAsar = Join-Path $Tmp 'app.asar.patched'
if ($cur -eq $OrigAsarSha256) {
  Say 'Patching the UI (23 edits) ...'
  New-Item -ItemType Directory -Force $Tmp | Out-Null
  $ok = [GgDebloat.Patcher]::Run($asar, $newAsar)
  [GgDebloat.Patcher]::Log | ForEach-Object { Say "  $_" }
  if (-not $ok) { Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue; Fail 'one or more edits did not match; nothing was changed.' }
  $got = Sha $newAsar
  if ($got -ne $PatchedAsarSha256) { Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue; Fail "the patched UI is not the expected build (got $got); nothing was changed." }
  Say '  patched UI matches the expected build'
  if ($SelfTest) { Say 'SELFTEST passed. Nothing was installed.'; Remove-Item $Tmp -Recurse -Force; Done 0 }
  New-Item -ItemType Directory -Force (Join-Path $Work 'backup') | Out-Null
  $bkAsar = Join-Path $Work "backup\app.asar.$SupportedVersion.orig"
  if (-not (Test-Path $bkAsar)) { Copy-Item $asar $bkAsar }
  Stop-GG
  Copy-Retry $newAsar $asar
  if ((Sha $asar) -ne $PatchedAsarSha256) { Fail 'copy verification failed; run again or use -Undo.' }
  Say '  patched UI installed'
} elseif ($cur -eq $PatchedAsarSha256) {
  Say 'The UI is already patched.'
  if ($SelfTest) { Say 'SELFTEST: already patched.'; Done 0 }
  Stop-GG
} else {
  Fail "the installed app.asar is not the stock GG $SupportedVersion one (SHA-256 $cur). It was modified or is a different build. Reinstall with the official installer, then run this again."
}
Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---- 4. databases: Engine, 3D Aim Trainer, Performance Coach off; two privacy settings off ---------------------------
$ggez = Join-Path $DbDir 'ggez.db'; $core = Join-Path $DbDir 'database.db'
if ((Test-Path $ggez) -and (Test-Path $core)) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $bd = Join-Path $Work "backup\db-$stamp"; New-Item -ItemType Directory -Force $bd | Out-Null
  Get-ChildItem $DbDir -File | Where-Object { $_.Name -match '^(ggez|database)\.db' } | ForEach-Object { Copy-Item $_.FullName $bd }
  $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
  [GgDebloat.Db]::Exec($ggez, "update sub_apps set is_enabled=0, updated_at='$now' where name in ('engine','threeDAT','performanceCoach') and is_enabled<>0")
  [GgDebloat.Db]::Exec($core, "update sub_apps set is_enabled=0, updated_at='$now' where name in ('engine','threeDAT') and is_enabled<>0")
  [GgDebloat.Db]::Exec($core, "update settings set value='false', updated_at='$now' where key in ('personalizationEnabled','enableAutomaticGameScanning')")
  [GgDebloat.Db]::Exec($core, 'delete from active_promos')
  $rows = [GgDebloat.Db]::Query($ggez, 'select name, is_enabled from sub_apps order by id')
  Say ('Modules: ' + (($rows | ForEach-Object { "$($_[0])=" + $(if ($_[1] -eq '1') { 'ON' } else { 'off' }) }) -join ', '))
} else {
  Say 'GG has not created its databases yet (it never ran). The UI patch is installed; to also switch the Engine off:'
  Say '  start GG once from the Start menu, close it completely, then run this file again.'
}

# ---- 5. firewall: outbound block for every GG program (this is the telemetry switch) --------------------------------
Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
$n = 0
Get-ChildItem $GG -Recurse -Filter *.exe -File | ForEach-Object {
  $rel = $_.FullName.Substring($GG.Length + 1)
  if ($AllowMom -and $rel -like 'apps\moments\*') { Say "  left open (-allow-moments-network): $rel"; return }
  New-NetFirewallRule -DisplayName "$FwGroup $rel" -Group $FwGroup -Direction Outbound -Program $_.FullName -Action Block -Profile Any | Out-Null
  $n++
}
Say "Firewall: $n outbound blocks (telemetry, ads, updates, accounts)."

# ---- 6. updater -------------------------------------------------------------------------------------------------------
$svc = Get-Service -Name 'SteelSeriesGGUpdateServiceProxy' -ErrorAction SilentlyContinue
if ($svc) { Set-Service -Name $svc.Name -StartupType Disabled; Say 'Update service: disabled (a GG update would undo this patch).' }

Say ''
Say 'Done. Start GG from the Start menu (not from this window). You can use Sonar and Moments without an account.'
Say "To undo everything: run this file again with  -Undo"
Done 0
