#!/usr/bin/env python3
"""
MEASURE the Android API->permission mapping, to decide whether a candor-java `permissions/1` extension
reads a vendor-published ground truth or degenerates into another curated table.

Three questions, from candor/BACKLOG.md:
  1. WHERE do the permission annotations live in a current SDK?
  2. Of the dangerous (runtime) permissions, how many are reachable from an ANNOTATED API?
  3. What fraction of annotations are anyOf / allOf / conditional=true?

ANSWERS, measured 2026-08-05 against a freshly installed SDK (API 30 and API 36):

  1. `platforms/android-NN/data/annotations.zip` — an XML sidecar keyed by a SIGNATURE STRING.
     NOT the bytecode: `@RequiresPermission` appears zero times in android.jar, while other annotations
     (Nullable/NonNull/Deprecated) survive on the same classes. candor-java is a bytecode engine, so this
     is a string join between an ASM method ref and a key like
       "android.location.LocationManager android.location.Location getLastKnownLocation(java.lang.String)"
     whose generic forms (`java.util.List<...>`) do not appear in erased bytecode descriptors at all.
  2. 46% at API 36 (19/41), 17% at API 30 — but ~37% once the artifacts are removed (see below).
  3. 20.1% conditional=true, 23.0% anyOf/allOf, leaving 60.6% single-permission and unconditional.

WHY THE HEADLINE NUMBER OVERSTATES IT, which is the finding that actually matters. Inspect the 19 and
four are not real coverage: READ_CONTACTS and WRITE_CONTACTS are annotated ONLY on
`E2eeContactKeysManager` (an encrypted-contact-keys corner, not how any app reads contacts), and
ACTIVITY_RECOGNITION and UWB_RANGING only on a `ServiceInfo.FOREGROUND_SERVICE_TYPE_*` CONSTANT, which
is not a callable API.

The structural reason: **ZERO annotations exist on the entire ContentResolver/ContentProvider surface.**
The consumer-privacy permissions — contacts, calendar, call log, SMS content, media, storage — are not
guarded by a distinctly-named method. They are guarded by the CONTENT URI passed as an argument:
`ContentResolver.query(CalendarContract.Events.CONTENT_URI, …)` requires READ_CALENDAR, and the same
method with a different URI requires READ_CONTACTS. No method annotation can express that, which is why
every one of those permissions is absent. It is a value-provenance problem, not a lookup problem.

Where the annotations DO cluster is the system/connectivity surface: bluetooth (144), telephony (125),
device-admin (96), wifi (37), location (34).

RE-RUN THIS when a new API level lands. The mapping is a MOVING TARGET and that is a design constraint,
not trivia: API 30 -> 36 went 130 -> 922 annotated members and 44 -> 187 permissions, and DROPPED three
(BLUETOOTH, BLUETOOTH_ADMIN, READ_EXTERNAL_STORAGE). An implementation must read the annotations for the
project's own compileSdk rather than bundle a snapshot.

    ANDROID_HOME=/opt/homebrew/share/android-commandlinetools python3 android-permission-coverage.py
"""
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

SDK = os.path.join(os.environ.get("ANDROID_HOME", "/opt/homebrew/share/android-commandlinetools"),
                   "platforms")

# The runtime ("dangerous") permission groups, from Android's documented list. HARDCODED, and that is a
# limitation of THIS MEASUREMENT, not of the design: the protection level lives in the framework's own
# AndroidManifest, which the SDK platform does not ship. Stated rather than hidden — a denominator you
# typed yourself is the kind of thing that quietly flatters a percentage.
DANGEROUS = """
ACCEPT_HANDOVER ACCESS_BACKGROUND_LOCATION ACCESS_COARSE_LOCATION ACCESS_FINE_LOCATION
ACCESS_MEDIA_LOCATION ACTIVITY_RECOGNITION ADD_VOICEMAIL ANSWER_PHONE_CALLS BODY_SENSORS
BODY_SENSORS_BACKGROUND CALL_PHONE CAMERA GET_ACCOUNTS NEARBY_WIFI_DEVICES POST_NOTIFICATIONS
PROCESS_OUTGOING_CALLS READ_CALENDAR READ_CALL_LOG READ_CONTACTS READ_EXTERNAL_STORAGE
READ_MEDIA_AUDIO READ_MEDIA_IMAGES READ_MEDIA_VIDEO READ_MEDIA_VISUAL_USER_SELECTED
READ_PHONE_NUMBERS READ_PHONE_STATE READ_SMS RECEIVE_MMS RECEIVE_SMS RECEIVE_WAP_PUSH
RECORD_AUDIO SEND_SMS USE_SIP UWB_RANGING WRITE_CALENDAR WRITE_CALL_LOG WRITE_CONTACTS
WRITE_EXTERNAL_STORAGE BLUETOOTH_ADVERTISE BLUETOOTH_CONNECT BLUETOOTH_SCAN
""".split()


