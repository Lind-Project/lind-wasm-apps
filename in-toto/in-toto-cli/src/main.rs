//! in-toto-cli: small command-line driver for the `in-toto` crate.
//!
//!   keygen     <out.pk8> <out.pub.json>
//!   run        --name <step> --key <pk8> --out <link-dir> [--materials p..] [--products p..] [--lstrip <prefix>] [-- <cmd> <args..>]
//!   gen-layout --key <owner.pk8> --step-key <functionary.pub.json> --out <root.layout> [--expires <RFC3339>]
//!              [--src <file>] [--pkg <file>] [--step-src <name>] [--step-pkg <name>] [-- <expected cmd of step-pkg>]
//!   verify     --layout <root.layout> --key <owner.pub.json> --links <link-dir>
//!
//! No clap, no std::net, no std::process (unsupported on wasm32-wasip1).
//! `run -- <cmd>` uses libc fork/execv/waitpid directly, the same way the Rust
//! grates launch their child, so the command runs as a child cage under lind.

use std::collections::HashMap;
use std::ffi::CString;
use std::fs;
use std::os::raw::{c_char, c_int};
use std::path::Path;
use std::process::exit;
use std::ptr;

use chrono::{DateTime, Utc};
use in_toto::crypto::{KeyId, KeyType, PrivateKey, PublicKey, SignatureScheme};
use in_toto::models::rule::{Artifact, ArtifactRule};
use in_toto::models::step::{Command, Step};
use in_toto::interchange::Json;
use in_toto::models::byproducts::ByProducts;
use in_toto::models::{
    LayoutMetadataBuilder, LinkMetadataBuilder, Metablock, MetadataWrapper, VirtualTargetPath,
};
use in_toto::runlib::record_artifacts;
use in_toto::verifylib::in_toto_verify;

// Defaults for the two-step demo layout: <step-src> creates <src>, <step-pkg>
// consumes <src> and creates <pkg>. All four can be overridden.
const STEP_WRITE: &str = "write-code";
const STEP_PACKAGE: &str = "package";
const ARTIFACT_SRC: &str = "foo.py";
const ARTIFACT_PKG: &str = "foo.tar.gz";

fn usage() -> ! {
    eprintln!(
        "usage:\n  in-toto-cli keygen <out.pk8> <out.pub.json>\n  in-toto-cli run --name <step> --key <pk8> --out <link-dir> [--materials p..] [--products p..] [--lstrip <prefix>] [-- <cmd> <args..>]\n  in-toto-cli gen-layout --key <owner.pk8> --step-key <functionary.pub.json> --out <root.layout> [--expires <RFC3339>] [--src <file>] [--pkg <file>] [--step-src <name>] [--step-pkg <name>] [-- <expected cmd>]\n  in-toto-cli verify --layout <root.layout> --key <owner.pub.json> --links <link-dir>"
    );
    exit(2)
}

fn die(msg: impl std::fmt::Display) -> ! {
    eprintln!("in-toto-cli: error: {}", msg);
    exit(1)
}

/// Minimal `--flag value...` parser.
struct Opts {
    map: HashMap<String, Vec<String>>,
}

impl Opts {
    fn parse(args: &[String]) -> Opts {
        let mut map: HashMap<String, Vec<String>> = HashMap::new();
        let mut cur: Option<String> = None;
        for a in args {
            if let Some(flag) = a.strip_prefix("--") {
                cur = Some(flag.to_string());
                map.entry(flag.to_string()).or_default();
            } else if let Some(f) = &cur {
                map.get_mut(f).unwrap().push(a.clone());
            } else {
                die(format!("unexpected positional argument '{}'", a));
            }
        }
        Opts { map }
    }
    fn one(&self, flag: &str) -> String {
        match self.map.get(flag) {
            Some(v) if v.len() == 1 => v[0].clone(),
            Some(v) => die(format!("--{} expects exactly one value, got {}", flag, v.len())),
            None => die(format!("missing required option --{}", flag)),
        }
    }
    fn opt(&self, flag: &str) -> Option<String> {
        self.map.get(flag).map(|v| {
            if v.len() != 1 {
                die(format!("--{} expects exactly one value", flag))
            }
            v[0].clone()
        })
    }
    fn many(&self, flag: &str) -> Vec<String> {
        self.map.get(flag).cloned().unwrap_or_default()
    }
}

fn load_private_key(path: &str) -> PrivateKey {
    let der = fs::read(path).unwrap_or_else(|e| die(format!("read {}: {}", path, e)));
    PrivateKey::from_pkcs8(&der, SignatureScheme::Ed25519)
        .unwrap_or_else(|e| die(format!("parse pkcs8 {}: {:?}", path, e)))
}

