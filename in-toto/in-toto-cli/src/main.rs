//! in-toto-cli: small command-line driver for the `in-toto` crate.
//!
//!   keygen     <out.pk8> <out.pub.json>
//!   run        --name <step> --key <pk8> --out <link-dir> [--materials p..] [--products p..] [--lstrip <prefix>]
//!   gen-layout --key <owner.pk8> --step-key <functionary.pub.json> --out <root.layout> [--expires <RFC3339>]
//!   verify     --layout <root.layout> --key <owner.pub.json> --links <link-dir>
//!
//! No clap, no std::net, no std::process (unsupported on wasm32-wasip1).

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::process::exit;

use chrono::{DateTime, Utc};
use in_toto::crypto::{KeyId, KeyType, PrivateKey, PublicKey, SignatureScheme};
use in_toto::models::rule::{Artifact, ArtifactRule};
use in_toto::models::step::Step;
use in_toto::models::{LayoutMetadataBuilder, Metablock, MetadataWrapper, VirtualTargetPath};
use in_toto::runlib::in_toto_run;
use in_toto::verifylib::in_toto_verify;

const STEP_WRITE: &str = "write-code";
const STEP_PACKAGE: &str = "package";
const ARTIFACT_SRC: &str = "foo.py";
const ARTIFACT_PKG: &str = "foo.tar.gz";

fn usage() -> ! {
    eprintln!(
        "usage:\n  in-toto-cli keygen <out.pk8> <out.pub.json>\n  in-toto-cli run --name <step> --key <pk8> --out <link-dir> [--materials p..] [--products p..] [--lstrip <prefix>]\n  in-toto-cli gen-layout --key <owner.pk8> --step-key <functionary.pub.json> --out <root.layout> [--expires <RFC3339>]\n  in-toto-cli verify --layout <root.layout> --key <owner.pub.json> --links <link-dir>"
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

fn cmd_run(args: &[String]) {
    let o = Opts::parse(args);
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

    // Empty command: only record and sign artifacts.
    let link = in_toto_run(&name, None, &mats, &prods, &[], Some(&key), None, lstrip_opt)
        .unwrap_or_else(|e| die(format!("in_toto_run({}): {:?}", name, e)));

    let fname = format!("{}.{}.link", name, key.key_id().prefix());
    let path = Path::new(&out_dir).join(&fname);
    write_json(path.to_str().unwrap(), &link);
    println!("wrote {}", path.display());
}

fn cmd_gen_layout(args: &[String]) {
    let o = Opts::parse(args);
    let owner = load_private_key(&o.one("key"));
    let functionary = load_public_key(&o.one("step-key"));
    let out = o.one("out");

    let mut builder = LayoutMetadataBuilder::new()
        .readme("lind-wasm in-toto demo layout: write-code -> package".to_string())
        .add_key(functionary.clone());
    if let Some(exp) = o.opt("expires") {
        let dt = DateTime::parse_from_rfc3339(&exp)
            .unwrap_or_else(|e| die(format!("--expires must be RFC3339: {}", e)))
            .with_timezone(&Utc);
        builder = builder.expires(dt);
    }

    let write_code = Step::new(STEP_WRITE)
        .threshold(1)
        .add_key(functionary.key_id().clone())
        .add_expected_product(ArtifactRule::Create(vpath(ARTIFACT_SRC)))
        .add_expected_product(ArtifactRule::Disallow(vpath("*")));

    let package = Step::new(STEP_PACKAGE)
        .threshold(1)
        .add_key(functionary.key_id().clone())
        .add_expected_material(ArtifactRule::Match {
            pattern: vpath(ARTIFACT_SRC),
            in_src: None,
            with: Artifact::Products,
            in_dst: None,
            from: STEP_WRITE.to_string(),
        })
        .add_expected_material(ArtifactRule::Disallow(vpath("*")))
        .add_expected_product(ArtifactRule::Create(vpath(ARTIFACT_PKG)))
        .add_expected_product(ArtifactRule::Disallow(vpath("*")));

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
