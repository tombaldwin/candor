//! ra-shadow-arm: the rust-analyzer SHADOW arm for bin/rust-ra-shadow.py (Phase 0 of the rust typer strategy; Fable
//! review 2026-11-28). It changes no candor report. It loads a cargo project with rust-analyzer's library crates
//! (ra_ap_* 0.0.358, pinned, built with ra_ap_load-cargo's own Cargo.lock: the only lock that built) on stable, WITHOUT
//! building it: `load_out_dirs_from_check: false` and `ProcMacroServerChoice::None` are fixed here and are not options,
//! because both would execute code from the scanned tree. For every call site in the LOCAL crates (including inside
//! expanded macro_rules!/builtin macros) it records the callee ra names, with the generic substitution.
//!
//! Lives OUTSIDE candor-rust's workspace on purpose: 188 packages (27 ra_ap_*), MSRV 1.98 and weekly breaking 0.0.x
//! releases must not reach `cargo install candor-scan`'s lock or MSRV while this is an instrument.
//!
//!   ra-shadow-arm <project-dir> [--sites out.jsonl] [--impls impls.jsonl] [--offline] [--no-sysroot] [--test]
//!
//! --sites: one JSON line per decl ({decl, path, file, start, end, macro, self_src}) and per call site ({file, line,
//!   mline, form, macro, outcome, target, origin, text, caller, tid, subst}); a site inside a cfg-disabled item is
//!   `outcome: inactive`, caller `<inactive>` (v3 charged it to the previous fn: the e10/e11/e12/e2 fabrications).
//! --impls: every trait impl ({impl, self, cfg, cfg_ok, impl_in_macro, nitems, krate}), its methods and assoc types,
//!   and every trait's declared methods ({self: "<default>", has_body}); `trait` is ra's TraitId (identity, not name).
//! stdout: one JSON summary line, including `loaded` (every non-lang crate ra loaded: the no-deps detector's input).
//! RA_SHADOW_LEGACY_FALLBACK=1 restores the v3 attribution, for calibrating the detector only.
use std::{collections::HashSet, io::Write, path::Path, time::Instant};

use hir::{
    AsAssocItem, AssocItemContainer, CallableKind, HasAttrs, HasSource, HirDisplay, ModuleDef, ModuleSource,
    PathResolution, Semantics,
};
use ide_db::RootDatabase;
use load_cargo::{LoadCargoConfig, ProcMacroServerChoice, load_workspace_at};
use project_model::{CargoConfig, RustLibSource};
use syntax::{AstNode, SyntaxNode, ast};

extern crate ra_ap_hir as hir;
extern crate ra_ap_ide_db as ide_db;
extern crate ra_ap_load_cargo as load_cargo;
extern crate ra_ap_project_model as project_model;
extern crate ra_ap_syntax as syntax;
extern crate ra_ap_vfs;

#[derive(Default, Debug)]
struct Tally {
    sites: u64,
    method: u64,
    call: u64,
    in_macro: u64,
    free: u64,
    inherent: u64,
    trait_impl: u64, // devirtualised to a concrete impl method
    trait_decl: u64, // resolved only to the trait's declaration (generic / dyn / no impl selected)
    ctor: u64,       // tuple struct / variant constructor
    closure: u64,
    fnptr: u64,
    fn_trait: u64, // call through an Fn* bound
    unresolved: u64,
    inactive: u64, // in an item rust-analyzer evaluates as cfg-disabled (no def): NOT analysed at all
    unresolved_method: u64,
    unresolved_path: u64,
    target_local: u64,
    target_dep: u64,
    target_lang: u64,
    macros: u64,
    macro_unexpanded: u64,
    macro_depth_cut: u64,
    ops: u64, // operator / await / ? resolved to a user-visible fn (extra edges, not counted in sites)
}

struct Ctx<'a> {
    sema: &'a Semantics<'a, RootDatabase>,
    db: &'a RootDatabase,
    t: Tally,
    out: Option<std::fs::File>,
    file: String,
    text: String,
    cur_fn: String,
    fallback: String,
    mline: usize,
    legacy: bool,
    cur_file: Option<ra_ap_vfs::FileId>,
}

