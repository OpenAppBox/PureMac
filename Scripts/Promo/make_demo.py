#!/usr/bin/env python3
"""Builds the mock Mac that PureMac's DEBUG demo mode shows in promotional screenshots.

Everything here is fictional: the user "alex", the apps, the files and every size. The script
creates, under --root:

  Users/alex/...      a mock home folder (real folders and tiny files with the right names and dates)
  Applications/...    fictional app bundles (folders; the app gives them icons)
  Data/PureMac.sqlite a scan index of the mock home with realistic sizes (the real schema)
  demo.json           sizes and app/diagnostic data the app's demo mode reads

Nothing outside --root is touched. Run Scripts/Promo/make_screenshots.sh rather than this directly.
"""
import argparse, hashlib, json, os, re, shutil, sqlite3, time, unicodedata

GB, MB, KB = 1_000_000_000, 1_000_000, 1_000
NOW = time.time()
DAY = 86_400

# Storage categories (StorageCategory raw values).
APPS, DOCS, MEDIA, DEV, CACHES, BACKUPS, ARCHIVES, SYSTEM, UNCLASSIFIED, CLOUD, APPDATA, MAIL = range(12)


class Node:
    def __init__(self, name, size=0, days=7, cat=None, children=None, kind=None, small=(0, 0), content=None):
        self.name, self.own, self.days, self.cat = name, int(size), days, cat
        self.children = children or []
        self.kind = kind if kind is not None else (1 if children is not None else 0)
        self.small_count, self.small_bytes = small[0], int(small[1])
        self.content = content          # duplicate files share a content key

    @property
    def is_container(self):
        return self.kind in (1, 2)


def D(name, children, cat=None, days=None, small=(0, 0)):
    return Node(name, cat=cat, children=children, days=days, small=small)


def P(name, size, cat, days=7, files=1000):
    """A package (Photos library, Final Cut library): one opaque item."""
    n = Node(name, size, days, cat, children=[], kind=2)
    n.package_files = files
    return n


def F(name, size, days=7, cat=None, content=None):
    return Node(name, size, days, cat, kind=0, content=content)


def gb(x): return int(x * GB)
def mb(x): return int(x * MB)


# ---------------------------------------------------------------------------------------------
# Fictional apps. Bundle IDs drive cache/support folder names, so the real engine associates them.
APPS_LIST = [
    # name, bundle id, version, SF Symbol, gradient colors, bundle size, last used (days), running, signing, source
    ("Lumina Photo",     "com.lumina.photo",      "4.2.1",  "camera.aperture",            ["#FF8A3D", "#E8365D"], gb(2.31), 1,   False, "appStore",  "appStore"),
    ("Frame Studio",     "com.framestudio.app",   "11.0",   "film.stack",                 ["#7C5CFF", "#3B2BB8"], gb(3.48), 6,   False, "developer", "dragAndDrop"),
    ("Cadence DAW",      "com.cadence.daw",       "12.2",   "waveform",                   ["#FF5E8A", "#9B1E5E"], gb(4.21), 240, False, "developer", "installerPackage"),
    ("Polyform 3D",      "com.polyform.3d",       "5.1",    "cube.transparent",           ["#22C1C3", "#0F6B8F"], gb(3.64), 150, False, "developer", "installerPackage"),
    ("Gamebox Launcher", "com.gamebox.launcher",  "3.8.4",  "gamecontroller.fill",        ["#4ADE80", "#15803D"], gb(1.12), 210, False, "developer", "dragAndDrop"),
    ("Ember Browser",    "com.ember.browser",     "128.0",  "flame.fill",                 ["#FDBA74", "#EA580C"], mb(612),  0,   True,  "developer", "dragAndDrop"),
    ("Slate Chat",       "com.slatechat.desktop", "4.41",   "bubble.left.and.bubble.right.fill", ["#60A5FA", "#1D4ED8"], mb(498), 0, True, "developer", "dragAndDrop"),
    ("Orbit Code",       "dev.orbitcode.app",     "1.96",   "chevron.left.forwardslash.chevron.right", ["#38BDF8", "#0369A1"], mb(437), 0, True, "developer", "dragAndDrop"),
    ("Vector Forge",     "com.vectorforge.app",   "2.6",    "pencil.and.outline",         ["#F472B6", "#BE185D"], gb(1.38), 21,  False, "appStore",  "appStore"),
    ("Northwind Mail",   "com.northwind.mail",    "6.3",    "envelope.fill",              ["#93C5FD", "#2563EB"], mb(286),  0,   False, "appStore",  "appStore"),
    ("Atlas Maps Pro",   "com.atlasmaps.pro",     "9.1",    "map.fill",                   ["#86EFAC", "#059669"], mb(731),  390, False, "appStore",  "appStore"),
    ("Inkwell Notes",    "com.inkwell.notes",     "3.0.2",  "note.text",                  ["#FDE68A", "#D97706"], mb(184),  2,   False, "appStore",  "appStore"),
    ("Quill Writer",     "com.quill.writer",      "7.4",    "text.book.closed.fill",      ["#C4B5FD", "#6D28D9"], mb(212),  120, False, "appStore",  "appStore"),
    ("Harbor VPN",       "com.harborvpn.client",  "2.9",    "lock.shield.fill",           ["#5EEAD4", "#0F766E"], mb(96),   9,   False, "developer", "installerPackage"),
    ("Tempo Timer",      "com.tempotimer.app",    "1.4",    "timer",                      ["#FCA5A5", "#DC2626"], mb(38),   33,  False, "appStore",  "appStore"),
    ("Pixel Sketch",     "com.pixelsketch.app",   "2.0",    "paintbrush.pointed.fill",    ["#F9A8D4", "#DB2777"], mb(905),  280, False, "developer", "dragAndDrop"),
]

