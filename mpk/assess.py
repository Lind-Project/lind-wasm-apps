#!/usr/bin/env python3
"""Assess which lind-wasm-apps run under lind, natively (MPK) and/or as WebAssembly.

--mode mpk (default): for every app recipe in mpk/recipes/ this runs, in order:

  1. build    - native x86-64 build linked against lind's glibc (mpk/bin/lind-mpk-cc)
  2. rewrite  - gsfork-elf rewrite of every produced ELF program (as lind_compile --mpk)
  3. install  - copy rewritten programs into lindfs at their usual paths
  4. smoke    - recipe-defined checks run under lind-boot
  5. upstream - the app's own <app>/run_tests.sh (the wasm test suite), unchanged

and writes results/report.{md,json} plus per-app logs.

--mode wasm: `make <app>` + `make install-<app>` (the regular wasm build, left
installed in lindfs), then the same smoke checks and run_tests.sh against the
wasm programs; writes results/wasm/report.{md,json}.

--mode both: wasm, then mpk (which restores the wasm installs afterwards), then
results/comparison.md. See mpk/README.md.
"""

import argparse
import concurrent.futures
import datetime
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

MPK_DIR = Path(__file__).resolve().parent
APPS_ROOT = MPK_DIR.parent
RECIPES = MPK_DIR / "recipes"
# Make-target names accepted as recipe names.
ALIASES = {"clang": "llvm-project", "gmake": "make"}
# Recipe name -> top-level Makefile target / build/<dir> of the wasm build,
# where they differ from the recipe name.
WASM_TARGETS = {"llvm-project": "clang", "make": "gmake"}
WASM_BUILD_DIRS = {"llvm-project": "clang"}
MODES = ("mpk", "wasm", "both")


# lindfs can hold root-owned entries (from sudo installs or guests running as
# root); fall back to sudo for those.
def _sudo(*cmd):
    subprocess.run(["sudo", "-n", *cmd], check=True)


def fs_remove(path):
    try:
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
    except PermissionError:
        _sudo("rm", "-rf", "--", str(path))


def fs_move(src, dst):
    try:
        shutil.move(str(src), str(dst))
    except PermissionError:
        if dst.exists() or dst.is_symlink():
            fs_remove(dst)
        _sudo("mv", "-T", "--", str(src), str(dst))


def fs_mkdir(path):
    try:
        path.mkdir(parents=True, exist_ok=True)
    except PermissionError:
        _sudo("mkdir", "-p", "--", str(path))


def fs_copy(src, dst):
    try:
        if src.is_symlink():
            dst.symlink_to(os.readlink(src))
        else:
            shutil.copy2(src, dst)
    except PermissionError:
        _sudo("cp", "-P", "--preserve=mode,timestamps", "--", str(src), str(dst))

VERDICT_ORDER = ["compatible", "partial", "runtime-fail", "rewrite-fail", "build-fail", "not-assessed"]
VERDICT_TEXT = {
    "compatible": "Compatible: builds, rewrites, and passes every check",
    "partial": "Partially compatible: runs, but some checks fail",
    "runtime-fail": "Rewritten, but no check passes under lind-mpk",
    "rewrite-fail": "Native build OK, gsfork-elf rewrite fails",
    "build-fail": "Native build against lind glibc fails",
    "not-assessed": "Not assessed (see reason)",
}
VERDICT_TEXT_WASM = dict(VERDICT_TEXT, **{
    "compatible": "Compatible: builds and passes every check",
    "runtime-fail": "Builds, but no check passes under lind-wasm",
    "build-fail": "wasm build (`make <app>` / `make install-<app>`) fails",
})


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


BUILD_PATTERNS = (r"\berror\b", r"\*\*\*", r"fatal", r"undefined reference", r"cannot|No such file")


