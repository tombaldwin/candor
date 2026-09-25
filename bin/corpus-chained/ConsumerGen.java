// ConsumerGen.java — generate a CONSUMER from a library's public API.  SOUNDNESS R668/R671.
//
// WHY THIS EXISTS.  `bin/AGENT-CORPUS-BRIEF.md` §2 says to scan a library AS A DEPENDENCY OF A
// CONSUMER, not standalone; the java and rust censuses (R665/R662) scan standalone, so they are
// structurally blind to the whole <0.39> chained-dispatch rung.  R595 is the proof: adding a pure
// default to a library deleted a real `Fs` from every CONSUMER — a defect that cannot exist in a
// standalone scan, because it needs a producer report joined by a consumer.
//
// At 452 artifacts a hand-written consumer is not an option, and obligation 3 is mechanical, so the
// consumer is GENERATED from the library's own public API in exactly the two shapes the rung is
// about:
//
//   DISPATCH probe  (the R608 / R530b shape)  — for every public interface or abstract class the
//                    library declares, a method that TAKES it and calls each declared member.  The
//                    consumer holds no implementor, so the only thing that can resolve the call is
//                    the `interfaceUnion` published in the library's own report and chained in via
//                    CANDOR_DEPS.  That join is <0.39> obligation 3.
//   FIELD probe     (the R595 shape)          — for every public static NON-FINAL field of
//                    functional-interface type, a REASSIGNMENT to an effectful implementor followed
//                    by a call into the library.  R595's defect is exactly here: the library's pure
//                    default wins and the consumer's effectful reassignment vanishes.
//
// It reads the jar by REFLECTION over a loader holding that jar (brief §G: ask the authority, never
// reimplement it — `Class#getCanonicalName` is the JDK's own binary->source name mapping, and
// `getParameterTypes` is its own erasure).  Anything it cannot resolve is COUNTED and named in the
// manifest rather than silently dropped: a consumer with no probes measures nothing and prints the
// same zero as a change that is correctly inert (R242).
import java.io.File;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Enumeration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;

public final class ConsumerGen {

    // The effect is INLINE rather than behind a helper: a helper would make every probe's row read
    // `Fs` through one shared callee, and a join defect one hop out would still look like a pass.
    static final String SINK =
        "try { new java.io.FileWriter(\"/tmp/candor-chained-sink\").close(); } "
        + "catch (java.lang.Throwable __x) { }";

    static final Map<String, Integer> SKIPS = new TreeMap<>();
    static void skip(String why) { SKIPS.merge(why, 1, Integer::sum); }

