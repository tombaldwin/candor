//! candor-classify-paths: one `<crate>\t<path>` per stdin line -> `<crate>\t<path>\t<effects|->` on stdout, from
//! the published candor-classify (classify_all). The ra shadow tool's sink oracle.
use std::io::{BufRead, Write};
fn main() {
    let out = std::io::stdout();
    let mut o = out.lock();
    for l in std::io::stdin().lock().lines() {
        let l = l.unwrap();
        let (k, p) = l.split_once('\t').unwrap_or(("std", l.as_str()));
        let e = candor_classify::classify_all(k, p).map(|v| v.join("+")).unwrap_or_else(|| "-".into());
        writeln!(o, "{}\t{}\t{}", k, p, e).unwrap();
    }
}
