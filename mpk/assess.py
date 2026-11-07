#!/usr/bin/env python3
"""Assess which lind-wasm-apps run under lind-wasm's native MPK backend.

For every app recipe in mpk/recipes/ this runs, in order:

  1. build    - native x86-64 build linked against lind's glibc (mpk/bin/lind-mpk-cc)
  2. rewrite  - gsfork-elf rewrite of every produced ELF program (as lind_compile --mpk)
  3. install  - copy rewritten programs into lindfs at their usual paths
  4. smoke    - recipe-defined checks run under lind-boot
  5. upstream - the app's own <app>/run_tests.sh (the wasm test suite), unchanged

and writes results/report.{md,json} plus per-app logs. See mpk/README.md.
"""

import argparse
import concurrent.futures
import datetime
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

MPK_DIR = Path(__file__).resolve().parent
APPS_ROOT = MPK_DIR.parent
RECIPES = MPK_DIR / "recipes"

VERDICT_ORDER = ["compatible", "partial", "runtime-fail", "rewrite-fail", "build-fail", "not-assessed"]
VERDICT_TEXT = {
    "compatible": "Compatible: builds, rewrites, and passes every check",
    "partial": "Partially compatible: runs, but some checks fail",
    "runtime-fail": "Rewritten, but no check passes under lind-mpk",
    "rewrite-fail": "Native build OK, gsfork-elf rewrite fails",
    "build-fail": "Native build against lind glibc fails",
    "not-assessed": "Not assessed (see reason)",
}


def sh(cmd, log, *, env=None, cwd=None, timeout=None):
    """Run cmd, appending combined output to log. Returns (rc, seconds)."""
    start = time.time()
    with open(log, "a") as fh:
        fh.write(f"$ {' '.join(map(str, cmd))}\n")
        fh.flush()
        proc = subprocess.Popen(cmd, stdout=fh, stderr=subprocess.STDOUT, env=env, cwd=cwd,
                                start_new_session=True)
        try:
            rc = proc.wait(timeout=timeout)
        except BaseException as error:
            # Kill the whole session, not just cmd: a rewrite's ddisasm or a
            # build's compilers would otherwise keep running (and holding tens
            # of GB) after the timeout.
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
            if not isinstance(error, subprocess.TimeoutExpired):
                raise
            fh.write(f"\n*** TIMEOUT after {timeout}s\n")
            rc = "timeout"
    return rc, round(time.time() - start, 1)


def tail_reason(log, patterns=(r"\berror\b", r"\*\*\*", r"fatal", r"undefined reference",
                               r"cannot|No such file")):
    """Best-effort one-line failure reason from a log."""
    try:
        lines = Path(log).read_text(errors="replace").splitlines()
    except OSError:
        return ""
    rx = re.compile("|".join(patterns), re.I)
    # Skip compile progress lines like "CC reftable/error.o".
    quiet = re.compile(r"^\s*(?:CC|CXX|LD|AR|GEN|CCLD|CXXLD)\s+\S+$")
    hits = [l.strip() for l in lines if rx.search(l) and not l.startswith("$ ") and not quiet.match(l)
            and not l.startswith("checking ")]
    pick = hits[0] if hits else (lines[-1].strip() if lines else "")
    # gsfork-elf names its scratch output by absolute path; keep the message.
    pick = re.sub(r"/\S*/\.gsfork-[^/\s:]+/output", "<rewrite-out>", pick)
    return pick[:240]


def syscall_names():
    names = {}
    for hdr in ("/usr/include/x86_64-linux-gnu/asm/unistd_64.h", "/usr/include/asm/unistd_64.h"):
        try:
            for m in re.finditer(r"#define __NR_(\w+) (\d+)", Path(hdr).read_text()):
                names[int(m.group(2))] = m.group(1)
            break
        except OSError:
            continue
    return names


SYSCALL_NAMES = syscall_names()