def tail_reason(log, patterns=BUILD_PATTERNS):
    """Best-effort one-line failure reason from a log."""
    try:
        lines = Path(log).read_text(errors="replace").splitlines()
    except OSError:
        return ""
    rx = re.compile("|".join(patterns), re.I)
    # Skip compile progress lines like "CC reftable/error.o".
    quiet = re.compile(r"^\s*(?:CC|CXX|LD|AR|GEN|CCLD|CXXLD)\s+\S+$")
    # ... and compiler command lines naming files such as xstrtol-error.o.
    command = re.compile(r"^depbase=|\s-c\s.*-o\s|^\S*(?:clang|gcc|cc)\s+-")
    hits = [l.strip() for l in lines if rx.search(l) and not l.startswith("$ ") and not quiet.match(l)
            and not l.startswith("checking ") and not command.search(l)]
    # Prefer explicit diagnostics over make's "*** ... Error N" echoes.
    strong = [h for h in hits if patterns is BUILD_PATTERNS
              and re.search(r"^(?:fatal|error)\b|: (?:fatal )?error:|^ERROR\b", h, re.I)]
    pick = (strong or hits or [lines[-1].strip() if lines else ""])[0]
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
    fields = ["${KIND:-program}", "${DEPS[*]:-}", "${SKIP_REASON:-}", "${NOTE:-}", "${UPSTREAM_TESTS:-1}",
              "${RUNTIME_DEPS[*]:-}", "${WASM_TARGET:-}", "${WASM_BUILD_DIR:-}", "${WASM_RUN_ARGS[*]:-}",
              "${WASM_SKIP_REASON:-}", "${WASM_UPSTREAM_TESTS:-1}", "${WASM_NOTE:-}"]
    script = f'source "{recipe}"; printf "%s\\n" ' + " ".join(f'"{f}"' for f in fields)
    out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True).stdout
    (kind, deps, skip, note, upstream, rdeps, wtarget, wdir, wargs, wskip, wupstream,
     wnote) = (out.split("\n") + [""] * len(fields))[:len(fields)]
    app = recipe.stem
    return {"kind": kind, "deps": deps.split(), "skip": skip, "note": note, "upstream": upstream == "1",
            "rdeps": rdeps.split(),
            # --mode wasm: `make <wasm_target>` stages into build/<wasm_dir>/ and
            # `make install-<wasm_target>` copies that tree into lindfs.
            "wasm_target": wtarget or WASM_TARGETS.get(app, app),
            "wasm_dir": wdir or WASM_BUILD_DIRS.get(app, app),
            "wasm_run_args": wargs, "wasm_skip": wskip, "wasm_upstream": wupstream == "1", "wasm_note": wnote}


def recipe_key(recipe):
    """Native-build cache key input: the recipe without its WASM_* settings
    and without recipe_smoke(), so smoke-only edits keep the build cache."""
    text = re.sub(rb"(?m)^WASM_\w+=.*\n", b"", recipe.read_bytes())
    return re.sub(rb"(?ms)^recipe_smoke\(\) \{\n.*?^\}\n", b"", text)


def tool_versions(args, mode):
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
    versions = {
        "date": datetime.datetime.now().isoformat(timespec="seconds"),
        "lind-wasm": rev(args.lind_wasm_root),
        "lind-wasm-apps": apps_rev,
        "lind-boot md5": boot_md5,
    }
    if mode == "mpk":
        versions["rewriter"] = rewriter_version(Path(args.gsfork_elf).resolve())
        versions["gcc"] = subprocess.run(["gcc", "-dumpfullversion"], capture_output=True, text=True).stdout.strip()
    else:
        clang = Path(os.environ.get("LLVM_BIN_DIR", "")) / "clang"
        if not clang.exists():
            clang = shutil.which("clang") or "clang"
        out = subprocess.run([str(clang), "--version"], capture_output=True, text=True).stdout
        versions["clang"] = out.splitlines()[0] if out else "unknown"
        versions["LIND_DYLINK"] = os.environ.get("LIND_DYLINK", "1")
    return versions


def rewriter_version(gsfork):
    """git rev of the rewriter checkout (if available) plus a hash of its Python
    sources, so local patches to gsfork_elf show up in the report."""
    root = gsfork.parent.parent.parent  # <rewriter>/.venv/bin/gsfork-elf
    r = subprocess.run(["git", "-C", str(root), "rev-parse", "--short", "HEAD"], capture_output=True, text=True)
    srcs = sorted((root / "gsfork_elf").glob("*.py"))
    h = hashlib.md5(b"".join(p.read_bytes() for p in srcs)).hexdigest()[:12] if srcs else "?"
    return (r.stdout.strip() + " " if r.returncode == 0 else "") + f"gsfork_elf md5 {h}"