# Per-app data in ~/Library (sizes in bytes). Keys are Library-relative paths.
def app_library():
    caches = {
        "com.lumina.photo": gb(3.42), "com.framestudio.app": gb(2.86), "com.cadence.daw": gb(0.92),
        "com.polyform.3d": gb(1.24), "com.gamebox.launcher": gb(0.66), "com.ember.browser": gb(2.21),
        "com.slatechat.desktop": gb(1.12), "dev.orbitcode.app": gb(0.87), "com.vectorforge.app": gb(0.48),
        "com.northwind.mail": gb(0.61), "com.atlasmaps.pro": gb(0.33), "com.inkwell.notes": mb(96),
        "com.quill.writer": mb(41), "com.pixelsketch.app": mb(388),
    }
    support = {
        "com.lumina.photo": gb(3.9), "com.framestudio.app": gb(4.4), "com.cadence.daw": gb(6.1),
        "com.polyform.3d": gb(2.7), "com.gamebox.launcher": gb(14.6), "com.ember.browser": gb(3.1),
        "Slate Chat": gb(1.2), "dev.orbitcode.app": gb(1.6), "com.vectorforge.app": mb(640),
        "com.atlasmaps.pro": gb(2.4), "com.pixelsketch.app": mb(512), "com.harborvpn.client": mb(22),
    }
    containers = {"com.northwind.mail": gb(1.62), "com.inkwell.notes": mb(705), "com.quill.writer": mb(318), "com.tempotimer.app": mb(4)}
    return caches, support, containers


