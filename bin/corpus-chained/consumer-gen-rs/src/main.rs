//! consumer-gen-rs — generate a CONSUMER CRATE from a library crate's public API.
//!
//! The rust half of the chained census (SOUNDNESS R671 built the java half; R673(a) records that
//! rust was never run).  Usage:
//!
//!     consumer-gen-rs <LIB_CRATE_DIR> <OUT_CRATE_DIR> <MANIFEST_JSON> [--cap N] [--variant noimpl|impl]
//!
//! WHY GENERATED.  At 1,625 crates a hand-written consumer is not an option, and ⟨0.39⟩
//! obligation 3 is mechanical: a consumer that calls a dependency's trait method through an erased
//! receiver must be told what the dependency could not resolve.  So the probes are derived, not
//! invented.
//!
//! WHY `syn` AND NOT THE ENGINE'S OWN REPORT.  Two reasons, and the second is the important one.
//! (1) A candor report is not an API listing — a pure function is OMITTED by design, so
//! `tower-service`'s report holds 2 rows for 4 analysed units.  (2) A consumer generated from the
//! engine's report could only ever probe what the engine already sees, so every defect of the form
//! "the engine does not recognise this declaration" would be invisible BY CONSTRUCTION, and the two
//! arms would not even share a consumer.  `syn` is the same parser candor-scan reads rust with, so
//! the generator is asking the authority rather than reimplementing it (brief §G).
//!
//! WHY IT NEED NOT COMPILE.  `candor-scan` analyses SOURCE; there is no build step in the chain.
//! That is the one place rust is easier than java, where every generated call had to survive javac
//! and a line-by-line recovery loop.  The probe bodies are therefore syntactically valid rust that
//! is not necessarily type-correct — and every probe body holds EXACTLY ONE CALL, with the callee's
//! arguments supplied as the probe's own parameters rather than constructed.  A `Default::default()`
//! or a `todo!()` in argument position would put a second, synthetic call in the body and any effect
//! it attracted would be indistinguishable from the one under test.
//!
//! WHAT IS PROBED, and why these shapes.  The fix window this arm measures is almost entirely
//! receiver-typing and dispatch work (R549, R551, R556, R557, R561, R562, R564, R569, R571, R576b,
//! R582, R597, R598, R608/R609, R652), so the dispatch probe comes in four receiver spellings that
//! those rows are about, plus two non-dispatch controls:
//!
//!   dyn     `fn p(r: &dyn lib::Tr, ..)          { r.m(..) }`   erased parameter receiver
//!   gen     `fn p<T: lib::Tr>(r: &T, ..)        { r.m(..) }`   monomorphised receiver (R582)
//!   let     `fn p(b: Box<dyn lib::Tr>, ..)      { let r = &*b; r.m(..) }`  let-position (R556/R569)
//!   fnref   `fn p(r: &dyn lib::Tr, ..)          { let f = lib::Tr::m; f(r, ..) }`  (R549)
//!   call    `fn p(..)                           { lib::path::f(..) }`   plain cross-crate call
//!   inh     `fn p(x: &lib::path::S, ..)         { x.m(..) }`    inherent method (R598's control)
//!   assoc   `fn p(..)                           { lib::path::S::new(..) }`
//!
//! MODULE STRUCTURE IS MIRRORED, DELIBERATELY.  R673(b) records that the java arm's CLASS scope is
//! degenerate by construction, because ConsumerGen emits one probe method per probe class.  The
//! scope rung that matters for rust is the MODULE (R664 measured 0 flips there), so a generator that
//! put one probe in one module would manufacture a module-scope result.  Every probe for a library
//! item at `lib::a::b::C::m` is emitted into consumer module `a::b`, so a consumer module holds as
//! many probes as the library module has public items, and module scope is a real widening of
//! function scope.  Items at the library's crate root go to consumer module `root`.
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

// ── what the walk collects ────────────────────────────────────────────────────────────────────────
struct TraitTarget {
    mod_path: Vec<String>,
    name: String,
    methods: Vec<(String, usize)>, // (method, arity excluding self)
}
struct FnTarget {
    mod_path: Vec<String>,
    name: String,
    arity: usize,
}
struct InhTarget {
    mod_path: Vec<String>,
    ty: String,
    name: String,
    arity: usize,
    has_self: bool,
}

#[derive(Default)]
struct Coll {
    traits: Vec<TraitTarget>,
    fns: Vec<FnTarget>,
    inh: Vec<InhTarget>,
    /// A skip is a probe NOT written.  It is not a clean result, so it is counted and reported.
    skips: BTreeMap<String, usize>,
}