def runtime_issues(text):
    """Group lind-boot panics in a guest log by cause."""
    issues = {}

    def add(key):
        issues[key] = issues.get(key, 0) + 1

    for m in re.finditer(r"no handler for syscall_num: (\d+)", text):
        n = int(m.group(1))
        add(f"missing syscall {n} ({SYSCALL_NAMES.get(n, '?')})")
    for m in re.finditer(r"panicked at [^\n]*:\n([^\n]*)", text):
        msg = m.group(1).strip()
        if "no handler for syscall_num" in msg or "cannot unwind" in msg:
            continue
        add("panic: " + re.sub(r"0x[0-9a-f]+|\b\d{3,}\b", "N", msg)[:120])
    for m in re.finditer(r"^\*\*\* TIMEOUT|timeout after \d+s", text, re.M):
        add("timeout")
    return issues


def glob_escape(name):
    return re.sub(r"([*?\[])", r"[\1]", name)


def test_lines(text, word):
    """Per-test result lines of a run_tests.sh log (formats vary between apps):
    `PASS: x`, `  [tag] PASS: x`, `[ PASS ] x`, `x: PASS`. Summary lines are skipped."""
    pats = [rf"^\s*(?:\[[^\]]*\]\s*)?{word}\b(?!:?\s*\d+\s*(?:\||$))",
            rf"^\s*\[\s*{word}\s*\]", rf"^\S[^:]*:\s+{word}\b"]
    return [l.strip() for l in text.splitlines() if any(re.match(p, l) for p in pats)]


def is_elf_program(path):
    """True for ELF executables (ET_EXEC, or PIE: ET_DYN with PT_INTERP)."""
    import struct
    if path.is_symlink():
        return False
    try:
        with open(path, "rb") as fh:
            head = fh.read(64)
            if len(head) < 64 or head[:4] != b"\x7fELF" or head[4] != 2:
                return False
            e_type, = struct.unpack_from("<H", head, 16)
            if e_type == 2:
                return True
            if e_type != 3:
                return False
            phoff, = struct.unpack_from("<Q", head, 32)
            phentsize, phnum = struct.unpack_from("<HH", head, 54)
            fh.seek(phoff)
            table = fh.read(phentsize * phnum)
    except OSError:
        return False
    return any(struct.unpack_from("<I", table, i * phentsize)[0] == 3 for i in range(phnum))


def needed_libs(path):
    out = subprocess.run(["readelf", "-d", str(path)], capture_output=True, text=True).stdout
    return re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", out)


def recipe_meta(recipe):
    script = (f'source "{recipe}"; printf "%s\\n" "${{KIND:-program}}" "${{DEPS[*]:-}}" '
              f'"${{SKIP_REASON:-}}" "${{NOTE:-}}" "${{UPSTREAM_TESTS:-1}}" "${{RUNTIME_DEPS[*]:-}}"')
    out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True).stdout
    kind, deps, skip, note, upstream, rdeps = (out.split("\n") + [""] * 6)[:6]
    return {"kind": kind, "deps": deps.split(), "skip": skip, "note": note, "upstream": upstream == "1",
            "rdeps": rdeps.split()}


def tool_versions(args):
    def rev(path):
        r = subprocess.run(["git", "-C", str(path), "rev-parse", "--short", "HEAD"], capture_output=True, text=True)
        dirty = subprocess.run(["git", "-C", str(path), "status", "--porcelain", "-uno"], capture_output=True, text=True)
        return (r.stdout.strip() + ("+dirty" if dirty.stdout.strip() else "")) if r.returncode == 0 else "unknown"

    apps_rev = rev(APPS_ROOT)
    marker = APPS_ROOT / ".mpk-source-rev"
    if apps_rev == "unknown" and marker.exists():
        apps_rev = marker.read_text().strip()
    boot = Path(args.lind_wasm_root) / "build" / "lind-boot"
    boot_md5 = hashlib.md5(boot.read_bytes()).hexdigest()[:12] if boot.exists() else "missing"
    gsfork = Path(args.gsfork_elf).resolve()
    return {
        "date": datetime.datetime.now().isoformat(timespec="seconds"),
        "lind-wasm": rev(args.lind_wasm_root),
        "lind-wasm-apps": apps_rev,
        "lind-boot md5": boot_md5,
        "rewriter": rewriter_version(gsfork),
        "gcc": subprocess.run(["gcc", "-dumpfullversion"], capture_output=True, text=True).stdout.strip(),
    }