    public static void main(String[] argv) throws Exception {
        if (argv.length < 3) {
            System.err.println("usage: ConsumerGen <lib.jar> <out-src-dir> <manifest.json> [extra-classpath]");
            System.exit(2);
        }
        Path jar = Paths.get(argv[0]).toAbsolutePath();
        Path outSrc = Paths.get(argv[1]).toAbsolutePath();
        Path manifest = Paths.get(argv[2]).toAbsolutePath();
        String extraCp = argv.length > 3 ? argv[3] : "";

        List<URL> urls = new ArrayList<>();
        urls.add(jar.toUri().toURL());
        for (String p : extraCp.split(File.pathSeparator)) {
            if (!p.isEmpty()) urls.add(Paths.get(p).toUri().toURL());
        }
        URLClassLoader ld = new URLClassLoader(urls.toArray(new URL[0]),
                                               ClassLoader.getPlatformClassLoader());

        List<String> binNames = new ArrayList<>();
        try (JarFile jf = new JarFile(jar.toFile())) {
            for (Enumeration<JarEntry> e = jf.entries(); e.hasMoreElements(); ) {
                String n = e.nextElement().getName();
                if (!n.endsWith(".class")) continue;
                if (n.startsWith("META-INF/")) continue;                 // multi-release duplicates
                if (n.endsWith("module-info.class") || n.endsWith("package-info.class")) continue;
                binNames.add(n.substring(0, n.length() - 6).replace('/', '.'));
            }
        }
        Collections.sort(binNames);

        Files.createDirectories(outSrc);
        int types = 0, dispatchProbes = 0, fieldProbes = 0, callLines = 0, files = 0;
        // probe qual -> kind, so the judge can tell an ABSENT consumer row from a PURE one (R636).
        Map<String, String> quals = new LinkedHashMap<>();

        for (String bin : binNames) {
            // EVERY reflective step can throw, not just Class.forName: `isAnonymousClass` resolves
            // the ENCLOSING METHOD and netty-common blew up there on a transitive `reactor.blockhound`
            // type.  One unreadable class must cost one class, never the whole entry — an entry that
            // dies here contributes zero probes, and zero probes prints exactly like a safe change.
            try {
                int[] d = emitOne(bin, ld, outSrc, quals);
                if (d != null) { types++; files++; dispatchProbes += d[0]; fieldProbes += d[1]; callLines += d[2]; }
            } catch (Throwable t) {
                skip("reflection failure on the type (" + t.getClass().getSimpleName() + ")");
            }
        }

        StringBuilder mf = new StringBuilder();
        mf.append("{\n");
        mf.append("  \"jar\": ").append(jstr(jar.toString())).append(",\n");
        mf.append("  \"classes_in_jar\": ").append(binNames.size()).append(",\n");
        mf.append("  \"probe_types\": ").append(types).append(",\n");
        mf.append("  \"probe_files\": ").append(files).append(",\n");
        mf.append("  \"dispatch_probes\": ").append(dispatchProbes).append(",\n");
        mf.append("  \"field_probes\": ").append(fieldProbes).append(",\n");
        mf.append("  \"call_lines\": ").append(callLines).append(",\n");
        mf.append("  \"skips\": {");
        boolean first = true;
        for (Map.Entry<String, Integer> e : SKIPS.entrySet()) {
            if (!first) mf.append(",");
            mf.append("\n    ").append(jstr(e.getKey())).append(": ").append(e.getValue());
            first = false;
        }
        mf.append(first ? "}" : "\n  }").append(",\n");
        mf.append("  \"quals\": {");
        first = true;
        for (Map.Entry<String, String> e : quals.entrySet()) {
            if (!first) mf.append(",");
            mf.append("\n    ").append(jstr(e.getKey())).append(": ").append(jstr(e.getValue()));
            first = false;
        }
        mf.append(first ? "}" : "\n  }").append("\n}\n");
        Files.write(manifest, mf.toString().getBytes(StandardCharsets.UTF_8));
        System.out.println("ConsumerGen: " + jar.getFileName() + " -> " + files + " probe files, "
                           + dispatchProbes + " dispatch, " + fieldProbes + " field, "
                           + callLines + " call lines");
    }