class Assessor:
    def __init__(self, args, mode, work, out):
        self.args = args
        self.mode = mode
        self.work = Path(work).resolve()
        self.out = Path(out).resolve()
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
        if mode == "mpk":
            self.rewrite_salt = self._rewrite_salt()
            self._shadow_roots()
        else:
            self._wasm_sysroot_check()
            self._wasm_runtime()

    def _rewrite_salt(self):
        """Inputs besides the program and flags that determine a rewrite: the
        rewriter sources and the glibc it reads (--tcb-layout, -L)."""
        h = hashlib.sha256(rewriter_version(Path(self.args.gsfork_elf).resolve()).encode())
        g = self.lind / "glibc-2.35" / "build"
        for lib in (g / "libc.so.6", g / "elf" / "ld.so", g / "math" / "libm.so"):
            if lib.exists():
                h.update(lib.read_bytes())
        return h.hexdigest().encode()

    # Upstream run_tests.sh scripts locate everything relative to their own path
    # and LIND_WASM_ROOT. Run them from shadow roots so they see MPK binaries in
    # build/<app>/ (not the wasm ones) and find scripts/bin/lind_run.
    def _shadow_roots(self):
        self.shadow_apps = self.work / "apps-root"
        self.stage = self.work / "stage"
        for d in (self.shadow_apps, self.stage):
            d.mkdir(parents=True, exist_ok=True)
        links = {self.shadow_apps / "build": self.stage, self.shadow_apps / "scripts": APPS_ROOT / "scripts"}
        for entry in APPS_ROOT.iterdir():
            if entry.is_dir() and (entry / "run_tests.sh").exists():
                links[self.shadow_apps / entry.name] = entry
        self._make_links(links)
        self._shadow_lind(self._real_lind_run())

    def _real_lind_run(self):
        lind_run = self.lind / "scripts" / "bin" / "lind_run"
        return lind_run if lind_run.exists() else self.lind / "scripts" / "lind_run"

    def _shadow_lind(self, lind_run):
        """A lind-wasm root whose scripts/bin/lind_run is `lind_run`; everything
        else links to the real checkout."""
        self.shadow_lind = self.work / "lind-root"
        (self.shadow_lind / "scripts" / "bin").mkdir(parents=True, exist_ok=True)
        self._make_links({
            self.shadow_lind / "lindfs": self.lindfs, self.shadow_lind / "build": self.lind / "build",
            # lind_run finds its repo root via ../../Makefile when sudo drops
            # LIND_WASM_ROOT; lmbench checks src/lind-boot/target/release.
            self.shadow_lind / "Makefile": self.lind / "Makefile",
            self.shadow_lind / "src": self.lind / "src",
            self.shadow_lind / "scripts" / "lind_run": lind_run,
            self.shadow_lind / "scripts" / "bin" / "lind_run": lind_run})

    @staticmethod
    def _make_links(links):
        for link, target in links.items():
            if link.is_symlink() or link.exists():
                link.unlink()
            link.symlink_to(target)

    # Apps built with `wasm-opt --fpcast-emu` (recipes whose WASM_RUN_ARGS has
    # --enable-fpcast) give libc function pointers whose table entries use the
    # emulated signature, so they need a libc/libm built the same way (cf.
    # `make fpcast` in lind-wasm and RUNTIME=fpcast in ../Dockerfile); with the
    # default runtime they trap "indirect call type mismatch", e.g. when exit()
    # runs their atexit handlers. Build that runtime next to the default one,
    # in lindfs /lib/fpcast, and run through a lind_run wrapper that preloads
    # it when LIND_ASSESS_RUNTIME=fpcast.
    FPCAST_LIBS = ("libc", "libm")

    def _wasm_runtime(self):
        sysroot = self._sysroot_libc().parent
        lind_boot = self.lind / "build" / "lind-boot"
        wasm_opt = self.lind / "scripts" / "bin" / "lind-wasm-opt"
        add_export = self.lind / "tools" / "add-export-tool" / "add-export-tool"
        inputs = [sysroot / "libc.so", sysroot / "libm.so", lind_boot, wasm_opt, add_export]
        dest = self.lindfs / "lib" / "fpcast"
        key = hashlib.sha256(b"".join(p.read_bytes() for p in inputs)).hexdigest()
        stamp = self.work / "fpcast-runtime.key"
        have = all((dest / f"{lib}.{ext}").exists() for lib in self.FPCAST_LIBS for ext in ("so", "cwasm"))
        if not (have and stamp.exists() and stamp.read_text() == key):
            print("[wasm-assess] building fpcast libc/libm into lindfs/lib/fpcast", flush=True)
            tmp = self.work / "fpcast-runtime"
            shutil.rmtree(tmp, ignore_errors=True)
            tmp.mkdir(parents=True)
            libc = tmp / "libc.so"
            # As scripts/build/make_shared_glibc.sh / make_shared_libm.sh with --with-fpcast.
            exports = [("__wasm_apply_tls_relocs", "func"), ("__wasm_apply_global_relocs", "func"),
                       ("__stack_pointer", "global")]
            src = sysroot / "libc.so"
            for name, kind in exports:
                subprocess.run([str(add_export), str(src), str(libc), name, kind, name], check=True,
                               stdout=subprocess.DEVNULL)
                src = libc
            for target, lib in (("libc", libc), ("library", sysroot / "libm.so")):
                subprocess.run([str(wasm_opt), f"--target={target}", "--fpcast-emu", str(lib),
                                "-o", str(tmp / lib.name)], check=True, stdout=subprocess.DEVNULL)
            for lib in self.FPCAST_LIBS:
                subprocess.run([str(lind_boot), "--precompile", str(tmp / f"{lib}.so")], check=True,
                               stdout=subprocess.DEVNULL)
            fs_mkdir(dest)
            for f in tmp.iterdir():
                if (dest / f.name).exists():
                    fs_remove(dest / f.name)
                fs_copy(f, dest / f.name)
            shutil.rmtree(tmp, ignore_errors=True)
            stamp.write_text(key)
        wrapper = self.work / "lind_run"
        wrapper.write_text(f"""#!/usr/bin/env bash
# Generated by lind-wasm-apps mpk/assess.py --mode wasm: lind_run, but with the
# fpcast libc/libm from lindfs /lib/fpcast when LIND_ASSESS_RUNTIME=fpcast or,
# if a plain `sudo` dropped that variable, when --enable-fpcast is passed.
set -euo pipefail
runtime="${{LIND_ASSESS_RUNTIME:-}}"
if [[ -z "$runtime" ]]; then
  runtime=default
  for a in "$@"; do [[ "$a" == --enable-fpcast ]] && runtime=fpcast; done
fi
[[ "$runtime" == fpcast ]] || exec {shlex.quote(str(self._real_lind_run()))} "$@"
[[ $EUID -eq 0 ]] || exec sudo -E LIND_ASSESS_RUNTIME=fpcast "$0" "$@"
exec {shlex.quote(str(lind_boot))} --preload env=/lib/fpcast/libc.cwasm --preload env=/lib/fpcast/libm.cwasm "$@"
""")
        wrapper.chmod(0o755)
        self._shadow_lind(wrapper)

    def env(self, app, meta=None):
        env = dict(os.environ)
        env.update(APP=app, APPS_ROOT=str(APPS_ROOT), LIND_WASM_ROOT=str(self.lind),
                   SRC=str(self.work / "src" / app), NATIVE=str(self.work / "native" / app),
                   PREFIX=str(self.prefix), JOBS=str(self.args.jobs),
                   SMOKE_TIMEOUT=str(self.args.smoke_timeout))
        if self.mode == "mpk":
            env["PATH"] = f"{self.shadow_lind / 'scripts'}:{env.get('PATH', '')}"
        else:
            env["LIND_RUN_ARGS"] = meta["wasm_run_args"] if meta else ""
            self.wasm_run_env(env, meta)
        return env

    def wasm_run_env(self, env, meta):
        """Run guests through the shadow root's lind_run wrapper (see _wasm_runtime)."""
        env["LIND_WASM_ROOT"] = str(self.shadow_lind)
        env["PATH"] = f"{self.shadow_lind / 'scripts' / 'bin'}:{self.lind / 'scripts' / 'bin'}:{env.get('PATH', '')}"
        fpcast = meta is not None and "--enable-fpcast" in meta["wasm_run_args"].split()
        env["LIND_ASSESS_RUNTIME"] = "fpcast" if fpcast else "default"

    def log(self, app, name):
        d = self.out / "logs" / app
        d.mkdir(parents=True, exist_ok=True)
        return d / f"{name}.log"

    # -- stages ---------------------------------------------------------------
    def copy_sources_cmd(self, app, src):
        """Command copying <app>/ into the scratch tree. In a git checkout the
        files are checked out from the index (committed + staged changes): the
        wasm builds (`make <app>`) build in tree, leave objects behind and
        regenerate tracked files (configure, config.hin, ...), and none of that
        may leak into the native build."""
        tracked = subprocess.run(["git", "-C", str(APPS_ROOT), "ls-files", "--", app],
                                 capture_output=True, text=True)
        if tracked.returncode != 0 or not tracked.stdout:
            return ["rsync", "-a", "--delete", f"{APPS_ROOT / app}/", f"{src}/"]
        # checkout-index --prefix recreates <app>/... below the prefix.
        tmp = src.parent / f".{app}.checkout"
        script = (f'set -e; rm -rf "$2" "$3"; mkdir -p "$2"; '
                  f'git -C "$1" ls-files -z -- "$4" | git -C "$1" checkout-index -z --stdin --prefix="$2/"; '
                  f'mv "$2/$4" "$3"; rmdir "$2"')
        return ["bash", "-c", script, "copy-sources", str(APPS_ROOT), str(tmp), str(src), app]

    def build(self, app, recipe, res):
        src, native = self.work / "src" / app, self.work / "native" / app
        stamp = native / ".mpk-build-ok"
        key = hashlib.sha256(recipe_key(recipe) + (MPK_DIR / "bin" / "lind-mpk-cc").read_bytes()
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
        rc, _ = sh(self.copy_sources_cmd(app, src), log)
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

    # -- wasm stages ----------------------------------------------------------
    def _wasm_sysroot_check(self):
        """The Makefile's merged-sysroot and library stamps do not notice a
        rebuilt lind-wasm sysroot; force them stale when its libc.a changed."""
        self.sysroot_key = hashlib.sha256(
            (os.environ.get("LIND_DYLINK", "1") + "\0").encode() + self._sysroot_libc().read_bytes()).hexdigest()
        stamp = self.work / "sysroot.key"
        if stamp.exists() and stamp.read_text() != self.sysroot_key:
            print("[assess] lind-wasm sysroot changed: make rebuild-sysroot rebuild-libs", flush=True)
            subprocess.run(["make", "-C", str(APPS_ROOT), "rebuild-sysroot", "rebuild-libs"], check=True,
                           stdout=subprocess.DEVNULL)
        stamp.write_text(self.sysroot_key)

    def _sysroot_libc(self):
        base = Path(os.environ.get("BASE_SYSROOT", self.lind / "src" / "glibc" / "sysroot"))
        return base / "lib" / "wasm32-wasi" / "libc.a"

    def make_env(self):
        env = {k: v for k, v in os.environ.items() if k not in ("APP", "SRC", "NATIVE", "PREFIX")}
        env.update(LIND_WASM_ROOT=str(self.lind), JOBS=str(self.args.jobs))
        env["PATH"] = f"{self.lind / 'scripts' / 'bin'}:{env.get('PATH', '')}"  # run_tests.sh calls lind_run
        return env

    def wasm_build(self, app, meta, res):
        stage = APPS_ROOT / "build" / meta["wasm_dir"]
        stamp = self.work / "stamps" / app
        compile_scripts = sorted((APPS_ROOT / app).rglob("compile_*.sh"))
        tree = subprocess.run(["git", "-C", str(APPS_ROOT), "rev-parse", f"HEAD:{app}"],
                              capture_output=True, text=True).stdout.strip()
        key = hashlib.sha256((self.sysroot_key + meta["wasm_target"] + tree).encode()
                             + b"".join(p.read_bytes() for p in compile_scripts)).hexdigest()
        log = self.log(app, "build")
        if not self.args.rebuild and stamp.exists() and stamp.read_text() == key and stage.is_dir():
            res["build"] = {"status": "ok", "cached": True}
            return True
        log.unlink(missing_ok=True)
        rc, secs = sh(["make", meta["wasm_target"]], log, env=self.make_env(), cwd=APPS_ROOT,
                      timeout=self.args.build_timeout)
        res["build"] = {"status": "ok" if rc == 0 else "fail", "seconds": secs,
                        "log": str(log.relative_to(self.out))}
        if rc != 0:
            res["build"]["reason"] = f"exit {rc}: " + tail_reason(log)
            return False
        if not stage.is_dir():
            # zlib, openssl, libtirpc, ed25519: the wasm build only produces a
            # library (in the merged sysroot); there is no program to run.
            res["skip"] = "library only: the wasm build stages no programs; exercised through its dependents"
            return False
        stamp.parent.mkdir(parents=True, exist_ok=True)
        stamp.write_text(key)
        return True

    def wasm_install(self, app, meta, res):
        """`make install-<target>`: the usual wasm workflow, which also installs
        shared libraries of dynamically linked builds. Not undone afterwards."""
        log = self.log(app, "install")
        log.unlink(missing_ok=True)
        rc, _ = sh(["make", f"install-{meta['wasm_target']}"], log, env=self.make_env(), cwd=APPS_ROOT,
                   timeout=self.args.build_timeout)
        if rc != 0:
            res["build"] = {"status": "fail", "reason": f"make install-{meta['wasm_target']} exit {rc}: "
                            + tail_reason(log), "log": str(log.relative_to(self.out))}
            return False
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
        key = hashlib.sha256(self.rewrite_salt + " ".join(cmd[4:]).encode() + path.read_bytes()).hexdigest()
        cached = self.work / "rewrite-cache" / key[:2] / key
        if cached.exists() and not self.args.no_rewrite_cache:
            shutil.copy2(cached, out)
            out.chmod(0o755)
            with open(log, "a") as fh:
                fh.write(f"cached rewrite of {path} ({cached})\n")
            entry = {"binary": "/" + str(rel), "status": "ok", "seconds": 0, "size": path.stat().st_size,
                     "cached": True}
            if extra:
                entry["needed"] = extra
            return entry
        # gsfork-elf caps each ddisasm/pprinter run at 300s by default; large
        # programs (openssl, gcc, clang) need longer. Bounded by --rewrite-timeout.
        env = dict(os.environ, GSFORK_TOOL_TIMEOUT=str(self.args.rewrite_timeout))
        env.setdefault("GSFORK_DDISASM_THREADS", str(self.ddisasm_threads))
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
            cached.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(out, cached)
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
        # ddisasm defaults to one Souffle thread per CPU. Its OpenMP threads
        # spin-wait, so concurrent rewrites must share the CPUs, not each take
        # all of them: 8 x 32 threads on 32 CPUs made a 150 KB program take an hour.
        workers = max(1, min(self.args.rewrite_workers, len(programs)))
        self.ddisasm_threads = max(1, len(os.sched_getaffinity(0)) // workers)
        # Largest first, so a big program (postgres, cc1) overlaps the small
        # ones instead of running alone at the end.
        order = sorted(programs, key=lambda p: p.stat().st_size, reverse=True)
        with concurrent.futures.ThreadPoolExecutor(workers) as pool:
            done = dict(zip(order, pool.map(lambda p: self.rewrite_one(app, native_root, p), order)))
        entries = [done[p] for p in programs]
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
                    fs_move(dest, saved)
                self.installed.append(dest)
            missing = [d for d in [dest.parent, *dest.parent.parents] if not d.exists()]
            self.created_dirs.extend(reversed(missing))
            fs_mkdir(dest.parent)
            if dest.exists() or dest.is_symlink():
                fs_remove(dest)
            fs_copy(path, dest)

    def restore_lindfs(self):
        for dest in reversed(self.installed):
            try:
                if dest.exists() or dest.is_symlink():
                    fs_remove(dest)
                saved = self.backup / dest.relative_to(self.lindfs)
                if saved.exists() or saved.is_symlink():
                    fs_move(saved, dest)
            except (OSError, subprocess.CalledProcessError) as e:
                print(f"[assess] warning: could not restore {dest}: {e}", file=sys.stderr, flush=True)
        # Smoke fixtures live in lindfs/tmp/mpk-*; guests ran as root via sudo.
        fixtures = [str(p) for p in (self.lindfs / "tmp").glob("mpk-*")]
        if fixtures:
            subprocess.run(["sudo", "-n", "rm", "-rf", "--", *fixtures], check=False)
        for d in reversed(self.created_dirs):
            try:
                d.rmdir()
            except OSError:
                pass

    def smoke(self, app, recipe, meta, res):
        log = self.log(app, "smoke")
        log.unlink(missing_ok=True)
        rc, secs = sh(["bash", str(MPK_DIR / "lib" / "stage.sh"), "smoke", str(recipe)], log,
                      env=self.env(app, meta), timeout=self.args.upstream_timeout)
        text = log.read_text(errors="replace")
        passed = re.findall(r"^SMOKE PASS: (.*)$", text, re.M)
        failed = re.findall(r"^SMOKE FAIL: (.*)$", text, re.M)
        skipped = re.findall(r"^SMOKE SKIP: (.*)$", text, re.M)
        self.note_issues(res, text)
        res["smoke"] = {"pass": len(passed), "fail": len(failed), "skip": len(skipped), "failures": failed,
                        "skipped": skipped, "seconds": secs, "log": str(log.relative_to(self.out))}
        if rc not in (0,) and not failed:
            res["smoke"]["fail"] += 1
            res["smoke"]["failures"].append(f"smoke script exit {rc}: {tail_reason(log)}")

    def upstream(self, app, meta, res):
        if not (APPS_ROOT / app / "run_tests.sh").exists():
            return
        log = self.log(app, "upstream")
        log.unlink(missing_ok=True)
        if self.mode == "mpk":
            env = self.env(app, meta)
            env["LIND_WASM_ROOT"] = str(self.shadow_lind)
            root = self.shadow_apps
        else:
            env = self.make_env()
            self.wasm_run_env(env, meta)
            root = APPS_ROOT
        env["LINDFS_ROOT"] = str(self.lindfs)
        scratch = self.lindfs / "tests" / app
        had_scratch = scratch.exists()
        rc, secs = sh(["bash", str(root / app / "run_tests.sh")], log, env=env, cwd=root / app,
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

    def prepare(self, app, recipe, meta, res):
        """Build the app (and rewrite it, for MPK) and install it into lindfs."""
        if self.mode == "wasm":
            return self.wasm_build(app, meta, res) and self.wasm_install(app, meta, res)
        if not (self.ensure_deps(app, meta, res) and self.build(app, recipe, res) and self.rewrite(app, res)):
            return False
        self.install(app)
        return True

    def assess(self, app):
        if app in self.results:
            return self.results[app]
        recipe = RECIPES / f"{app}.sh"
        meta = recipe_meta(recipe)
        wasm = self.mode == "wasm"
        res = {"app": app, "kind": meta["kind"], "note": meta["wasm_note"] if wasm else meta["note"]}
        self.results[app] = res
        shutil.rmtree(self.out / "logs" / app, ignore_errors=True)
        print(f"[{self.mode}-assess] {app}: start", flush=True)
        skip = meta["wasm_skip"] if wasm else meta["skip"]
        if skip:
            res["skip"] = skip
        else:
            try:
                if self.prepare(app, recipe, meta, res):
                    for dep in meta["rdeps"]:
                        self.assess(dep)
                    self.smoke(app, recipe, meta, res)
                    if (meta["wasm_upstream"] if wasm else meta["upstream"]) and not self.args.no_upstream:
                        self.upstream(app, meta, res)
            except (OSError, subprocess.SubprocessError) as e:
                # Keep going with the other apps; report this one as not assessed.
                res["skip"] = f"harness error: {type(e).__name__}: {e}"
        res["verdict"], res["reason"] = verdict(res)
        print(f"[{self.mode}-assess] {app}: {res['verdict']} {res['reason']}", flush=True)
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
    rw = res.get("rewrite", {"ok": 1, "total": 1})  # wasm mode: no rewrite stage
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
    any_pass = sm.get("pass", 0) > 0 or (up is not None and up["pass"] > 0)
    if not reasons:
        if not any_pass and sm.get("skip"):
            return "not-assessed", f"no check ran; smoke skipped: {(sm.get('skipped') or [''])[0]}"
        return "compatible", ""
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


def write_report(results, versions, out, mode):
    summary = {v: sorted(a for a, r in results.items() if r["verdict"] == v) for v in VERDICT_ORDER}
    (out / "report.json").write_text(json.dumps(
        {"mode": mode, "versions": versions, "summary": summary, "apps": results}, indent=2, default=str) + "\n")

    title = "lind-mpk (native, GS-Fork rewritten)" if mode == "mpk" else "lind-wasm (WebAssembly)"
    lines = [f"# {title} compatibility of lind-wasm-apps", "",
             "Generated by `mpk/assess.py` (see `mpk/README.md`). Do not edit by hand.", "",
             "| Component | Version |", "|---|---|"]
    lines += [f"| {k} | `{v}` |" for k, v in versions.items()]
    assessed = [a for a in results if results[a]["verdict"] != "not-assessed"]
    lines += ["", f"**{len(summary['compatible'])} of {len(results)} apps fully compatible** "
              f"({len(summary['compatible']) + len(summary['partial'])} run at least partially; "
              f"{len(assessed)} assessed).", "", "| Verdict | Count | Apps |", "|---|---|---|"]
    text = VERDICT_TEXT if mode == "mpk" else VERDICT_TEXT_WASM
    lines += [f"| {text[v]} | {len(summary[v])} | {', '.join(summary[v])} |" for v in VERDICT_ORDER
              if mode == "mpk" or v != "rewrite-fail"]
    lines += ["", "## Per app", "",
              "| App | Kind | Build | Rewrite | Smoke | run_tests.sh | Verdict | Runtime issues | First problem |",
              "|---|---|---|---|---|---|---|---|---|"]
    if mode == "wasm":
        lines[-2:] = ["| App | Kind | Build | Smoke | run_tests.sh | Verdict | Runtime issues | First problem |",
                      "|---|---|---|---|---|---|---|---|"]
    for app in sorted(results):
        r = results[app]
        b = r.get("build", {})
        build = "-" if r.get("skip") and not b else b.get("status", "-") + (
            " (cached)" if b.get("cached") else f" ({b['seconds']:.0f}s)" if "seconds" in b else "")
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
        cols = [app, r["kind"], build] + ([rw_s] if mode == "mpk" else []) + [sm_s, up_s, r["verdict"], issues or "-", reason]
        lines.append("| " + " | ".join(cols) + " |")
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
    logs = "build, rewrite-<binary>, smoke, upstream" if mode == "mpk" else "build, install, smoke, upstream"
    lines += ["", f"Logs: `logs/<app>/` next to this report ({logs}).", ""]
    (out / "report.md").write_text("\n".join(lines))


def write_comparison(out):
    """Side-by-side verdicts of the latest wasm and mpk reports."""
    reports = {}
    for mode, path in (("wasm", out / "wasm" / "report.json"), ("mpk", out / "report.json")):
        if not path.exists():
            return None
        reports[mode] = json.loads(path.read_text())
    w, m = reports["wasm"], reports["mpk"]

    def cell(r):
        if r is None:
            return "-"
        s = r["verdict"]
        sm, up = r.get("smoke"), r.get("upstream")
        if sm:
            s += f"; smoke {sm['pass']}/{sm['pass'] + sm['fail']}"
        if up:
            s += f"; tests {up['pass']}/{up['pass'] + up['fail']}"
        return s

    lines = ["# lind-wasm-apps under lind: WASM vs MPK", "",
             "Generated by `mpk/assess.py --mode both` (or `make experiments`). Details: "
             "[wasm/report.md](wasm/report.md), [report.md](report.md).", "",
             "| | WASM | MPK |", "|---|---|---|",
             f"| date | {w['versions']['date']} | {m['versions']['date']} |",
             f"| lind-wasm | `{w['versions']['lind-wasm']}` | `{m['versions']['lind-wasm']}` |"]
    for v in VERDICT_ORDER:
        lines.append(f"| {v} | {len(w['summary'][v])} | {len(m['summary'][v])} |")
    lines += ["", "| App | WASM | MPK |", "|---|---|---|"]
    for app in sorted(set(w["apps"]) | set(m["apps"])):
        lines.append(f"| {app} | {cell(w['apps'].get(app))} | {cell(m['apps'].get(app))} |")
    lines.append("")
    path = out / "comparison.md"
    path.write_text("\n".join(lines))
    return path


def main():
    # When started from `make experiments`, the outer make's MAKELEVEL/MAKEFLAGS
    # would leak into app builds (postgres only generates headers at MAKELEVEL 0).
    for var in ("MAKELEVEL", "MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES"):
        os.environ.pop(var, None)
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("apps", nargs="*", help="apps to assess (default: every recipe)")
    p.add_argument("--lind-wasm-root", default=os.environ.get("LIND_WASM_ROOT", str(Path.home() / "lind-wasm")))
    p.add_argument("--gsfork-elf", default=os.environ.get("GSFORK_ELF_BIN") or shutil.which("gsfork-elf")
                   or str(Path.home() / "rewriter" / ".venv" / "bin" / "gsfork-elf"))
    p.add_argument("--mode", choices=MODES, default="mpk",
                   help="mpk: native build + GS-Fork rewrite (default); wasm: the regular `make <app>` wasm "
                        "build; both: wasm, then mpk, then comparison.md")
    p.add_argument("--work", default=str(APPS_ROOT / "build" / "mpk"), help="MPK scratch dir (default build/mpk)")
    p.add_argument("--wasm-work", default=str(APPS_ROOT / "build" / "wasm-assess"),
                   help="WASM build stamps (default build/wasm-assess)")
    p.add_argument("--out", default=str(MPK_DIR / "results"),
                   help="report dir (default mpk/results; the WASM report goes to OUT/wasm)")
    p.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    p.add_argument("--rewrite-workers", type=int, default=8)
    p.add_argument("--build-timeout", type=int, default=3600)
    p.add_argument("--rewrite-timeout", type=int, default=3600)
    p.add_argument("--smoke-timeout", type=int, default=60, help="per smoke command")
    p.add_argument("--upstream-timeout", type=int, default=1800)
    p.add_argument("--rebuild", action="store_true", help="ignore cached builds")
    p.add_argument("--keep-src", action="store_true", help="keep build trees in WORK/src")
    p.add_argument("--keep-installed", action="store_true", help="leave MPK binaries in lindfs")
    p.add_argument("--no-upstream", action="store_true", help="skip <app>/run_tests.sh")
    p.add_argument("--no-rewrite-cache", action="store_true",
                   help="ignore cached rewrites in WORK/rewrite-cache (keyed by program, flags, rewriter and glibc)")
    p.add_argument("--exclude", nargs="+", default=[], metavar="APP",
                   help="apps to leave out of the default (all-recipes) set, e.g. --exclude gcc clang")
    args = p.parse_args()

    modes = ["wasm", "mpk"] if args.mode == "both" else [args.mode]
    if "mpk" in modes and not Path(args.gsfork_elf).exists():
        sys.exit(f"gsfork-elf not found ({args.gsfork_elf}); set GSFORK_ELF_BIN")
    if not (Path(args.lind_wasm_root) / "build" / "lind-boot").exists():
        sys.exit(f"lind-boot not built under {args.lind_wasm_root}; run `make lind-boot`")
    exclude = {ALIASES.get(a, a) for a in args.exclude}
    apps = [ALIASES.get(a, a) for a in args.apps] or sorted(r.stem for r in RECIPES.glob("*.sh"))
    apps = [a for a in apps if a not in exclude]
    unknown = [a for a in apps if not (RECIPES / f"{a}.sh").exists()]
    if unknown:
        sys.exit(f"no recipe for: {' '.join(unknown)}")

    for mode in modes:
        out = Path(args.out).resolve() / ("wasm" if mode == "wasm" else "")
        # Selecting or excluding apps is a partial run: other apps keep their
        # results and logs (e.g. gcc/clang from a run on a bigger machine).
        partial = bool(args.apps or exclude)
        if not partial and (out / "logs").exists():
            shutil.rmtree(out / "logs")
        assessor = Assessor(args, mode, args.wasm_work if mode == "wasm" else args.work, out)
        versions = tool_versions(args, mode)
        results = assessor.run(apps)
        if partial and (out / "report.json").exists():
            # Partial run: merge into the existing report so it stays complete.
            previous = json.loads((out / "report.json").read_text())["apps"]
            previous.update(results)
            results = previous
        write_report(results, versions, out, mode)
        print(f"[{mode}-assess] report: {out / 'report.md'}", flush=True)
    comparison = write_comparison(Path(args.out).resolve())
    if comparison:
        print(f"[assess] comparison: {comparison}")


if __name__ == "__main__":
    main()