fn origin_of(db: &RootDatabase, k: hir::Crate) -> &'static str {
    let origin = k.origin(db);
    if origin.is_local() {
        "local"
    } else if origin.is_lang() {
        "lang"
    } else {
        "dep"
    }
}

fn fn_path(db: &RootDatabase, f: hir::Function) -> (String, &'static str, &'static str) {
    let m = f.module(db);
    let krate = m.krate(db);
    let dt = krate.to_display_target(db);
    let o = origin_of(db, krate);
    let mut segs: Vec<String> =
        vec![krate.display_name(db).map(|n| n.to_string()).unwrap_or_else(|| "?".into())];
    let mut mods = m.path_to_root(db);
    mods.reverse();
    for md in mods.iter() {
        if let Some(n) = md.name(db) {
            segs.push(n.as_str().to_string());
        }
    }
    let name = f.name(db).as_str().to_string();
    let kind = match f.as_assoc_item(db).map(|a| a.container(db)) {
        Some(AssocItemContainer::Trait(t)) => {
            segs.push(format!("<dyn {}>", t.name(db).as_str()));
            "trait_decl"
        }
        Some(AssocItemContainer::Impl(i)) => {
            let st = i.self_ty(db).display(db, dt).to_string();
            match i.trait_(db) {
                Some(tr) => {
                    segs.push(format!("<{} as {}>", st, tr.name(db).as_str()));
                    "trait_impl"
                }
                None => {
                    segs.push(format!("<{}>", st));
                    "inherent"
                }
            }
        }
        None => "free",
    };
    segs.push(name);
    (segs.join("::"), kind, o)
}

fn fid(f: hir::Function) -> String {
    format!("{:?}", f)
}

impl<'a> Ctx<'a> {
    /// The unit a site belongs to. The nearest enclosing `fn` decides: with a def it is the caller; WITHOUT one it is a
    /// cfg-disabled item and the site is `<inactive>` (never charged to anyone). No enclosing `fn` in this tree (a
    /// macro expansion, or a const/static initialiser) -> the fallback, which is the enclosing fn of the MACRO CALL
    /// (set by `walk` on entering an expansion) or "" at file level. v3 fell back to "the last fn the walk passed",
    /// which charged an item-position macro's cfg-disabled impl to the preceding fn (the e10/e11/e12/e2 fabrications).
    fn caller_of(&self, node: &SyntaxNode) -> String {
        if self.legacy {
            for a in node.ancestors() {
                if let Some(f) = ast::Fn::cast(a.clone()) {
                    if let Some(d) = self.sema.to_fn_def(&f) { return fid(d); }
                }
            }
            return self.cur_fn.clone();
        }
        for a in node.ancestors() {
            if let Some(f) = ast::Fn::cast(a.clone()) {
                return match self.sema.to_fn_def(&f) { Some(d) => fid(d), None => "<inactive>".into() };
            }
        }
        self.fallback.clone()
    }

    #[allow(clippy::too_many_arguments)]
    fn emit(&mut self, node: &SyntaxNode, form: &str, in_macro: bool, outcome: &str, target: &str, origin: &str,
            tid: &str, subst: serde_json::Value) {
        if self.out.is_none() {
            return;
        }
        let caller = self.caller_of(node);
        let r = self.sema.original_range(node);
        let off: usize = r.range.start().into();
        // `line` is meaningful only when the upmapped range is in THIS file (a token from another file's macro_rules!
        // body upmaps there); `rf` says which. `mline` is the outermost macro call's line in this file.
        let rf = Some(r.file_id.file_id(self.db)) == self.cur_file;
        let line = if rf { self.text[..off.min(self.text.len())].bytes().filter(|b| *b == b'\n').count() + 1 } else { 0 };
        let txt: String = node.text().to_string().chars().take(80).collect();
        let v = serde_json::json!({"file": self.file, "line": line, "form": form, "macro": in_macro,
            "outcome": outcome, "target": target, "origin": origin, "text": txt,
            "caller": caller, "tid": tid, "subst": subst, "mline": if in_macro { self.mline } else { 0 }});
        let _ = writeln!(self.out.as_mut().unwrap(), "{}", v);
    }