fn load_public_key(path: &str) -> PublicKey {
    let s = fs::read_to_string(path).unwrap_or_else(|e| die(format!("read {}: {}", path, e)));
    serde_json::from_str::<PublicKey>(&s)
        .unwrap_or_else(|e| die(format!("parse public key {}: {}", path, e)))
}

fn write_json<T: serde::Serialize>(path: &str, v: &T) {
    let s = serde_json::to_string_pretty(v).unwrap_or_else(|e| die(format!("serialize: {}", e)));
    fs::write(path, s.as_bytes()).unwrap_or_else(|e| die(format!("write {}: {}", path, e)));
}

fn vpath(s: &str) -> VirtualTargetPath {
    VirtualTargetPath::new(s.to_string()).unwrap_or_else(|e| die(format!("bad path {}: {:?}", s, e)))
}

fn cmd_keygen(args: &[String]) {
    if args.len() != 2 {
        usage();
    }
    let der = PrivateKey::new(KeyType::Ed25519).unwrap_or_else(|e| die(format!("keygen: {:?}", e)));
    fs::write(&args[0], &der).unwrap_or_else(|e| die(format!("write {}: {}", args[0], e)));
    let key = PrivateKey::from_pkcs8(&der, SignatureScheme::Ed25519)
        .unwrap_or_else(|e| die(format!("reparse generated key: {:?}", e)));
    write_json(&args[1], key.public());
    println!("keyid {}", key_id_str(key.key_id()));
}

fn key_id_str(k: &KeyId) -> String {
    serde_json::to_value(k)
        .ok()
        .and_then(|v| v.as_str().map(|s| s.to_string()))
        .unwrap_or_else(|| format!("{:?}", k))
}

extern "C" {
    fn fork() -> c_int;
    fn execv(path: *const c_char, argv: *const *const c_char) -> c_int;
    fn waitpid(pid: c_int, status: *mut c_int, options: c_int) -> c_int;
    fn _exit(code: c_int) -> !;
}

/// Run `cmd` as a child process and return its exit status.
/// fork/execv/waitpid come from glibc; on lind the child is a new cage, so a
/// grate wrapping this process (e.g. the IMFS grate) also sees the child.
fn run_child(cmd: &[String]) -> i32 {
    let cstrs: Vec<CString> = cmd
        .iter()
        .map(|s| CString::new(s.as_str()).unwrap_or_else(|_| die(format!("bad argument {:?}", s))))
        .collect();
    let mut argv: Vec<*const c_char> = cstrs.iter().map(|s| s.as_ptr()).collect();
    argv.push(ptr::null());

    let pid = unsafe { fork() };
    if pid < 0 {
        die(format!("fork: {}", std::io::Error::last_os_error()));
    }
    if pid == 0 {
        unsafe { execv(argv[0], argv.as_ptr()) };
        eprintln!("execv {}: {}", cmd[0], std::io::Error::last_os_error());
        unsafe { _exit(127) }
    }
    let mut status: c_int = 0;
    if unsafe { waitpid(pid, &mut status, 0) } < 0 {
        die(format!("waitpid: {}", std::io::Error::last_os_error()));
    }
    if status & 0x7f != 0 {
        die(format!("command killed by signal {}", status & 0x7f));
    }
    (status >> 8) & 0xff
}

fn cmd_run(args: &[String]) {
    // Everything after "--" is the step command; it runs between recording
    // materials and recording products, like in-toto-run.
    let (opt_args, cmd) = match args.iter().position(|a| a == "--") {
        Some(i) => (&args[..i], &args[i + 1..]),
        None => (args, &args[args.len()..]),
    };
    let o = Opts::parse(opt_args);
    let name = o.one("name");
    let key = load_private_key(&o.one("key"));
    let out_dir = o.one("out");
    let materials = o.many("materials");
    let products = o.many("products");
    let lstrip = o.opt("lstrip");

    let mats: Vec<&str> = materials.iter().map(String::as_str).collect();
    let prods: Vec<&str> = products.iter().map(String::as_str).collect();
    let lstrip_v: Vec<&str> = lstrip.iter().map(String::as_str).collect();
    let lstrip_opt: Option<&[&str]> = if lstrip_v.is_empty() { None } else { Some(&lstrip_v) };

    let materials = record_artifacts(&mats, None, lstrip_opt)
        .unwrap_or_else(|e| die(format!("record materials: {:?}", e)));

    let mut byproducts = ByProducts::new();
    if !cmd.is_empty() {
        let rc = run_child(cmd);
        if rc != 0 {
            eprintln!("warning: {} exited with status {}", cmd[0], rc);
        }
        byproducts = byproducts.set_return_value(rc);
    }

    let products = record_artifacts(&prods, None, lstrip_opt)
        .unwrap_or_else(|e| die(format!("record products: {:?}", e)));

    let link = LinkMetadataBuilder::new()
        .name(name.clone())
        .materials(materials)
        .byproducts(byproducts)
        .command(Command::from(cmd))
        .products(products)
        .signed::<Json>(&key)
        .unwrap_or_else(|e| die(format!("sign link {}: {:?}", name, e)));

    let fname = format!("{}.{}.link", name, key.key_id().prefix());
    let path = Path::new(&out_dir).join(&fname);
    write_json(path.to_str().unwrap(), &link);
    println!("wrote {}", path.display());
}