def build_home():
    caches, support, containers = app_library()
    cache_nodes = [D(bid, [F("Cache.db", s, days=2)], cat=CACHES) for bid, s in caches.items()]
    cache_nodes += [
        D("Homebrew", [D("downloads", [F(f"{h}--{n}.bottle.tar.gz", s, days=d) for h, n, s, d in [
            ("8f1c", "ffmpeg-7.1", mb(1240), 40), ("2b9e", "llvm-19.1", mb(1410), 52), ("c71d", "python@3.13", mb(530), 33)]])], cat=CACHES),
        D("pip", [F("wheels.db", mb(640), days=21)], cat=CACHES),
        D("Yarn", [F("v6.cache", mb(1200), days=18)], cat=CACHES),
        D("CocoaPods", [F("Pods.cache", mb(910), days=64)], cat=CACHES),
    ]
    support_nodes = [D(k, [F("Library.data", v, days=5)], cat=APPDATA) for k, v in support.items()]
    support_nodes.append(D("Slate Chat", [F("Library.data", gb(1.2)), D("Cache", [F("data_1", gb(1.12), days=0)])], cat=APPDATA))
    support_nodes = [n for n in support_nodes if not (n.name == "Slate Chat" and len(n.children) == 1)]
    support_nodes.append(D("MobileSync", [D("Backup", [P("00008110-alex-iPhone", gb(21.4), BACKUPS, days=19, files=91_234)])], cat=BACKUPS))
    # Remnants of apps that are no longer installed (orphan detection finds these).
    support_nodes += [D("com.driftsoft.sketchbook", [F("Brushes.data", gb(1.38), days=210)], cat=APPDATA, days=210),
                      D("io.tunnelbox.client", [F("state.data", mb(58), days=12)], cat=APPDATA, days=12)]
    cache_nodes += [D("com.driftsoft.sketchbook", [F("Cache.db", mb(412), days=214)], cat=CACHES, days=214),
                    D("com.parallax.videoconverter", [F("Cache.db", gb(2.06), days=330)], cat=CACHES, days=330)]
    container_nodes = [D(k, [F("Data.db", v, days=3)], cat=APPDATA) for k, v in containers.items()]
    container_nodes.append(D("com.oldvendor.pdfreader", [F("Data.db", mb(186), days=4)], cat=APPDATA, days=4))

    derived = [D(n, [F("Index.noindex", s, days=d)], cat=DEV) for n, s, d in [
        # Xcode names these "<Project>-<28 letters>".
        ("PixelKit-hzqkfdtwuyxbnmalrcpeosgvijtd", gb(8.9), 3), ("OrbitDashboard-agmdkxtwqzbneoyfhlrcujpsvimt", gb(5.2), 9),
        ("AtlasMobile-cwlpqrbyhwnxtegsakdfiuzomjvq", gb(3.1), 47), ("Playground-fjdkeuqopwmtzsrhaxcgvnlbyiwe", gb(1.5), 122),
        ("LegacyWidgets-qpwoeirutyalskdjfhgzmxncbvlk", gb(0.9), 214)]]
    developer = D("Developer", [
        D("Xcode", [
            D("DerivedData", derived),
            D("Archives", [D("2026-09-02", [P("PixelKit 2.4.xcarchive", gb(3.4), DEV, 46, files=1840)]),
                           D("2026-06-14", [P("PixelKit 2.3.xcarchive", gb(2.8), DEV, 126, files=1702)])]),
            D("iOS DeviceSupport", [D("iPhone15,2 26.0 (23A341)", [F("Symbols.cache", gb(4.6), days=58)]),
                                    D("iPhone15,2 26.1 (23B82)", [F("Symbols.cache", gb(4.5), days=12)])]),
            D("UserData", [D("Previews", [F("Previews.data", gb(1.8), days=4)])]),
        ]),
        D("CoreSimulator", [D("Devices", [], small=(284_112, gb(31.4))),
                            D("Caches", [D("dyld", [F("shared_cache", gb(2.4), days=15)])])]),
    ], cat=DEV)
    logs = D("Logs", [D("com.framestudio.app", [F("render.log", mb(214), days=45)], days=45),
                      D("DiagnosticReports", [F(f"FrameStudio-2026-0{m}-1{m}-101522.ips", mb(36), days=40 + m * 8) for m in range(1, 6)], days=40),
                      D("com.cadence.daw", [F("engine.log", mb(48), days=240)], days=240)], cat=CACHES)
    prefs = D("Preferences", [F(f"{a[1]}.plist", KB * 40, days=a[6]) for a in APPS_LIST] +
              [F("com.driftsoft.sketchbook.plist", KB * 24, days=212)], cat=APPDATA)
    saved = D("Saved Application State", [D(f"{a[1]}.savedState", [F("windows.plist", KB * 300, days=2)]) for a in APPS_LIST[:6]] +
              [D("com.parallax.videoconverter.savedState", [F("windows.plist", KB * 300, days=333)], days=333)], cat=APPDATA)
    agents = D("LaunchAgents", [F("com.ember.browser.updater.plist", KB * 4, days=30),
                                F("com.harborvpn.client.helper.plist", KB * 4, days=90),
                                F("io.tunnelbox.client.plist", KB * 4, days=400)], cat=APPDATA)
    library = D("Library", [
        D("Caches", cache_nodes, cat=CACHES),
        D("Application Support", support_nodes, cat=APPDATA),
        D("Containers", container_nodes, cat=APPDATA),
        developer, logs, prefs, saved, agents,
        D("Mail", [], cat=MAIL, small=(184_331, gb(11.2))),
        D("Mobile Documents", [D("com~apple~CloudDocs", [], small=(42_910, gb(28.4)))], cat=CLOUD),
    ], cat=APPDATA)

    home = D("alex", [
        D("Movies", [
            D("Final Cut Libraries", [P("Iceland Trip 2025.fcpbundle", gb(112.4), MEDIA, 12, files=9_412),
                                      P("Lisbon Wedding.fcpbundle", gb(74.1), MEDIA, 140, files=7_204)]),
            D("Exports", [F("Iceland Trip 2025 — Master 4K.mov", gb(18.9), 10), F("Lisbon Wedding — Final.mov", gb(11.2), 402),
                          F("Lisbon Wedding — Teaser.mp4", gb(1.4), 395)]),
            D("Raw", [F("Iceland-Drone-0412.mov", gb(2.41), 30, content="drone0412"), F("Iceland-Drone-0413.mov", gb(2.12), 30),
                      F("GoPro-0091.mp4", gb(3.6), 20)]),
        ], cat=MEDIA),
        D("Pictures", [P("Photos Library.photoslibrary", gb(128.3), MEDIA, 1, files=212_480),
                       D("Lightroom", [F("Lightroom Catalog.lrcat", gb(7.8), 6)]),
                       D("Screenshots", [], small=(1_834, gb(2.1)))], cat=MEDIA),
        D("Music", [D("Music", [D("Media.localized", [], small=(5_120, gb(24.6)))]),
                    D("Cadence Projects", [F("Northern Lights.cdp", gb(4.9), 240), F("Late Night Sessions.cdp", gb(4.5), 260)])], cat=MEDIA),
        D("Documents", [
            D("Work", [], small=(12_410, gb(14.2))),
            F("Client Archive 2023.zip", gb(6.8), 610, cat=ARCHIVES),
            F("Tax Return 2024.pdf", mb(12.4), 190, content="tax2024"),
            D("Design", [F("Brand-Assets-2025.zip", gb(1.18), 70, cat=ARCHIVES, content="brand2025"),
                         F("Keynote-Template.key", mb(312), 88, content="keynote")]),
            D("Papers", [], small=(3_120, gb(3.1))),
        ], cat=DOCS),
        D("Downloads", [
            F("Cadence-DAW-12.2.dmg", gb(1.9), 75, cat=ARCHIVES), F("Polyform-Setup-5.1.pkg", gb(1.4), 64, cat=ARCHIVES),
            F("Ubuntu-24.04-desktop-arm64.iso", gb(6.1), 430, cat=ARCHIVES), F("Frame-Studio-Templates.zip", gb(4.3), 380, cat=ARCHIVES),
            F("Iceland-Drone-0412.mov", gb(2.41), 29, cat=MEDIA, content="drone0412"),
            F("Brand-Assets-2025.zip", gb(1.18), 66, cat=ARCHIVES, content="brand2025"),
            F("Product-Demo-Final.mp4", mb(864), 41, cat=MEDIA, content="demo"),
            F("Tax Return 2024.pdf", mb(12.4), 188, cat=DOCS, content="tax2024"),
            F("Keynote-Template.key", mb(312), 80, cat=DOCS, content="keynote"),
        ], cat=ARCHIVES, small=(2_410, gb(1.2))),
        D("Desktop", [D("Footage", [F("Iceland-Drone-0412.mov", gb(2.41), 28, content="drone0412")]),
                      F("Product-Demo-Final.mp4", mb(864), 40, content="demo"),
                      F("Tax Return 2024.pdf", mb(12.4), 150, cat=DOCS, content="tax2024")], cat=MEDIA, small=(96, gb(1.1))),
        D("Projects", [
            D("atlas-web", [D("node_modules", [], small=(212_904, gb(1.9))), D("src", [], small=(840, mb(120)))]),
            D("orbit-dashboard", [D("node_modules", [], small=(161_220, gb(1.4))), D("src", [], small=(610, mb(90)))]),
            D("pixelkit-ios", [D("build", [F("PixelKit.app.dSYM.zip", gb(2.6), 9)]), D("Sources", [], small=(1_210, mb(300)))]),
            D("ml-experiments", [D("datasets", [F("images-2025.tar", gb(12.8), 160, cat=UNCLASSIFIED)]), D(".venv", [], small=(48_000, gb(3.2)))]),
        ], cat=DEV),
        library,
        D(".npm", [D("_cacache", [F("index-v5", gb(2.4), 26)])], cat=DEV),
        D(".cache", [D("huggingface", [D("hub", [F("models--vision-base-v2.safetensors", gb(9.6), 140), F("models--speech-small.safetensors", gb(4.6), 90)])], cat=APPDATA)], cat=CACHES),
        D("Applications", [P("Retro Arcade.app", gb(9.8), APPS, 300, files=4_120)], cat=APPS),
        D(".Trash", [], cat=SYSTEM, small=(214, mb(420))),
    ])
    return home