    fn record_fn(&mut self, node: &SyntaxNode, form: &str, in_macro: bool, f: hir::Function,
                 gs: Option<hir::GenericSubstitution<'a>>, count: bool) {
        let (p, kind, o) = fn_path(self.db, f);
        let dt = f.module(self.db).krate(self.db).to_display_target(self.db);
        let subst = match gs {
            Some(g) => serde_json::Value::Array(
                g.types(self.db)
                    .into_iter()
                    .map(|(n, t)| {
                        let s = t.strip_references();
                        let tp = s.as_type_param(self.db).map(|p| p.name(self.db).as_str().to_string());
                        serde_json::json!([n.as_str(), s.display(self.db, dt).to_string(), tp])
                    })
                    .collect(),
            ),
            None => serde_json::Value::Null,
        };
        if count {
            match kind {
                "free" => self.t.free += 1,
                "inherent" => self.t.inherent += 1,
                "trait_impl" => self.t.trait_impl += 1,
                _ => self.t.trait_decl += 1,
            }
            match o {
                "local" => self.t.target_local += 1,
                "lang" => self.t.target_lang += 1,
                _ => self.t.target_dep += 1,
            }
        } else {
            self.t.ops += 1;
        }
        self.emit(node, form, in_macro, kind, &p, o, &fid(f), subst);
    }

    fn inactive(&self, node: &SyntaxNode) -> bool {
        for a in node.ancestors() {
            if let Some(f) = ast::Fn::cast(a.clone()) {
                return self.sema.to_fn_def(&f).is_none();
            }
        }
        false
    }

    fn miss(&mut self, node: &SyntaxNode, form: &str, in_macro: bool, method: bool) {
        if !in_macro && self.inactive(node) {
            self.t.inactive += 1;
            self.emit(node, form, in_macro, "inactive", "", "", "", serde_json::Value::Null);
            return;
        }
        self.t.unresolved += 1;
        if method { self.t.unresolved_method += 1 } else { self.t.unresolved_path += 1 }
        self.emit(node, form, in_macro, "unresolved", "", "", "", serde_json::Value::Null);
    }