impl Coll {
    fn skip(&mut self, why: &str) {
        *self.skips.entry(why.to_string()).or_insert(0) += 1;
    }
}

fn is_pub(v: &syn::Visibility) -> bool {
    matches!(v, syn::Visibility::Public(_))
}

fn recv_arity(sig: &syn::Signature) -> (bool, usize) {
    let mut has_self = false;
    let mut n = 0usize;
    for a in &sig.inputs {
        match a {
            syn::FnArg::Receiver(_) => has_self = true,
            syn::FnArg::Typed(_) => n += 1,
        }
    }
    (has_self, n)
}

fn path_attr(attrs: &[syn::Attribute]) -> Option<String> {
    for a in attrs {
        if a.path().is_ident("path") {
            if let syn::Meta::NameValue(nv) = &a.meta {
                if let syn::Expr::Lit(syn::ExprLit { lit: syn::Lit::Str(s), .. }) = &nv.value {
                    return Some(s.value());
                }
            }
        }
    }
    None
}

/// Walk one parsed module body.  `dir` is the directory `mod x;` resolves against, `mod_path` the
/// public path of this module from the crate root.
fn walk(items: &[syn::Item], dir: &Path, mod_path: &[String], c: &mut Coll, depth: usize) {
    if depth > 12 {
        c.skip("module nesting deeper than 12");
        return;
    }
    for it in items {
        match it {
            syn::Item::Mod(m) => {
                // ONLY `pub mod`.  A private module's items are not nameable from a consumer even
                // when a `pub use` re-exports them under another path, and a probe naming an
                // unnameable path measures nothing.  This UNDER-counts (re-exports are missed) and
                // that is the safe direction: it never writes a probe the consumer could not write.
                if !is_pub(&m.vis) {
                    c.skip("private `mod` (its items are not nameable by a consumer)");
                    continue;
                }
                let mut sub = mod_path.to_vec();
                sub.push(m.ident.to_string());
                if let Some((_, inner)) = &m.content {
                    walk(inner, dir, &sub, c, depth + 1);
                    continue;
                }
                let name = m.ident.to_string();
                let cand: Vec<PathBuf> = match path_attr(&m.attrs) {
                    Some(p) => vec![dir.join(p)],
                    None => vec![dir.join(format!("{name}.rs")), dir.join(&name).join("mod.rs")],
                };
                let mut found = false;
                for f in cand {
                    if !f.is_file() {
                        continue;
                    }
                    found = true;
                    let src = match std::fs::read_to_string(&f) {
                        Ok(s) => s,
                        Err(_) => {
                            c.skip("module file unreadable");
                            break;
                        }
                    };
                    match syn::parse_file(&src) {
                        Ok(ast) => {
                            let ndir = f.parent().unwrap_or(dir);
                            let ndir = if f.file_name().map(|x| x == "mod.rs").unwrap_or(false) {
                                ndir.to_path_buf()
                            } else {
                                ndir.join(&name)
                            };
                            let ndir = if ndir.is_dir() { ndir } else { f.parent().unwrap_or(dir).to_path_buf() };
                            walk(&ast.items, &ndir, &sub, c, depth + 1);
                        }
                        Err(_) => c.skip("module file did not parse as rust"),
                    }
                    break;
                }
                if !found {
                    // A `#[cfg(...)]`-gated module whose file is not in the published .crate, or a
                    // platform module.  Named rather than silently dropped.
                    c.skip("`pub mod` with no file on disk (cfg-gated or platform-specific)");
                }
            }
            syn::Item::Trait(t) => {
                if !is_pub(&t.vis) {
                    c.skip("private trait");
                    continue;
                }
                let mut methods = vec![];
                for ti in &t.items {
                    if let syn::TraitItem::Fn(f) = ti {
                        let (has_self, n) = recv_arity(&f.sig);
                        if has_self {
                            methods.push((f.sig.ident.to_string(), n));
                        } else {
                            c.skip("trait associated fn with no `self` (not a dispatch)");
                        }
                    }
                }
                if methods.is_empty() {
                    c.skip("public trait with no `self`-taking method");
                    continue;
                }
                c.traits.push(TraitTarget {
                    mod_path: mod_path.to_vec(),
                    name: t.ident.to_string(),
                    methods,
                });
            }
            syn::Item::Fn(f) => {
                if !is_pub(&f.vis) {
                    c.skip("private fn");
                    continue;
                }
                let (_, n) = recv_arity(&f.sig);
                c.fns.push(FnTarget {
                    mod_path: mod_path.to_vec(),
                    name: f.sig.ident.to_string(),
                    arity: n,
                });
            }
            syn::Item::Impl(im) => {
                if im.trait_.is_some() {
                    continue; // a trait impl is not part of the callable surface a consumer names
                }
                let ty = match &*im.self_ty {
                    syn::Type::Path(p) => match p.path.segments.last() {
                        Some(s) => s.ident.to_string(),
                        None => {
                            c.skip("inherent impl on an unnameable type");
                            continue;
                        }
                    },
                    _ => {
                        c.skip("inherent impl on a non-path type");
                        continue;
                    }
                };
                for ii in &im.items {
                    if let syn::ImplItem::Fn(f) = ii {
                        if !is_pub(&f.vis) {
                            c.skip("private inherent method");
                            continue;
                        }
                        let (has_self, n) = recv_arity(&f.sig);
                        c.inh.push(InhTarget {
                            mod_path: mod_path.to_vec(),
                            ty: ty.clone(),
                            name: f.sig.ident.to_string(),
                            arity: n,
                            has_self,
                        });
                    }
                }
            }
            _ => {}
        }
    }
}