# ---------------------------------------------------------------------------------------------

def finalize(node, inherited=None, parent_days=None):
    """Computes sizes, counts, categories and dates bottom-up."""
    node.cat = node.cat if node.cat is not None else inherited
    if node.kind == 0:
        node.size, node.files, node.dirs = node.own, 1, 0
        node.cat = node.cat if node.cat is not None else UNCLASSIFIED
        node.mdays = node.days
        return
    if node.kind == 2:
        node.size, node.files, node.dirs, node.mdays = node.own, getattr(node, "package_files", 1000), 0, node.days
        return
    for c in node.children:
        finalize(c, node.cat)
    node.size = sum(c.size for c in node.children) + node.small_bytes
    node.files = sum(c.files for c in node.children) + node.small_count
    node.dirs = sum(c.dirs + (1 if c.kind == 1 else 0) for c in node.children)
    newest = min([c.mdays for c in node.children] + ([2] if node.small_count else []), default=30)
    node.mdays = node.days if node.days is not None else newest
    # Folder category: the location context, else the category holding ≥ 60% of the bytes.
    if node.cat is None:
        by = {}
        for c in node.children: by[c.cat] = by.get(c.cat, 0) + c.size
        best = max(by.items(), key=lambda kv: kv[1], default=(UNCLASSIFIED, 0))
        node.cat = best[0] if node.size and best[1] / node.size >= 0.6 else UNCLASSIFIED