    fn walk(&mut self, root: &SyntaxNode, in_macro: bool, depth: u32) {
        for node in root.descendants() {
            if let Some(f) = ast::Fn::cast(node.clone()) {
                if let Some(d) = self.sema.to_fn_def(&f) {
                    if !in_macro {
                        self.cur_fn = fid(d);
                    }
                    if let Some(o) = self.out.as_mut() {
                        let (a, b) = if in_macro { (0, 0) } else {
                            let rg = node.text_range();
                            let ln = |x: usize| self.text[..x.min(self.text.len())].bytes().filter(|c| *c == b'\n').count() + 1;
                            (ln(rg.start().into()), ln(rg.end().into()))
                        };
                        // the impl's self type AS WRITTEN (candor keys from source syntax: `NonZeroI16`, not ra's
                        // canonical `NonZero<i16>`; a tuple or `&T` self type has no type segment there)
                        let self_src = node.ancestors().skip(1).find_map(ast::Impl::cast)
                            .and_then(|i| i.self_ty()).map(|t| t.syntax().text().to_string());
                        let _ = writeln!(o, "{}", serde_json::json!({"decl": fid(d), "path": fn_path(self.db, d).0, "macro": in_macro,
                            "file": self.file, "start": a, "end": b, "self_src": self_src}));
                    }
                }
            }
            let callish = ast::MethodCallExpr::can_cast(node.kind()) || ast::CallExpr::can_cast(node.kind());
            let opish = ast::BinExpr::can_cast(node.kind()) || ast::AwaitExpr::can_cast(node.kind())
                || ast::TryExpr::can_cast(node.kind()) || ast::IndexExpr::can_cast(node.kind())
                || ast::MacroCall::can_cast(node.kind());
            if !self.legacy && (callish || opish) && self.caller_of(&node) == "<inactive>" {
                if callish {
                    self.t.sites += 1;
                    self.t.inactive += 1;
                    self.emit(&node, "call", in_macro, "inactive", "", "", "", serde_json::Value::Null);
                }
                continue;
            }
            if let Some(mc) = ast::MethodCallExpr::cast(node.clone()) {
                self.t.sites += 1;
                self.t.method += 1;
                if in_macro {
                    self.t.in_macro += 1;
                }
                match self.sema.resolve_method_call_fallback(&mc) {
                    Some((either::Either::Left(f), gs)) => self.record_fn(&node, "method", in_macro, f, gs, true),
                    _ => self.miss(&node, "method", in_macro, true),
                }
            } else if let Some(ce) = ast::CallExpr::cast(node.clone()) {
                self.t.sites += 1;
                self.t.call += 1;
                if in_macro {
                    self.t.in_macro += 1;
                }
                let Some(callee) = ce.expr() else { continue };
                let mut done = false;
                if let ast::Expr::PathExpr(pe) = &callee {
                    if let Some(path) = pe.path() {
                        match self.sema.resolve_path_with_subst(&path) {
                            Some((PathResolution::Def(ModuleDef::Function(f)), gs)) => {
                                self.record_fn(&node, "path", in_macro, f, gs, true);
                                done = true;
                            }
                            Some((PathResolution::Def(ModuleDef::Adt(_)), _))
                            | Some((PathResolution::Def(ModuleDef::EnumVariant(_)), _)) => {
                                self.t.ctor += 1;
                                self.emit(&node, "path", in_macro, "ctor", "", "", "", serde_json::Value::Null);
                                done = true;
                            }
                            _ => {}
                        }
                    }
                }
                if !done {
                    let k = self.sema.resolve_expr_as_callable(&callee).map(|c| c.kind());
                    let n = serde_json::Value::Null;
                    match k {
                        Some(CallableKind::Function(f)) => self.record_fn(&node, "call", in_macro, f, None, true),
                        Some(CallableKind::TupleStruct(_)) | Some(CallableKind::TupleEnumVariant(_)) => {
                            self.t.ctor += 1;
                            self.emit(&node, "call", in_macro, "ctor", "", "", "", n);
                        }
                        Some(CallableKind::Closure(_)) => {
                            self.t.closure += 1;
                            self.emit(&node, "call", in_macro, "closure", "", "", "", n);
                        }
                        Some(CallableKind::FnPtr) => {
                            self.t.fnptr += 1;
                            self.emit(&node, "call", in_macro, "fnptr", "", "", "", n);
                        }
                        Some(CallableKind::FnImpl(_)) => {
                            self.t.fn_trait += 1;
                            self.emit(&node, "call", in_macro, "fn_trait", "", "", "", n);
                        }
                        None => self.miss(&node, "call", in_macro, false),
                    }
                }
            } else if let Some(be) = ast::BinExpr::cast(node.clone()) {
                if let Some(f) = self.sema.resolve_bin_expr(&be) {
                    self.record_fn(&node, "op", in_macro, f, None, false);
                }
            } else if let Some(ae) = ast::AwaitExpr::cast(node.clone()) {
                if let Some(f) = self.sema.resolve_await_to_poll(&ae) {
                    self.record_fn(&node, "await", in_macro, f, None, false);
                }
            } else if let Some(te) = ast::TryExpr::cast(node.clone()) {
                if let Some(f) = self.sema.resolve_try_expr(&te) {
                    self.record_fn(&node, "try", in_macro, f, None, false);
                }
            } else if let Some(ie) = ast::IndexExpr::cast(node.clone()) {
                if let Some(f) = self.sema.resolve_index_expr(&ie) {
                    self.record_fn(&node, "index", in_macro, f, None, false);
                }
            } else if let Some(mac) = ast::MacroCall::cast(node.clone()) {
                self.t.macros += 1;
                if depth < 32 {
                    if let Some(exp) = self.sema.expand_macro_call(&mac) {
                        let enc = self.caller_of(&node);
                        let saved = std::mem::replace(&mut self.fallback, enc);
                        let saved_m = self.mline;
                        if depth == 0 {
                            let off: usize = node.text_range().start().into();
                            self.mline = self.text[..off.min(self.text.len())].bytes().filter(|c| *c == b'\n').count() + 1;
                        }
                        self.walk(&exp.value, true, depth + 1);
                        self.fallback = saved;
                        self.mline = saved_m;
                    } else {
                        // the disclosure channel: ra KNOWS it could not expand this call
                        self.t.macro_unexpanded += 1;
                        self.emit(&node, "macro", in_macro, "unexpanded", "", "", "", serde_json::Value::Null);
                    }
                } else {
                    self.t.macro_depth_cut += 1;
                    self.emit(&node, "macro", in_macro, "unexpanded", "", "", "", serde_json::Value::Null);
                }
            }
        }
    }
}