def rewriter_version(gsfork):
    """git rev of the rewriter checkout (if available) plus a hash of its Python
    sources, so local patches to gsfork_elf show up in the report."""
    root = gsfork.parent.parent.parent  # <rewriter>/.venv/bin/gsfork-elf
    r = subprocess.run(["git", "-C", str(root), "rev-parse", "--short", "HEAD"], capture_output=True, text=True)
    srcs = sorted((root / "gsfork_elf").glob("*.py"))
    h = hashlib.md5(b"".join(p.read_bytes() for p in srcs)).hexdigest()[:12] if srcs else "?"
    return (r.stdout.strip() + " " if r.returncode == 0 else "") + f"gsfork_elf md5 {h}"


class Assessor:
    def __init__(self, args):
        self.args = args
        self.work = Path(args.work).resolve()
        self.out = Path(args.out).resolve()
        self.lind = Path(args.lind_wasm_root).resolve()
        self.lindfs = self.lind / "lindfs"
        self.prefix = self.work / "prefix"
        self.backup = self.work / "lindfs-backup"
        self.installed = []  # lindfs paths written by this run
        self.created_dirs = []  # lindfs directories created by this run
        self.results = {}
        self.deps_done = {}
        for d in (self.work, self.out / "logs", self.prefix, self.backup):
            d.mkdir(parents=True, exist_ok=True)
        self._shadow_roots()

    # Upstream run_tests.sh scripts locate everything relative to their own path
    # and LIND_WASM_ROOT. Run them from shadow roots so they see MPK binaries in
    # build/<app>/ (not the wasm ones) and find scripts/bin/lind_run.
    def _shadow_roots(self):
        self.shadow_apps = self.work / "apps-root"
        self.shadow_lind = self.work / "lind-root"
        self.stage = self.work / "stage"
        for d in (self.shadow_apps, self.shadow_lind / "scripts" / "bin", self.stage):
            d.mkdir(parents=True, exist_ok=True)
        links = {self.shadow_apps / "build": self.stage, self.shadow_apps / "scripts": APPS_ROOT / "scripts",
                 self.shadow_lind / "lindfs": self.lindfs, self.shadow_lind / "build": self.lind / "build",
                 self.shadow_lind / "scripts" / "lind_run": self.lind / "scripts" / "lind_run",
                 self.shadow_lind / "scripts" / "bin" / "lind_run": self.lind / "scripts" / "lind_run"}
        for entry in APPS_ROOT.iterdir():
            if entry.is_dir() and (entry / "run_tests.sh").exists():
                links[self.shadow_apps / entry.name] = entry
        for link, target in links.items():
            if link.is_symlink() or link.exists():
                link.unlink()
            link.symlink_to(target)

    def env(self, app):
        env = dict(os.environ)
        env.update(APP=app, APPS_ROOT=str(APPS_ROOT), LIND_WASM_ROOT=str(self.lind),
                   SRC=str(self.work / "src" / app), NATIVE=str(self.work / "native" / app),
                   PREFIX=str(self.prefix), JOBS=str(self.args.jobs),
                   SMOKE_TIMEOUT=str(self.args.smoke_timeout))
        env["PATH"] = f"{self.shadow_lind / 'scripts'}:{env.get('PATH', '')}"
        return env

    def log(self, app, name):
        d = self.out / "logs" / app
        d.mkdir(parents=True, exist_ok=True)
        return d / f"{name}.log"

    # -- stages ---------------------------------------------------------------
    def build(self, app, recipe, res):
        src, native = self.work / "src" / app, self.work / "native" / app
        stamp = native / ".mpk-build-ok"
        key = hashlib.sha256(recipe.read_bytes() + (MPK_DIR / "bin" / "lind-mpk-cc").read_bytes()
                             + (MPK_DIR / "lib" / "common.sh").read_bytes()).hexdigest()
        log = self.log(app, "build")
        if not self.args.rebuild and stamp.exists() and stamp.read_text() == key:
            res["build"] = {"status": "ok", "cached": True}
            return True
        log.unlink(missing_ok=True)
        shutil.rmtree(native, ignore_errors=True)
        shutil.rmtree(src, ignore_errors=True)
        native.mkdir(parents=True)
        src.mkdir(parents=True)
        rc, _ = sh(["rsync", "-a", "--delete", f"{APPS_ROOT / app}/", f"{src}/"], log)
        if rc != 0:
            res["build"] = {"status": "fail", "reason": "could not copy sources: " + tail_reason(log)}
            return False
        rc, secs = sh(["bash", str(MPK_DIR / "lib" / "stage.sh"), "build", str(recipe)], log,
                      env=self.env(app), timeout=self.args.build_timeout)
        programs = [p for p in native.rglob("*") if p.is_file() and is_elf_program(p)]
        ok = rc == 0 and bool(programs)
        res["build"] = {"status": "ok" if ok else "fail", "seconds": secs, "log": str(log.relative_to(self.out))}
        if not ok:
            res["build"]["reason"] = (f"exit {rc}: " if rc != 0 else "no programs staged: ") + tail_reason(log)
            return False
        stamp.write_text(key)
        if not self.args.keep_src:
            shutil.rmtree(src, ignore_errors=True)
        return True

    def rewrite_one(self, app, native_root, path):
        rel = path.relative_to(native_root)
        out = self.stage / app / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        log = self.log(app, "rewrite-" + str(rel).replace("/", "_"))
        log.unlink(missing_ok=True)
        g = self.lind / "glibc-2.35"
        cmd = [self.args.gsfork_elf, "rewrite", str(path), str(out),
               "--scratch-field=sandbox_scratch", "--sandbox-field=sandbox_offset",
               "-L", str(g / "build" / "elf"), "-L", str(g / "build"),
               "--tcb-layout", str(g / "build" / "libc.so.6"),
               "--trust-library", "ld-linux-x86-64.so.2", "--trust-library", "libm.so.6",
               "--trust-library", "libc.so.6"]
        extra = [n for n in needed_libs(path) if n not in ("libc.so.6", "libm.so.6", "ld-linux-x86-64.so.2")]
        # gsfork-elf caps each ddisasm/pprinter run at 300s by default; large
        # programs (openssl, gcc, clang) need longer. Bounded by --rewrite-timeout.
        env = dict(os.environ, GSFORK_TOOL_TIMEOUT=str(self.args.rewrite_timeout))
        rc, secs = sh(cmd, log, env=env, timeout=self.args.rewrite_timeout, cwd=self.work)
        entry = {"binary": "/" + str(rel), "status": "ok" if rc == 0 and out.exists() else "fail",
                 "seconds": secs, "size": path.stat().st_size}
        if extra:
            entry["needed"] = extra
        # gsfork-elf leaves <out>.gsfork/ (work files) and <out>.failed-*/
        # (diagnostics) beside the output; keep them out of the lindfs stage.
        for side in out.parent.glob(glob_escape(out.name) + ".*"):
            if side.is_dir() and (side.name == out.name + ".gsfork" or ".failed-" in side.name):
                if side.name.endswith(".gsfork") and not self.args.keep_src:
                    shutil.rmtree(side, ignore_errors=True)
                else:
                    keep = self.work / "rewrite-artifacts" / app / rel.parent / side.name
                    shutil.rmtree(keep, ignore_errors=True)
                    keep.parent.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(side), str(keep))
        if entry["status"] == "fail":
            out.unlink(missing_ok=True)
            entry["reason"] = tail_reason(log, (r"^gsfork-elf:", r"rewriteerror", r"TIMEOUT", r"\berror\b"))
            entry["log"] = str(log.relative_to(self.out))
        else:
            out.chmod(0o755)
        return entry

    def rewrite(self, app, res):
        native_root = self.work / "native" / app
        stage = self.stage / app
        shutil.rmtree(stage, ignore_errors=True)
        stage.mkdir(parents=True)
        programs, by_hash = [], {}
        for p in sorted(native_root.rglob("*")):
            if p.name == ".mpk-build-ok" or p.is_dir() and not p.is_symlink():
                continue
            dest = stage / p.relative_to(native_root)
            dest.parent.mkdir(parents=True, exist_ok=True)
            if is_elf_program(p):
                digest = hashlib.sha256(p.read_bytes()).hexdigest()
                if digest in by_hash:
                    # Identical program (e.g. git builtins): link to the first copy.
                    dest.symlink_to("/" + str(by_hash[digest].relative_to(native_root)))
                else:
                    by_hash[digest] = p
                    programs.append(p)
            elif p.is_symlink():
                dest.symlink_to(os.readlink(p))
            else:
                shutil.copy2(p, dest)
        with concurrent.futures.ThreadPoolExecutor(self.args.rewrite_workers) as pool:
            entries = list(pool.map(lambda p: self.rewrite_one(app, native_root, p), programs))
        ok = sum(e["status"] == "ok" for e in entries)
        res["rewrite"] = {"ok": ok, "total": len(entries),
                          "failed": [e for e in entries if e["status"] != "ok"],
                          "seconds": round(sum(e["seconds"] for e in entries), 1)}
        return ok > 0

    def install(self, app):
        root = self.stage / app
        for path in sorted(root.rglob("*")):
            if path.is_dir() and not path.is_symlink():
                continue
            rel = path.relative_to(root)
            dest = self.lindfs / rel
            saved = self.backup / rel
            if dest not in self.installed:
                if (dest.exists() or dest.is_symlink()) and not (saved.exists() or saved.is_symlink()):
                    saved.parent.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(dest), str(saved))
                self.installed.append(dest)
            missing = [d for d in [dest.parent, *dest.parent.parents] if not d.exists()]
            self.created_dirs.extend(reversed(missing))
            dest.parent.mkdir(parents=True, exist_ok=True)
            if dest.is_dir() and not dest.is_symlink():
                shutil.rmtree(dest)
            elif dest.exists() or dest.is_symlink():
                dest.unlink()
            if path.is_symlink():
                dest.symlink_to(os.readlink(path))
            else:
                shutil.copy2(path, dest)

    def restore_lindfs(self):
        for dest in reversed(self.installed):
            if dest.exists() or dest.is_symlink():
                dest.unlink()
            saved = self.backup / dest.relative_to(self.lindfs)
            if saved.exists() or saved.is_symlink():
                shutil.move(str(saved), str(dest))
        # Smoke fixtures live in lindfs/tmp/mpk-*; guests ran as root via sudo.
        fixtures = [str(p) for p in (self.lindfs / "tmp").glob("mpk-*")]
        if fixtures:
            subprocess.run(["sudo", "-n", "rm", "-rf", "--", *fixtures], check=False)
        for d in reversed(self.created_dirs):
            try:
                d.rmdir()
            except OSError:
                pass

    def smoke(self, app, recipe, res):
        log = self.log(app, "smoke")
        log.unlink(missing_ok=True)
        rc, secs = sh(["bash", str(MPK_DIR / "lib" / "stage.sh"), "smoke", str(recipe)], log,
                      env=self.env(app), timeout=self.args.upstream_timeout)
        text = log.read_text(errors="replace")
        passed = re.findall(r"^SMOKE PASS: (.*)$", text, re.M)
        failed = re.findall(r"^SMOKE FAIL: (.*)$", text, re.M)
        skipped = re.findall(r"^SMOKE SKIP: (.*)$", text, re.M)
        self.note_issues(res, text)
        res["smoke"] = {"pass": len(passed), "fail": len(failed), "skip": len(skipped), "failures": failed,
                        "seconds": secs, "log": str(log.relative_to(self.out))}
        if rc not in (0,) and not failed:
            res["smoke"]["fail"] += 1
            res["smoke"]["failures"].append(f"smoke script exit {rc}: {tail_reason(log)}")

    def upstream(self, app, res):
        script = self.shadow_apps / app / "run_tests.sh"
        if not (APPS_ROOT / app / "run_tests.sh").exists():
            return
        log = self.log(app, "upstream")
        log.unlink(missing_ok=True)
        env = self.env(app)
        env["LIND_WASM_ROOT"] = str(self.shadow_lind)
        env["LINDFS_ROOT"] = str(self.lindfs)
        scratch = self.lindfs / "tests" / app
        had_scratch = scratch.exists()
        rc, secs = sh(["bash", str(script)], log, env=env, cwd=self.shadow_apps / app,
                      timeout=self.args.upstream_timeout)
        if scratch.exists() and not had_scratch:
            # run_tests.sh's own cleanup trap cannot remove root-owned guest output.
            subprocess.run(["sudo", "-n", "rm", "-rf", "--", str(scratch)], check=False)
        text = re.sub(r"\x1b\[[0-9;]*m", "", log.read_text(errors="replace"))
        self.note_issues(res, text)
        n_pass, n_fail, n_skip = (len(test_lines(text, w)) for w in ("PASS", "FAIL", "SKIP"))
        res["upstream"] = {"exit": rc, "pass": n_pass, "fail": n_fail, "skip": n_skip,
                           "seconds": secs, "log": str(log.relative_to(self.out))}
        if rc != 0:
            fails = test_lines(text, "FAIL")
            res["upstream"]["first_failure"] = (fails[0] if fails else tail_reason(log))[:240]

    @staticmethod
    def note_issues(res, text):
        issues = res.setdefault("runtime_issues", {})
        for key, n in runtime_issues(text).items():
            issues[key] = issues.get(key, 0) + n

    # -- orchestration --------------------------------------------------------
    def ensure_deps(self, app, meta, res):
        for dep in meta["deps"]:
            if dep not in self.deps_done:
                self.assess(dep)
                self.deps_done[dep] = self.results[dep]["build"].get("status") == "ok"
            if not self.deps_done[dep]:
                res["build"] = {"status": "fail", "reason": f"dependency {dep} failed to build"}
                return False
        return True

    def assess(self, app):
        if app in self.results:
            return self.results[app]
        recipe = RECIPES / f"{app}.sh"
        meta = recipe_meta(recipe)
        res = {"app": app, "kind": meta["kind"], "note": meta["note"]}
        self.results[app] = res
        print(f"[mpk-assess] {app}: start", flush=True)
        if meta["skip"]:
            res["skip"] = meta["skip"]
        elif self.ensure_deps(app, meta, res) and self.build(app, recipe, res) and self.rewrite(app, res):
            self.install(app)
            for dep in meta["rdeps"]:
                self.assess(dep)
            self.smoke(app, recipe, res)
            if meta["upstream"] and not self.args.no_upstream:
                self.upstream(app, res)
        res["verdict"], res["reason"] = verdict(res)
        print(f"[mpk-assess] {app}: {res['verdict']} {res['reason']}", flush=True)
        return res

    def run(self, apps):
        try:
            for app in apps:
                self.assess(app)
        finally:
            if not self.args.keep_installed:
                self.restore_lindfs()
        return self.results