def walk(node, path, depth=0, parent=None):
    yield node, path, depth, parent
    for c in node.children:
        yield from walk(c, path + "/" + c.name, depth + 1, node)


def leaf_categories(node, totals):
    if node.kind in (0, 2):
        t = totals.setdefault(node.cat, [0, 0]); t[0] += node.files; t[1] += node.size
    else:
        if node.small_count:
            t = totals.setdefault(node.cat, [0, 0]); t[0] += node.small_count; t[1] += node.small_bytes
        for c in node.children: leaf_categories(c, totals)


def schema_sql(repo):
    text = open(os.path.join(repo, "Packages/PureMacKit/Sources/PureMacKit/Persistence/DatabaseSchema.swift")).read()
    return re.search(r'"""\n(.*?)\n\s*"""', text, re.S).group(1)


def name_key(name):
    return unicodedata.normalize("NFC", name).casefold()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    args = ap.parse_args()
    root = os.path.abspath(args.root)
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(os.path.join(root, "Users", "alex"))
    root = os.path.realpath(root)   # the engine works with resolved paths
    home_path = os.path.join(root, "Users", "alex")

    home = build_home()
    finalize(home)

    # Filesystem: folders, tiny files with the right names and dates (duplicates share content).
    device = os.lstat(home_path).st_dev
    sizes = {}
    for node, path, depth, parent in walk(home, home_path):
        rel = os.path.relpath(path, home_path)
        if depth > 0:
            sizes[rel] = {"bytes": node.size, "days": node.mdays, "files": node.files}
        if node.kind == 1 or node.kind == 2:
            os.makedirs(path, exist_ok=True)
        else:
            payload = (f"PureMac demo · {node.content}" if node.content else f"PureMac demo · {rel}").encode()
            with open(path, "wb") as f:
                f.write(payload * 64)
    for node, path, depth, parent in sorted(walk(home, home_path), key=lambda t: -t[2]):   # deepest first
        t = NOW - node.mdays * DAY
        os.utime(path, (t, t))

    for app in APPS_LIST:   # in ~/Applications, so paths read "~/Applications/…"
        os.makedirs(os.path.join(home_path, "Applications", app[0] + ".app", "Contents"), exist_ok=True)

    # Scan index.
    # Not next to the home folder: PureMac never touches its own data folder, so it must not contain the home.
    os.makedirs(os.path.join(root, "Data"))
    db = sqlite3.connect(os.path.join(root, "Data", "PureMac.sqlite"))
    db.executescript(schema_sql(args.repo))
    db.execute("PRAGMA user_version = 1")
    # Recorded as a whole-disk scan, so Overview shows the finished picture (no "isn't in this
    # scan" prompt). The index itself is the demo home folder.
    roots = json.dumps([{"path": home_path, "kind": "dataVolume"}])

    totals = {}
    leaf_categories(home, totals)
    # Older sessions (summaries only) give the trend chart and "changes since previous scan".
    history = [(-118, 0.83), (-87, 0.88), (-56, 0.91), (-27, 0.95), (-14, 0.97)]
    top = [c for c in home.children]
    growth = {"Movies": 0.78, "Downloads": 0.42, "Library": 0.965, "Projects": 0.84, "Documents": 1.09, "Pictures": 0.986, "Desktop": 1.22}
    for i, (offset, scale) in enumerate(history):
        started = NOW + offset * DAY
        cur = db.execute("INSERT INTO scan_session(started_at, finished_at, status, roots, file_count, dir_count, logical_bytes, allocated_bytes, small_threshold, has_index) VALUES (?,?,?,?,?,?,?,?,?,0)",
                         (started, started + 41, "completed", roots, int(home.files * scale), int(home.dirs * scale), int(home.size * scale * 1.03), int(home.size * scale), 262_144))
        sid = cur.lastrowid
        last = i == len(history) - 1
        db.execute("INSERT INTO root_summary VALUES (?,?,?,?,?,?)", (sid, home_path, 0, int(home.size * scale * 1.03), int(home.size * scale), int(home.files * scale)))
        for c in top:
            factor = growth.get(c.name, 1.0) if last else scale
            db.execute("INSERT INTO root_summary VALUES (?,?,?,?,?,?)", (sid, home_path + "/" + c.name, 1, int(c.size * factor), int(c.size * factor), c.files))
        for cat, (count, size) in totals.items():
            db.execute("INSERT INTO category_total VALUES (?,?,?,?,?)", (sid, cat, int(count * scale), int(size * scale * 1.03), int(size * scale)))

    started = NOW - 3 * 3600
    cur = db.execute("INSERT INTO scan_session(started_at, finished_at, status, roots, file_count, dir_count, logical_bytes, allocated_bytes, small_threshold, has_index) VALUES (?,?,?,?,?,?,?,?,?,1)",
                     (started, started + 38.6, "completed", roots, home.files, home.dirs, int(home.size * 1.03), home.size, 262_144))
    sid = cur.lastrowid
    ids, next_id, inode = {}, 1, 900_000
    for node, path, depth, parent in walk(home, home_path):
        if node.kind == 0 and node.size < 262_144:
            continue
        ids[id(node)] = next_id
        ext = os.path.splitext(node.name)[1][1:].lower() or None
        inode += 1
        m = NOW - node.mdays * DAY
        db.execute("INSERT INTO entry VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (
            next_id, sid, ids.get(id(parent)) if parent else None, depth, node.kind, node.name, name_key(node.name), path, ext,
            int(node.size * 1.03), node.size, m, m - 400 * DAY, node.files, node.dirs,
            node.small_count, int(node.small_bytes * 1.03), node.small_bytes, device, inode, 0, node.cat))
        next_id += 1
    db.execute("INSERT INTO root_summary VALUES (?,?,?,?,?,?)", (sid, home_path, 0, int(home.size * 1.03), home.size, home.files))
    for c in top:
        db.execute("INSERT INTO root_summary VALUES (?,?,?,?,?,?)", (sid, home_path + "/" + c.name, 1, int(c.size * 1.03), c.size, c.files))
    for cat, (count, size) in totals.items():
        db.execute("INSERT INTO category_total VALUES (?,?,?,?,?)", (sid, cat, count, int(size * 1.03), size))

    # Cleanup history (oldest first, so the newest has the highest id and is listed first).
    for title, mode, days, items, moved in [
        ("Selected items", "userFiles", 63, [("Downloads/Xcode_26_beta.xip", gb(8.9))], True),
        ("Duplicate copies", "duplicates", 47, [("Downloads/GoPro-0090.mp4", gb(3.1)), ("Desktop/Lisbon-Teaser-v2.mp4", gb(1.4))], True),
        ("Uninstall Snapclip", "uninstallKeepData", 34, [("Applications/Snapclip.app", gb(1.24)), ("Library/Caches/com.snapclip.app", mb(318)), ("Library/Logs/com.snapclip.app", mb(42))], True),
        ("Smart Clean", "smartClean", 21, [("Library/Caches/com.lumina.photo", gb(2.9)), ("Library/Caches/Homebrew/downloads", gb(2.2)), ("Library/Caches/com.framestudio.app", gb(1.6)), (".npm/_cacache", gb(1.1))], True),
    ]:
        started = NOW - days * DAY
        total = sum(b for _, b in items)
        cur = db.execute("INSERT INTO cleanup_operation(plan_uuid, mode, title, started_at, finished_at, status, item_count, moved, failed, skipped, bytes_identified, bytes_trashed, free_before, free_after, detailed) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,1)",
                         (hashlib.md5(title.encode()).hexdigest(), mode, title, started, started + 6, "finished", len(items), len(items), 0, 0, total, total, gb(61.2), gb(61.2) + int(total * 0.97)))
        for seq, (rel, b) in enumerate(items):
            base = os.path.basename(rel)
            db.execute("INSERT INTO cleanup_item(operation_id, seq, path, trash_path, bytes, status) VALUES (?,?,?,?,?,?)",
                       (cur.lastrowid, seq, os.path.join(home_path, rel), os.path.join(home_path, ".Trash", base), b, "movedToTrash"))
    db.commit()
    db.close()

    manifest = {
        "home": home_path,
        "applications": os.path.join(home_path, "Applications"),
        "sizes": sizes,
        "apps": [{"name": a[0], "bundleID": a[1], "version": a[2], "symbol": a[3], "colors": a[4], "bundleBytes": a[5],
                  "lastUsedDays": a[6], "running": a[7], "signing": a[8], "source": a[9]} for a in APPS_LIST],
        "volume": {"name": "Macintosh HD", "total": 994_662_584_320, "available": gb(78.4), "important": gb(96.1)},
        "duplicateRoots": ["Downloads", "Documents", "Desktop", "Movies"],
    }
    with open(os.path.join(root, "demo.json"), "w") as f:
        json.dump(manifest, f, indent=1, ensure_ascii=False)
    print(f"demo home {home_path}: {home.size / GB:.1f} GB, {home.files:,} files, {next_id - 1:,} index rows")


if __name__ == "__main__":
    main()