def parse_annotations(zpath):
    """-> (items, perms_seen). One item per annotated member."""
    items, perms = [], set()
    with zipfile.ZipFile(zpath) as z:
        for name in z.namelist():
            if not name.endswith("annotations.xml"):
                continue
            try:
                root = ET.fromstring(z.read(name))
            except ET.ParseError:
                continue
            for item in root.findall("item"):
                sig = item.get("name", "")
                for ann in item.findall("annotation"):
                    if not ann.get("name", "").endswith("RequiresPermission"):
                        continue
                    rec = {"sig": sig, "kind": None, "perms": [], "conditional": False,
                           "pkg": name[:-len("/annotations.xml")].replace("/", ".")}
                    for val in ann.findall("val"):
                        vn, vv = val.get("name"), val.get("val", "")
                        if vn == "conditional":
                            rec["conditional"] = vv.strip().lower() == "true"
                            continue
                        found = re.findall(r'"([^"]+)"', vv.replace("&quot;", '"'))
                        if vn in ("value", "anyOf", "allOf") and found:
                            rec["kind"] = vn
                            rec["perms"] = found
                    if rec["perms"] or rec["conditional"]:
                        items.append(rec)
                        perms.update(rec["perms"])
    return items, perms


def universe(jar):
    """Every permission constant the platform defines — a machine-read denominator."""
    out = subprocess.run(["javap", "-constants", "-cp", jar, "android.Manifest$permission"],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout
    return set(re.findall(r'=\s*"([a-z0-9._]+\.permission\.[A-Z_0-9]+)"', out)) | \
           set(re.findall(r'String\s+([A-Z_0-9]+)\s*=', out))


def report(api):
    z = f"{SDK}/android-{api}/data/annotations.zip"
    jar = f"{SDK}/android-{api}/android.jar"
    if not os.path.exists(z):
        print(f"  API {api}: no annotations.zip"); return None
    items, perms = parse_annotations(z)
    consts = {c for c in universe(jar) if re.fullmatch(r"[A-Z_0-9]+", c)}
    short = {p.rsplit(".", 1)[-1] for p in perms}

    kinds = {}
    for it in items:
        kinds[it["kind"] or "conditional-only"] = kinds.get(it["kind"] or "conditional-only", 0) + 1
    cond = sum(1 for it in items if it["conditional"])
    multi = sum(1 for it in items if it["kind"] in ("anyOf", "allOf"))

    covered = sorted(p for p in DANGEROUS if p in short)
    missing = sorted(p for p in DANGEROUS if p not in short)

    print(f"\n{'='*78}\nAPI {api}\n{'='*78}")
    print(f"  annotated members ......... {len(items)}")
    print(f"  distinct packages ......... {len({i['pkg'] for i in items})}")
    print(f"  distinct permissions named  {len(short)}")
    print(f"  permission constants in the platform (machine-read denominator): {len(consts)}")
    print(f"\n  Q3 — annotation FORMS (each is a different verdict for candor):")
    for k, v in sorted(kinds.items(), key=lambda x: -x[1]):
        print(f"    {k:<18} {v:>5}  ({100*v/len(items):.1f}%)")
    print(f"    conditional=true   {cond:>5}  ({100*cond/len(items):.1f}%)  <- spec 0.24 unanswerable condition")
    print(f"    multi-permission   {multi:>5}  ({100*multi/len(items):.1f}%)  <- anyOf/allOf")
    print(f"\n  Q2 — DANGEROUS (runtime) permissions reachable from an annotated API:")
    print(f"    {len(covered)}/{len(DANGEROUS)} = {100*len(covered)/len(DANGEROUS):.0f}%")
    print(f"    NOT reachable from any annotation ({len(missing)}):")
    for m in missing:
        print(f"      · {m}")
    return {"api": api, "items": len(items), "perms": short, "covered": covered,
            "missing": missing, "cond": cond, "multi": multi}


if __name__ == "__main__":
    rs = [r for r in (report(a) for a in (30, 36)) if r]
    if len(rs) == 2:
        a, b = rs
        print(f"\n{'='*78}\nIS IT MAINTAINED? API {a['api']} -> {b['api']}\n{'='*78}")
        print(f"  annotated members: {a['items']} -> {b['items']}  ({b['items']-a['items']:+d})")
        print(f"  permissions named: {len(a['perms'])} -> {len(b['perms'])}  ({len(b['perms'])-len(a['perms']):+d})")
        gained = sorted(b["perms"] - a["perms"])
        print(f"  newly annotated permissions ({len(gained)}): {', '.join(gained[:12])}"
              + (" …" if len(gained) > 12 else ""))
        lost = sorted(a["perms"] - b["perms"])
        if lost:
            print(f"  DROPPED ({len(lost)}): {', '.join(lost[:12])}")