def verdict(res):
    if res.get("skip"):
        return "not-assessed", res["skip"]
    b = res.get("build", {})
    if b.get("status") != "ok":
        return "build-fail", b.get("reason", "")
    rw = res.get("rewrite", {})
    if not rw.get("ok"):
        first = (rw.get("failed") or [{}])[0]
        return "rewrite-fail", f"{first.get('binary', '')}: {first.get('reason', '')}"
    sm, up = res.get("smoke", {}), res.get("upstream")
    reasons = []
    if rw["ok"] < rw["total"]:
        first = rw["failed"][0]
        reasons.append(f"{rw['total'] - rw['ok']}/{rw['total']} binaries failed to rewrite "
                       f"(first: {first.get('binary', '')}: {first.get('reason', '')[:120]})")
    if sm.get("fail"):
        reasons.append("smoke: " + sm["failures"][0])
    if up and up["exit"] != 0:
        reasons.append(f"run_tests.sh: {up['pass']} pass/{up['fail']} fail; {up.get('first_failure', '')}")
    if not reasons:
        return "compatible", ""
    any_pass = sm.get("pass", 0) > 0 or (up is not None and up["pass"] > 0)
    return ("partial" if any_pass else "runtime-fail"), "; ".join(reasons)


REWRITE_CAUSES = [
    ("GOT reference does not resolve", "GOT reference does not resolve to a symbol"),
    ("TIMEOUT", "rewrite exceeded --rewrite-timeout"),
    ("reported recovery/link diagnostics", "ddisasm symbol-recovery diagnostics"),
    ("relinking lost a dynamic symbol", "relinking lost a dynamic symbol/type"),
    ("required provena", "required provenance/reference symbol missing"),
    ("--trust-library", "depends on a shared library other than libc/libm/ld.so"),
    ("LSDA", "C++ LSDA exception-specification filters unsupported"),
]