    /** null when the type yields no probe; else {dispatchProbes, fieldProbes, callLines}. */
    static int[] emitOne(String bin, URLClassLoader ld, Path outSrc, Map<String, String> quals)
            throws Exception {
            Class<?> c;
            try { c = Class.forName(bin, false, ld); }
            catch (Throwable t) { skip("class not loadable (missing transitive dep or bad bytecode)"); return null; }
            if (c.isAnnotation() || c.isEnum() || c.isSynthetic()) { skip("annotation/enum/synthetic"); return null; }
            if (c.isAnonymousClass() || c.isLocalClass()) { skip("anonymous/local"); return null; }
            if (!publicChain(c)) { skip("not public (or a non-public enclosing type)"); return null; }
            String src = c.getCanonicalName();
            if (src == null) { skip("no canonical (source) name"); return null; }

            List<String> body = new ArrayList<>();
            int myDispatch = 0, myField = 0, myCalls = 0;

            // ── DISPATCH probes: R608 / R530b ────────────────────────────────────────────────────
            boolean abstractish = c.isInterface() || Modifier.isAbstract(c.getModifiers());
            if (abstractish) {
                Method[] ms = null;
                try { ms = c.getDeclaredMethods(); }
                catch (Throwable t) { skip("declared methods unreadable"); }
                if (ms != null) {
                    List<Method> sorted = new ArrayList<>();
                    for (Method m : ms) sorted.add(m);
                    sorted.sort((a, b) -> (a.getName() + a.toString()).compareTo(b.getName() + b.toString()));
                    List<String> calls = new ArrayList<>();
                    for (Method m : sorted) {
                        int mod = m.getModifiers();
                        if (!Modifier.isPublic(mod) || Modifier.isStatic(mod)) continue;
                        if (m.isSynthetic() || m.isBridge()) continue;
                        String call = renderCall("__x", m);
                        if (call == null) { skip("member signature not renderable"); continue; }
                        calls.add("        try { " + call + " } catch (java.lang.Throwable __t) { }");
                    }
                    if (!calls.isEmpty()) {
                        body.add("    public static void dispatch(" + src + " __x) {");
                        body.addAll(calls);
                        body.add("    }");
                        myDispatch = 1; myCalls = calls.size();
                    } else {
                        skip("abstract type with no renderable member");
                    }
                }
            }

            // ── FIELD probes: R595 ───────────────────────────────────────────────────────────────
            java.lang.reflect.Field[] fs = null;
            try { fs = c.getDeclaredFields(); }
            catch (Throwable t) { skip("declared fields unreadable"); }
            if (fs != null) {
                for (java.lang.reflect.Field f : fs) {
                    int mod = f.getModifiers();
                    if (!Modifier.isPublic(mod) || !Modifier.isStatic(mod) || Modifier.isFinal(mod)) continue;
                    if (f.isSynthetic()) continue;
                    Class<?> ft = f.getType();
                    Method sam = samOf(ft);
                    if (sam == null) continue;
                    String impl = renderImplementor(ft, sam);
                    if (impl == null) { skip("SAM not renderable"); continue; }
                    List<String> after = libraryCalls(c, src);
                    body.add("    public static void field_" + f.getName() + "() {");
                    body.add("        " + src + "." + f.getName() + " = " + impl + ";");
                    body.addAll(after);
                    body.add("    }");
                    quals.put(probePkg(c) + "." + probeClass(c, src) + ".field_" + f.getName(), "field");
                    myField++;
                    myCalls += after.size();
                }
            }

            if (body.isEmpty()) return null;
            String pkg = probePkg(c);
            String cls = probeClass(c, src);
            StringBuilder sb = new StringBuilder();
            sb.append("package ").append(pkg).append(";\n");
            sb.append("// generated consumer for ").append(src).append("\n");
            sb.append("public final class ").append(cls).append(" {\n");
            for (String ln : body) sb.append(ln).append("\n");
            sb.append("}\n");
            Path dir = outSrc.resolve(pkg.replace('.', '/'));
            Files.createDirectories(dir);
            Files.write(dir.resolve(cls + ".java"), sb.toString().getBytes(StandardCharsets.UTF_8));
            if (myDispatch > 0) quals.put(pkg + "." + cls + ".dispatch", "dispatch");

        return new int[] { myDispatch, myField, myCalls };
    }

    // ── rendering ────────────────────────────────────────────────────────────────────────────────

    static String probePkg(Class<?> c) {
        String p = c.getPackageName();
        return p.isEmpty() ? "candorgen" : "candorgen." + p;
    }

    static String probeClass(Class<?> c, String canonical) {
        String p = c.getPackageName();
        String tail = p.isEmpty() ? canonical : canonical.substring(p.length() + 1);
        return "C_" + tail.replace('.', '_');
    }

    static boolean publicChain(Class<?> t) {
        for (Class<?> k = t; k != null; k = k.getEnclosingClass()) {
            if (!Modifier.isPublic(k.getModifiers())) return false;
        }
        return true;
    }

    static String renderType(Class<?> t) {
        if (t.isArray()) {
            String e = renderType(t.getComponentType());
            return e == null ? null : e + "[]";
        }
        if (t.isPrimitive()) return t.getName();
        if (!publicChain(t)) return null;
        return t.getCanonicalName();
    }

    static String defaultArg(Class<?> t) {
        String ty = renderType(t);
        if (ty == null) return null;
        if (!t.isPrimitive()) return "(" + ty + ") null";
        switch (t.getName()) {
            case "boolean": return "false";
            case "char":    return "(char) 0";
            case "long":    return "0L";
            case "float":   return "0f";
            case "double":  return "0d";
            case "void":    return null;
            default:        return "(" + ty + ") 0";   // byte / short / int
        }
    }

    static String defaultReturn(Class<?> t) {
        if (t == void.class) return "";
        if (!t.isPrimitive()) return "return null;";
        switch (t.getName()) {
            case "boolean": return "return false;";
            case "char":    return "return (char) 0;";
            case "long":    return "return 0L;";
            case "float":   return "return 0f;";
            case "double":  return "return 0d;";
            default:        return "return 0;";
        }
    }