// ── emission ─────────────────────────────────────────────────────────────────────────────────────
struct Probe {
    /// consumer module path (mirrors the library's), e.g. `["auth","add_authorization"]`
    m: Vec<String>,
    /// the probe's own fn name
    name: String,
    body: String,
    shape: &'static str,
    /// the library item the probe names, for the manifest
    target: String,
}

fn args_sig(n: usize) -> String {
    (0..n).map(|i| format!(", a{i}: ()")).collect::<String>()
}
fn args_call(n: usize) -> String {
    (0..n).map(|i| if i == 0 { format!("a{i}") } else { format!(", a{i}") }).collect::<String>()
}
fn args_call_after(n: usize) -> String {
    (0..n).map(|i| format!(", a{i}")).collect::<String>()
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 4 {
        eprintln!("usage: consumer-gen-rs <LIB_CRATE_DIR> <OUT_CRATE_DIR> <MANIFEST_JSON> [--cap N] [--variant noimpl|impl]");
        std::process::exit(2);
    }
    let lib = PathBuf::from(&a[1]);
    let out = PathBuf::from(&a[2]);
    let manifest = PathBuf::from(&a[3]);
    let mut cap = 0usize;
    if let Some(i) = a.iter().position(|x| x == "--cap") {
        cap = a.get(i + 1).and_then(|s| s.parse().ok()).unwrap_or(0);
    }
    // TWO VARIANTS, AND THEY CANNOT SHARE ONE CRATE.  ⟨0.39⟩ conjunct 4 — "this crate supplies no
    // implementor of that abstraction" — is asked of the CRATE, so a consumer that both withholds and
    // supplies an implementor of the same trait answers only the second question.  So the arm builds
    // two consumers per library and scans both:
    //   noimpl  the java arm's shape (ConsumerGen holds no implementor).  Nothing effectful is
    //           planted, so every effect in this consumer arrived across the dependency boundary and
    //           the module/crate scope arithmetic is clean.
    //   impl    an effectful implementor of every public trait, in ONE separate top-level module, plus
    //           the same dispatch and call probes.  This is R529's chained shape and the only one that
    //           can see the implementor-union half of the window (R576b, R597, R598, R652).  Its
    //           scope arithmetic is NOT clean — the planted `Exec` is already in the crate on both
    //           arms — so this variant is quotable at FUNCTION scope only, and the judge says so.
    let mut variant = "noimpl".to_string();
    if let Some(i) = a.iter().position(|x| x == "--variant") {
        variant = a.get(i + 1).cloned().unwrap_or_else(|| "noimpl".to_string());
    }
    if variant != "noimpl" && variant != "impl" {
        eprintln!("BAD-VARIANT {variant} (want noimpl|impl)");
        std::process::exit(2);
    }
    // Rare enough in real libraries that the planted effect does not drown the joined ones, and
    // distinguishable from `Fs`, which the java arm plants.
    const SINK: &str = "let _ = std::process::Command::new(\"true\").status();";

    // ── the crate's PACKAGE name and its LINK name.  The dep report's `package` field and the path
    // the consumer writes are the link name (`tower_service`); the Cargo.toml dependency key is the
    // package name (`tower-service`).  Conflating them is how a chained probe silently becomes an
    // unchained one — ⟨0.39⟩ conjunct 1 is "a REAL Cargo.toml dependency".
    let ctoml = lib.join("Cargo.toml");
    let raw = std::fs::read_to_string(&ctoml).unwrap_or_default();
    // A swallowed Cargo.toml parse error would report every crate as NO-PACKAGE, which reads like a
    // property of the corpus rather than a broken generator.  Say which it is.
    let doc: toml::Table = match toml::from_str(&raw) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("CARGO-TOML-UNPARSED {}: {e}", ctoml.display());
            std::process::exit(3);
        }
    };
    let pkg_name = doc
        .get("package")
        .and_then(|p| p.get("name"))
        .and_then(|n| n.as_str())
        .unwrap_or("")
        .to_string();
    if pkg_name.is_empty() {
        eprintln!("NO-PACKAGE {}", lib.display());
        std::process::exit(3);
    }
    let link = doc
        .get("lib")
        .and_then(|l| l.get("name"))
        .and_then(|n| n.as_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| pkg_name.replace('-', "_"));
    let root = doc
        .get("lib")
        .and_then(|l| l.get("path"))
        .and_then(|n| n.as_str())
        .map(|s| lib.join(s))
        .unwrap_or_else(|| lib.join("src/lib.rs"));
    if !root.is_file() {
        // A bin-only crate has no library surface for a consumer to name.  This is a property of the
        // crate, not a failure of the run, and it is reported so the entry can be excluded BY NAME
        // rather than carried into the A/B with an empty consumer (R242: an entry that contributes
        // zero rows prints exactly like a correctly-inert change).
        eprintln!("NO-LIB-TARGET {} (no {})", pkg_name, root.display());
        std::process::exit(3);
    }

    let src = std::fs::read_to_string(&root).unwrap_or_default();
    let ast = match syn::parse_file(&src) {
        Ok(x) => x,
        Err(e) => {
            eprintln!("PARSE-FAIL {pkg_name}: {e}");
            std::process::exit(3);
        }
    };
    let mut c = Coll::default();
    walk(&ast.items, root.parent().unwrap_or(&lib), &[], &mut c, 0);

    // ── build the probe list ──────────────────────────────────────────────────────────────────────
    let mut probes: Vec<Probe> = vec![];
    let mut impl_bodies: Vec<String> = vec![];
    let mut k = 0usize;
    let modname = |m: &[String]| -> Vec<String> {
        if m.is_empty() { vec!["root".to_string()] } else { m.to_vec() }
    };
    for t in &c.traits {
        let full = {
            let mut s = link.clone();
            for seg in &t.mod_path {
                s.push_str("::");
                s.push_str(seg);
            }
            s.push_str("::");
            s.push_str(&t.name);
            s
        };
        if variant == "impl" {
            // The implementor lives in ONE top-level module of its own, never beside the probes: an
            // effectful body in a probe's own module would put the effect in that module on BOTH arms,
            // and a probe gaining it in POST would then add no NEW (module, effect) pair.  Module scope
            // is the rung this measurement exists to answer (R664 measured zero there), so planting the
            // effect there would manufacture the result.
            let j = impl_bodies.len();
            let mut b = format!("pub struct Imp{j};\nimpl {full} for Imp{j} {{\n");
            for (m, n) in &t.methods {
                b.push_str(&format!("    fn {m}(&self{}) {{ {SINK} }}\n", args_sig(*n)));
            }
            b.push_str("}\n");
            impl_bodies.push(b);
        }
        for (m, n) in &t.methods {
            let cm = modname(&t.mod_path);
            let tgt = format!("{full}::{m}");
            probes.push(Probe {
                m: cm.clone(),
                name: format!("p{k}_dyn"),
                body: format!("pub fn p{k}_dyn(r: &dyn {full}{}) {{ r.{m}({}); }}", args_sig(*n), args_call(*n)),
                shape: "dyn",
                target: tgt.clone(),
            });
            k += 1;
            probes.push(Probe {
                m: cm.clone(),
                name: format!("p{k}_gen"),
                body: format!("pub fn p{k}_gen<T: {full}>(r: &T{}) {{ r.{m}({}); }}", args_sig(*n), args_call(*n)),
                shape: "gen",
                target: tgt.clone(),
            });
            k += 1;
            probes.push(Probe {
                m: cm.clone(),
                name: format!("p{k}_let"),
                body: format!(
                    "pub fn p{k}_let(b: Box<dyn {full}>{}) {{ let r = &*b; r.{m}({}); }}",
                    args_sig(*n),
                    args_call(*n)
                ),
                shape: "let",
                target: tgt.clone(),
            });
            k += 1;
            probes.push(Probe {
                m: cm,
                name: format!("p{k}_fnref"),
                body: format!(
                    "pub fn p{k}_fnref(r: &dyn {full}{}) {{ let f = {full}::{m}; f(r{}); }}",
                    args_sig(*n),
                    args_call_after(*n)
                ),
                shape: "fnref",
                target: tgt,
            });
            k += 1;
        }
    }
    for f in &c.fns {
        let mut s = link.clone();
        for seg in &f.mod_path {
            s.push_str("::");
            s.push_str(seg);
        }
        s.push_str("::");
        s.push_str(&f.name);
        probes.push(Probe {
            m: modname(&f.mod_path),
            name: format!("p{k}_call"),
            body: format!("pub fn p{k}_call({}) {{ {s}({}); }}", args_sig(f.arity).trim_start_matches(", "), args_call(f.arity)),
            shape: "call",
            target: s,
        });
        k += 1;
    }
    for i in &c.inh {
        if variant == "impl" {
            // A concrete inherent receiver is decided without any implementor union, so it measures
            // the same thing in both variants; emitted once, in `noimpl`.
            break;
        }
        let mut base = link.clone();
        for seg in &i.mod_path {
            base.push_str("::");
            base.push_str(seg);
        }
        base.push_str("::");
        base.push_str(&i.ty);
        let tgt = format!("{base}::{}", i.name);
        if i.has_self {
            probes.push(Probe {
                m: modname(&i.mod_path),
                name: format!("p{k}_inh"),
                body: format!(
                    "pub fn p{k}_inh(x: &{base}{}) {{ x.{}({}); }}",
                    args_sig(i.arity),
                    i.name,
                    args_call(i.arity)
                ),
                shape: "inh",
                target: tgt,
            });
        } else {
            probes.push(Probe {
                m: modname(&i.mod_path),
                name: format!("p{k}_assoc"),
                body: format!(
                    "pub fn p{k}_assoc({}) {{ {base}::{}({}); }}",
                    args_sig(i.arity).trim_start_matches(", "),
                    i.name,
                    args_call(i.arity)
                ),
                shape: "assoc",
                target: tgt,
            });
        }
        k += 1;
    }

    let total_before_cap = probes.len();
    let mut capped = false;
    if cap > 0 && probes.len() > cap {
        // A cap is a DENOMINATOR change, so it is recorded and it is deterministic: a stride, not a
        // prefix, so the sample is not all one module.
        let stride = (probes.len() + cap - 1) / cap;
        probes = probes.into_iter().step_by(stride).collect();
        capped = true;
    }
    if probes.is_empty() {
        eprintln!("NO-PROBES {pkg_name} (no public trait with a self-taking method, no public fn, no public inherent method)");
        std::process::exit(3);
    }

    // ── emit the consumer crate ───────────────────────────────────────────────────────────────────
    let _ = std::fs::remove_dir_all(&out);
    std::fs::create_dir_all(out.join("src")).expect("mkdir consumer src");
    // Group by consumer module path.
    let mut by_mod: BTreeMap<Vec<String>, Vec<&Probe>> = BTreeMap::new();
    for p in &probes {
        by_mod.entry(p.m.clone()).or_default().push(p);
    }
    // A module tree: emit every module inline in one file per TOP-LEVEL module, nesting the rest, so
    // the consumer qual is `<top>::<...>::p<K>_<shape>` and no file-layout question arises.
    let mut tops: BTreeMap<String, BTreeMap<Vec<String>, Vec<&Probe>>> = BTreeMap::new();
    for (m, ps) in &by_mod {
        tops.entry(m[0].clone()).or_default().insert(m.clone(), ps.clone());
    }
    let mut lib_rs = format!(
        "// GENERATED by bin/corpus-chained/consumer-gen-rs from the public API of `{pkg_name}`.\n\
         // One call per probe body; arguments are the probe's own parameters, never constructed.\n"
    );
    for top in tops.keys() {
        lib_rs.push_str(&format!("pub mod {top};\n"));
    }
    if !impl_bodies.is_empty() {
        lib_rs.push_str("pub mod candor_impls;\n");
        std::fs::write(out.join("src/candor_impls.rs"), impl_bodies.join("\n")).expect("write impls");
    }
    std::fs::write(out.join("src/lib.rs"), lib_rs).expect("write lib.rs");
    for (top, group) in &tops {
        // One file per TOP-LEVEL consumer module, the rest nested inline.  Emitted as a real tree —
        // a flat sequence of `pub mod a { .. }` blocks would repeat `a` once per leaf and give the
        // parser two bodies for one module.
        let mut s = String::new();
        emit_tree(&mut s, group, &[top.clone()], 0);
        std::fs::write(out.join(format!("src/{top}.rs")), s).expect("write module");
    }
    std::fs::write(
        out.join("Cargo.toml"),
        format!(
            "[package]\nname = \"cc-{}\"\nversion = \"0.0.0\"\nedition = \"2021\"\n\n[lib]\nname = \"cc_{}\"\npath = \"src/lib.rs\"\n\n[dependencies]\n{} = \"*\"\n",
            link.replace('_', "-"),
            link,
            pkg_name
        ),
    )
    .expect("write consumer Cargo.toml");

    // ── the manifest: every probe's consumer qual, so the judge can account for ABSENT rows ───────
    let mut quals = String::new();
    for (i, p) in probes.iter().enumerate() {
        let qual = format!("{}::{}", p.m.join("::"), p.name);
        if i > 0 {
            quals.push(',');
        }
        quals.push_str(&format!(
            "\n  {}: {{\"shape\": {}, \"target\": {}}}",
            json_str(&qual),
            json_str(p.shape),
            json_str(&p.target)
        ));
    }
    let mut skips = String::new();
    for (i, (kk, v)) in c.skips.iter().enumerate() {
        if i > 0 {
            skips.push(',');
        }
        skips.push_str(&format!("\n  {}: {v}", json_str(kk)));
    }
    let shapes = {
        let mut m: BTreeMap<&str, usize> = BTreeMap::new();
        for p in &probes {
            *m.entry(p.shape).or_insert(0) += 1;
        }
        m.iter()
            .enumerate()
            .map(|(i, (k, v))| format!("{}{}: {v}", if i > 0 { "," } else { "" }, json_str(k)))
            .collect::<String>()
    };
    std::fs::write(
        &manifest,
        format!(
            "{{\n \"variant\": {}, \"implementors\": {}, \"package\": {}, \"link\": {}, \"probe_types\": {}, \"public_traits\": {}, \
             \"public_fns\": {}, \"public_inherent\": {}, \"probes\": {}, \"probes_before_cap\": {}, \
             \"capped\": {}, \"consumer_modules\": {}, \"shapes\": {{{}}},\n \"skips\": {{{}\n }},\n \"quals\": {{{}\n }}\n}}\n",
            json_str(&variant),
            impl_bodies.len(),
            json_str(&pkg_name),
            json_str(&link),
            c.traits.len() + c.fns.len() + c.inh.len(),
            c.traits.len(),
            c.fns.len(),
            c.inh.len(),
            probes.len(),
            total_before_cap,
            capped,
            by_mod.len(),
            shapes,
            skips,
            quals
        ),
    )
    .expect("write manifest");
    println!(
        "OK {pkg_name} link={link} probes={} (of {}) modules={} traits={} fns={} inherent={}",
        probes.len(),
        total_before_cap,
        by_mod.len(),
        c.traits.len(),
        c.fns.len(),
        c.inh.len()
    );
}

/// Render the probes of `group` whose module path starts with `prefix`, nesting deeper paths.
fn emit_tree(s: &mut String, group: &BTreeMap<Vec<String>, Vec<&Probe>>, prefix: &[String], depth: usize) {
    let ind = "    ".repeat(depth);
    if let Some(ps) = group.get(prefix) {
        for p in ps {
            s.push_str(&format!("{ind}{}\n", p.body));
        }
    }
    let mut kids: Vec<String> = vec![];
    for m in group.keys() {
        if m.len() > prefix.len() && m[..prefix.len()] == *prefix {
            let seg = m[prefix.len()].clone();
            if !kids.contains(&seg) {
                kids.push(seg);
            }
        }
    }
    for kid in kids {
        s.push_str(&format!("{ind}pub mod {kid} {{\n"));
        let mut sub = prefix.to_vec();
        sub.push(kid);
        emit_tree(s, group, &sub, depth + 1);
        s.push_str(&format!("{ind}}}\n"));
    }
}

fn json_str(s: &str) -> String {
    let mut o = String::from("\"");
    for ch in s.chars() {
        match ch {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}