def rewrite_cause(reason):
    """Collapse a gsfork-elf failure reason into a cause shared across binaries."""
    for needle, cause in REWRITE_CAUSES:
        if needle in reason:
            return cause
    m = re.search(r"unsupported instruction (\w+)", reason)
    if m:
        return f"unsupported instruction {m.group(1)}"
    return re.sub(r"0x[0-9a-f]+|(?<!\S)/\S+", "…", reason).strip()[:140]


def write_report(results, versions, out, args):
    summary = {v: sorted(a for a, r in results.items() if r["verdict"] == v) for v in VERDICT_ORDER}
    (out / "report.json").write_text(json.dumps(
        {"versions": versions, "summary": summary, "apps": results}, indent=2, default=str) + "\n")

    lines = ["# lind-mpk compatibility of lind-wasm-apps", "",
             "Generated by `mpk/assess.py` (see `mpk/README.md`). Do not edit by hand.", "",
             "| Component | Version |", "|---|---|"]
    lines += [f"| {k} | `{v}` |" for k, v in versions.items()]
    assessed = [a for a in results if results[a]["verdict"] != "not-assessed"]
    lines += ["", f"**{len(summary['compatible'])} of {len(results)} apps fully compatible** "
              f"({len(summary['compatible']) + len(summary['partial'])} run at least partially; "
              f"{len(assessed)} assessed).", "", "| Verdict | Count | Apps |", "|---|---|---|"]
    lines += [f"| {VERDICT_TEXT[v]} | {len(summary[v])} | {', '.join(summary[v])} |" for v in VERDICT_ORDER]
    lines += ["", "## Per app", "",
              "| App | Kind | Build | Rewrite | Smoke | run_tests.sh | Verdict | Runtime issues | First problem |",
              "|---|---|---|---|---|---|---|---|---|"]
    for app in sorted(results):
        r = results[app]
        b = r.get("build", {})
        build = "-" if r.get("skip") else b.get("status", "-") + (f" ({b['seconds']:.0f}s)" if "seconds" in b else "")
        rw = r.get("rewrite")
        rw_s = f"{rw['ok']}/{rw['total']}" if rw else "-"
        sm = r.get("smoke")
        sm_s = f"{sm['pass']}/{sm['pass'] + sm['fail']}" if sm else "-"
        if sm and sm.get("skip"):
            sm_s += f" ({sm['skip']} skipped)"
        up = r.get("upstream")
        up_s = (f"{up['pass']} pass, {up['fail']} fail" + ("" if up["exit"] == 0 else f" (exit {up['exit']})")) if up else "-"
        reason = r["reason"].replace("|", "\\|").replace("\n", " ")[:300]
        issues = "; ".join(f"{k} ×{n}" for k, n in sorted(r.get("runtime_issues", {}).items())).replace("|", "\\|")
        lines.append(f"| {app} | {r['kind']} | {build} | {rw_s} | {sm_s} | {up_s} | {r['verdict']} | {issues or '-'} | {reason} |")
    blockers = {}
    for app, r in results.items():
        for key in r.get("runtime_issues", {}):
            blockers.setdefault(key, []).append(app)
        for f in r.get("rewrite", {}).get("failed", []):
            key = "rewrite: " + rewrite_cause(f.get("reason", ""))
            blockers.setdefault(key, []).append(app)
    if blockers:
        lines += ["", "## Blockers by cause", "", "| Cause | Apps |", "|---|---|"]
        for key, apps_ in sorted(blockers.items(), key=lambda kv: (-len(set(kv[1])), kv[0])):
            cause = key.replace("|", "\\|")
            lines.append(f"| {cause} | {', '.join(sorted(set(apps_)))} |")
    notes = [(a, r["note"]) for a, r in sorted(results.items()) if r.get("note")]
    if notes:
        lines += ["", "## Notes", ""] + [f"- **{a}**: {n}" for a, n in notes]
    lines += ["", "Logs: `results/logs/<app>/` (build, rewrite-<binary>, smoke, upstream).", ""]
    (out / "report.md").write_text("\n".join(lines))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("apps", nargs="*", help="apps to assess (default: every recipe)")
    p.add_argument("--lind-wasm-root", default=os.environ.get("LIND_WASM_ROOT", str(Path.home() / "lind-wasm")))
    p.add_argument("--gsfork-elf", default=os.environ.get("GSFORK_ELF_BIN") or shutil.which("gsfork-elf")
                   or str(Path.home() / "rewriter" / ".venv" / "bin" / "gsfork-elf"))
    p.add_argument("--work", default=str(APPS_ROOT / "build" / "mpk"), help="scratch dir (default build/mpk)")
    p.add_argument("--out", default=str(MPK_DIR / "results"), help="report dir (default mpk/results)")
    p.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    p.add_argument("--rewrite-workers", type=int, default=8)
    p.add_argument("--build-timeout", type=int, default=3600)
    p.add_argument("--rewrite-timeout", type=int, default=3600)
    p.add_argument("--smoke-timeout", type=int, default=60, help="per smoke command")
    p.add_argument("--upstream-timeout", type=int, default=1800)
    p.add_argument("--rebuild", action="store_true", help="ignore cached native builds")
    p.add_argument("--keep-src", action="store_true", help="keep build trees in WORK/src")
    p.add_argument("--keep-installed", action="store_true", help="leave MPK binaries in lindfs")
    p.add_argument("--no-upstream", action="store_true", help="skip <app>/run_tests.sh")
    args = p.parse_args()

    if not Path(args.gsfork_elf).exists():
        sys.exit(f"gsfork-elf not found ({args.gsfork_elf}); set GSFORK_ELF_BIN")
    if not (Path(args.lind_wasm_root) / "build" / "lind-boot").exists():
        sys.exit(f"lind-boot not built under {args.lind_wasm_root}; run `make lind-boot`")
    apps = args.apps or sorted(r.stem for r in RECIPES.glob("*.sh"))
    unknown = [a for a in apps if not (RECIPES / f"{a}.sh").exists()]
    if unknown:
        sys.exit(f"no recipe for: {' '.join(unknown)}")

    out = Path(args.out).resolve()
    if not args.apps and (out / "logs").exists():
        shutil.rmtree(out / "logs")
    assessor = Assessor(args)
    versions = tool_versions(args)
    results = assessor.run(apps)
    if args.apps and (out / "report.json").exists():
        # Partial run: merge into the existing report so it stays complete.
        previous = json.loads((out / "report.json").read_text())["apps"]
        previous.update(results)
        results = previous
    write_report(results, versions, out, args)
    print(f"[mpk-assess] report: {out / 'report.md'}")


if __name__ == "__main__":
    main()