fn dump_impls(db: &RootDatabase, out: &mut std::fs::File) {
    for krate in hir::Crate::all(db) {
        let dt = krate.to_display_target(db);
        for imp in hir::Impl::all_in_crate(db, krate) {
            let Some(tr) = imp.trait_(db) else { continue };
            let st = imp.self_ty(db).display(db, dt).to_string();
            // cfg trace (FABLE-REVIEW change 6): does a cfg-disabled impl reach the index? record the impl's own cfg
            // predicate, whether this host's crate cfg satisfies it, and whether the impl came from a macro expansion.
            let cfgx = imp.attrs(db).cfgs(db).cloned();
            let cfg_s = cfgx.as_ref().map(|c| c.to_string());
            let cfg_ok = cfgx.as_ref().and_then(|c| krate.cfg(db).check(c));
            let in_mac = imp.source(db).map(|s| s.file_id.is_macro()).unwrap_or(false);
            let _ = writeln!(out, "{}", serde_json::json!({"impl": tr.name(db).as_str(), "self": st, "cfg": cfg_s,
                "cfg_ok": cfg_ok, "impl_in_macro": in_mac, "nitems": imp.items(db).len(),
                "krate": krate.display_name(db).map(|n| n.to_string()).unwrap_or_default()}));
            for it in imp.items(db) {
                if let hir::AssocItem::TypeAlias(ta) = it {
                    let _ = writeln!(out, "{}", serde_json::json!({"assoc": ta.name(db).as_str(), "tname": tr.name(db).as_str(),
                        "self": st, "ty": ta.ty(db).display(db, dt).to_string(), "cfg": cfg_s, "cfg_ok": cfg_ok,
                        "impl_in_macro": in_mac}));
                }
                if let hir::AssocItem::Function(f) = it {
                    let _ = writeln!(out, "{}", serde_json::json!({"trait": format!("{:?}", tr), "tname": tr.name(db).as_str(),
                        "self": st, "method": f.name(db).as_str(), "fn": fid(f), "path": fn_path(db, f).0,
                        "cfg": cfg_s, "cfg_ok": cfg_ok, "impl_in_macro": in_mac}));
                }
            }
        }
        for m in krate.modules(db) {
            for d in m.declarations(db) {
                if let ModuleDef::Trait(tr) = d {
                    for it in tr.items(db) {
                        if let hir::AssocItem::Function(f) = it {
                            let _ = writeln!(out, "{}", serde_json::json!({"trait": format!("{:?}", tr), "tname": tr.name(db).as_str(),
                                "self": "<default>", "method": f.name(db).as_str(), "fn": fid(f), "path": fn_path(db, f).0,
                                "has_body": f.has_body(db)}));
                        }
                    }
                }
            }
        }
    }
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let dir = Path::new(&args[1]);
    let opt = |k: &str| args.iter().position(|a| a == k).map(|i| args[i + 1].clone());
    let offline = args.iter().any(|a| a == "--offline");
    let no_sysroot = args.iter().any(|a| a == "--no-sysroot");
    let all_crates = args.iter().any(|a| a == "--all-crates");
    let t0 = Instant::now();
    let mut cfg = CargoConfig {
        sysroot: if no_sysroot { None } else { Some(RustLibSource::Discover) },
        all_targets: true,
        set_test: args.iter().any(|a| a == "--test"),
        ..Default::default()
    };
    if offline {
        cfg.extra_env.insert("CARGO_NET_OFFLINE".into(), Some("true".into()));
    }
    let load = LoadCargoConfig {
        load_out_dirs_from_check: false,
        with_proc_macro_server: ProcMacroServerChoice::None,
        prefill_caches: false,
        num_worker_threads: 1,
        proc_macro_processes: 0,
    };
    let (db, vfs, _pm) = load_workspace_at(dir, &cfg, &load, &|_| {})?;
    let t_load = t0.elapsed().as_secs_f64();
    hir::attach_db(&db, || -> anyhow::Result<()> {
    let sema = Semantics::new(&db);
    let mut ctx = Ctx {
        sema: &sema,
        db: &db,
        t: Tally::default(),
        out: opt("--sites").map(|p| std::fs::File::create(p).unwrap()),
        file: String::new(),
        text: String::new(),
        cur_fn: String::new(),
        fallback: String::new(),
        mline: 0,
        // calibration seed ONLY: RA_SHADOW_LEGACY_FALLBACK=1 restores v3's "last fn the walk passed" attribution so
        // the shadow tool's misattribution detector can be shown to fire (rust-ra-shadow.py --selftest / D2).
        legacy: std::env::var("RA_SHADOW_LEGACY_FALLBACK").is_ok(),
        cur_file: None,
    };
    let mut seen = HashSet::new();
    let mut nfiles = 0;
    let mut ncrates = 0;
    for krate in hir::Crate::all(&db) {
        let o = origin_of(&db, krate);
        if !(o == "local" || (all_crates && o == "dep")) {
            continue;
        }
        ncrates += 1;
        for m in krate.modules(&db) {
            let src = m.definition_source(&db);
            if !matches!(src.value, ModuleSource::SourceFile(_)) {
                continue;
            }
            let fid_ = src.file_id;
            if !seen.insert(fid_) {
                continue;
            }
            nfiles += 1;
            let root = sema.parse_or_expand(fid_);
            ctx.file = fid_.file_id().map(|e| vfs.file_path(e.file_id(&db)).to_string()).unwrap_or_default();
            ctx.text = root.text().to_string();
            ctx.cur_fn.clear();
            ctx.fallback.clear();
            ctx.cur_file = fid_.file_id().map(|e| e.file_id(&db));
            ctx.walk(&root, false, 0);
        }
    }
    if let Some(p) = opt("--impls") {
        let mut f = std::fs::File::create(p)?;
        dump_impls(&db, &mut f);
    }
    let t_all = t0.elapsed().as_secs_f64();
    // the no-deps detector's input (FABLE-REVIEW §3): every non-lang crate ra LOADED, so a driver can compare it with
    // `cargo metadata`'s resolve. ra's own fallback when metadata fails is to load the workspace WITHOUT deps, silently.
    let mut loaded: Vec<serde_json::Value> = Vec::new();
    for krate in hir::Crate::all(&db) {
        let o = origin_of(&db, krate);
        if o == "lang" { continue; }
        loaded.push(serde_json::json!([krate.display_name(&db).map(|n| n.to_string()).unwrap_or_default(), o,
            krate.version(&db).unwrap_or_default()]));
    }
    let t = &ctx.t;
    let definite = t.free + t.inherent + t.trait_impl;
    let callsites = t.sites - t.ctor - t.inactive;
    let v = serde_json::json!({
        "dir": args[1], "crates": ncrates, "loaded": loaded, "ra_ap": "0.0.358", "files": nfiles, "load_s": t_load, "total_s": t_all,
        "sites": t.sites, "method": t.method, "call": t.call, "in_macro": t.in_macro,
        "free": t.free, "inherent": t.inherent, "trait_impl": t.trait_impl, "trait_decl": t.trait_decl,
        "ctor": t.ctor, "macros": t.macros, "macro_unexpanded": t.macro_unexpanded, "macro_depth_cut": t.macro_depth_cut, "closure": t.closure, "fnptr": t.fnptr, "fn_trait": t.fn_trait, "ops": t.ops,
        "unresolved": t.unresolved, "inactive": t.inactive, "unresolved_method": t.unresolved_method, "unresolved_path": t.unresolved_path,
        "target_local": t.target_local, "target_dep": t.target_dep, "target_lang": t.target_lang,
        "definite_share": if callsites > 0 { definite as f64 / callsites as f64 } else { 0.0 },
        "resolved_share": if callsites > 0 { (callsites - t.unresolved) as f64 / callsites as f64 } else { 0.0 },
    });
    println!("{}", v);
    Ok(())
    })
}