    // Every argument is CAST to its erasure, always.  Not decoration: a bare `null` against an
    // overloaded member is `reference to m is ambiguous` and would drop the probe for a reason that
    // has nothing to do with the library.
    static String renderCall(String recv, Method m) {
        StringBuilder sb = new StringBuilder(recv + "." + m.getName() + "(");
        Class<?>[] ps = m.getParameterTypes();
        for (int i = 0; i < ps.length; i++) {
            String a = defaultArg(ps[i]);
            if (a == null) return null;
            if (i > 0) sb.append(", ");
            sb.append(a);
        }
        return sb.append(");").toString();
    }

    static boolean isObjectMethod(Method m) {
        try { Object.class.getMethod(m.getName(), m.getParameterTypes()); return true; }
        catch (NoSuchMethodException e) { return false; }
    }

    static Method samOf(Class<?> t) {
        if (t == null || !t.isInterface()) return null;
        Method found = null;
        try {
            for (Method m : t.getMethods()) {
                if (!Modifier.isAbstract(m.getModifiers()) || Modifier.isStatic(m.getModifiers())) continue;
                if (isObjectMethod(m)) continue;
                if (found != null) return null;
                found = m;
            }
        } catch (Throwable t2) { return null; }
        return found;
    }

    // A LAMBDA where the target type is not generic, an ANONYMOUS CLASS otherwise.  The distinction
    // is R530b's own one-variable control — `() -> {…}` vs `new H(){…}` — and a lambda against a RAW
    // functional interface is where javac's inference gives up, so the raw case takes the anon form
    // rather than being dropped.
    static String renderImplementor(Class<?> ft, Method sam) {
        String iface = renderType(ft);
        if (iface == null) return null;
        String ret = renderType(sam.getReturnType());
        if (ret == null) return null;
        Class<?>[] ps = sam.getParameterTypes();
        StringBuilder args = new StringBuilder();
        for (int i = 0; i < ps.length; i++) {
            String pt = renderType(ps[i]);
            if (pt == null) return null;
            if (i > 0) args.append(", ");
            args.append(pt).append(" __p").append(i);
        }
        if (ft.getTypeParameters().length == 0) {
            StringBuilder lam = new StringBuilder("(");
            for (int i = 0; i < ps.length; i++) { if (i > 0) lam.append(", "); lam.append("__p").append(i); }
            lam.append(") -> { ").append(SINK).append(" ").append(defaultReturn(sam.getReturnType())).append(" }");
            return lam.toString();
        }
        return "new " + iface + "() { public " + (sam.getReturnType() == void.class ? "void" : ret)
             + " " + sam.getName() + "(" + args + ") { " + SINK + " "
             + defaultReturn(sam.getReturnType()) + " } }";
    }

    // "…then a call into the library" (R595's `firePublic()`).  Capped at 8: the probe exists to
    // reach the library's own dispatch on the field, not to enumerate its API surface twice.
    static List<String> libraryCalls(Class<?> c, String src) {
        List<String> out = new ArrayList<>();
        Method[] ms;
        try { ms = c.getDeclaredMethods(); } catch (Throwable t) { return out; }
        List<Method> sorted = new ArrayList<>();
        for (Method m : ms) sorted.add(m);
        sorted.sort((a, b) -> (a.getName() + a.toString()).compareTo(b.getName() + b.toString()));
        for (Method m : sorted) {
            if (out.size() >= 8) break;
            int mod = m.getModifiers();
            if (!Modifier.isPublic(mod) || !Modifier.isStatic(mod)) continue;
            if (m.isSynthetic() || m.isBridge()) continue;
            String call = renderCall(src, m);
            if (call == null) continue;
            out.add("        try { " + call + " } catch (java.lang.Throwable __t) { }");
        }
        return out;
    }

    static String jstr(String s) {
        StringBuilder sb = new StringBuilder("\"");
        for (char ch : s.toCharArray()) {
            switch (ch) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n");  break;
                case '\r': sb.append("\\r");  break;
                case '\t': sb.append("\\t");  break;
                default:
                    if (ch < 0x20) sb.append(String.format("\\u%04x", (int) ch));
                    else sb.append(ch);
            }
        }
        return sb.append("\"").toString();
    }
}