fn cmd_gen_layout(args: &[String]) {
    // Everything after "--" is the expected command of the second step.
    let (opt_args, cmd) = match args.iter().position(|a| a == "--") {
        Some(i) => (&args[..i], &args[i + 1..]),
        None => (args, &args[args.len()..]),
    };
    let o = Opts::parse(opt_args);
    let owner = load_private_key(&o.one("key"));
    let functionary = load_public_key(&o.one("step-key"));
    let out = o.one("out");
    let step_src = o.opt("step-src").unwrap_or_else(|| STEP_WRITE.to_string());
    let step_pkg = o.opt("step-pkg").unwrap_or_else(|| STEP_PACKAGE.to_string());
    let art_src = o.opt("src").unwrap_or_else(|| ARTIFACT_SRC.to_string());
    let art_pkg = o.opt("pkg").unwrap_or_else(|| ARTIFACT_PKG.to_string());

    let mut builder = LayoutMetadataBuilder::new()
        .readme(format!("lind-wasm in-toto demo layout: {} -> {}", step_src, step_pkg))
        .add_key(functionary.clone());
    if let Some(exp) = o.opt("expires") {
        let dt = DateTime::parse_from_rfc3339(&exp)
            .unwrap_or_else(|e| die(format!("--expires must be RFC3339: {}", e)))
            .with_timezone(&Utc);
        builder = builder.expires(dt);
    }

    let write_code = Step::new(&step_src)
        .threshold(1)
        .add_key(functionary.key_id().clone())
        .add_expected_product(ArtifactRule::Create(vpath(&art_src)))
        .add_expected_product(ArtifactRule::Disallow(vpath("*")));

    let mut package = Step::new(&step_pkg)
        .threshold(1)
        .add_key(functionary.key_id().clone())
        .add_expected_material(ArtifactRule::Match {
            pattern: vpath(&art_src),
            in_src: None,
            with: Artifact::Products,
            in_dst: None,
            from: step_src.clone(),
        })
        .add_expected_material(ArtifactRule::Disallow(vpath("*")))
        .add_expected_product(ArtifactRule::Create(vpath(&art_pkg)))
        .add_expected_product(ArtifactRule::Disallow(vpath("*")));
    if !cmd.is_empty() {
        package = package.expected_command(Command::from(cmd));
    }

    let layout = builder
        .add_step(write_code)
        .add_step(package)
        .build()
        .unwrap_or_else(|e| die(format!("build layout: {:?}", e)));

    let mb = Metablock::new(MetadataWrapper::Layout(layout), &[&owner])
        .unwrap_or_else(|e| die(format!("sign layout: {:?}", e)));
    write_json(&out, &mb);
    println!("wrote {}", out);
}

fn cmd_verify(args: &[String]) {
    let o = Opts::parse(args);
    let layout_path = o.one("layout");
    let links = o.one("links");
    let raw = fs::read(&layout_path).unwrap_or_else(|e| die(format!("read {}: {}", layout_path, e)));
    let layout = serde_json::from_slice::<Metablock>(&raw)
        .unwrap_or_else(|e| die(format!("parse layout {}: {}", layout_path, e)));

    let mut keys: HashMap<KeyId, PublicKey> = HashMap::new();
    for k in o.many("key") {
        let pk = load_public_key(&k);
        keys.insert(pk.key_id().clone(), pk);
    }
    if keys.is_empty() {
        die("verify needs at least one --key");
    }

    match in_toto_verify(&layout, keys, &links, None) {
        Ok(summary) => {
            println!("VERIFIED");
            if let MetadataWrapper::Link(l) = &summary.metadata {
                let mut names: Vec<&str> = l.products.keys().map(|k| k.value()).collect();
                names.sort_unstable();
                for n in names {
                    println!("product {}", n);
                }
            }
        }
        Err(e) => {
            println!("FAILED");
            eprintln!("in-toto-cli: verification failed: {:?}", e);
            exit(1);
        }
    }
}

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    if argv.len() < 2 {
        usage();
    }
    let rest = &argv[2..];
    match argv[1].as_str() {
        "keygen" => cmd_keygen(rest),
        "run" => cmd_run(rest),
        "gen-layout" => cmd_gen_layout(rest),
        "verify" => cmd_verify(rest),
        _ => usage(),
    }
}
