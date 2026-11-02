"""Run the people-grouping policies on a COPY of the owner's Moments store and print counts only.
Prints no names, photos, paths or embeddings. There is no answer key on real data, so this shows
how many cards/questions/loose faces each policy would leave, not how correct it is.
Usage: python3 real_check.py <copy-of-Moments.store>"""
import os, sqlite3, sys, collections
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import baseline_current, baseline_proposal, route_p5, route_p3, route_f1a, route_f1b

store = sys.argv[1]
db = sqlite3.connect(f"file:{store}?mode=ro", uri=True)
tables = {r[0].upper(): r[0] for r in db.execute("select name from sqlite_master where type='table'")}
def cols(t): return {r[1].upper(): r[1] for r in db.execute(f"pragma table_info({t})")}
ft, mt = tables["ZFACEOBSERVATION"], tables["ZMEDIAITEM"]
fc, mc = cols(ft), cols(mt)
ext = os.path.join(os.path.dirname(store), "." + os.path.basename(store).rsplit(".", 1)[0] + "_SUPPORT", "_EXTERNAL_DATA")

def decode(blob):
    if blob is None: return None
    b = bytes(blob)
    if len(b) == 513 and b[0] == 1: b = b[1:]
    elif b[:1] == b"\x02":
        p = os.path.join(ext, b[1:].decode(errors="ignore").strip("\x00"))
        b = open(p, "rb").read() if os.path.exists(p) else b""
    if len(b) != 512: return None
    v = np.frombuffer(b, dtype="<f4").astype(float); n = np.linalg.norm(v)
    return v / n if n > 0 else None

dates = {r[0]: r[1] for r in db.execute(f"select {mc['ZID']}, {mc['ZCAPTUREDATE']} from {mt}")}
rows = db.execute(f"select {fc['ZMEDIAID']}, {fc['ZEMBEDDING']}, {fc['ZQUALITY']}, {fc['ZCONFIRMED']}, {fc['ZASSIGNMENTSOURCE']} from {ft}").fetchall()
X, q, media, tm, ev = [], [], [], [], []
mids = {}
skipped = 0
for i, (mid, emb, qual, conf, src) in enumerate(rows):
    v = decode(emb)
    if v is None or (conf and src == "user"):
        skipped += 1; continue
    X.append(v); q.append(qual or 0.0); media.append(mids.setdefault(mid, len(mids)))
    d = dates.get(mid)
    if d is None:
        tm.append(-1e6 - i); ev.append(-1 - i)          # no date: never shares an outing or a year
    else:
        day = d / 86400.0                                # Core Data seconds since 2001 -> days
        tm.append(day); ev.append(int(np.floor(day)))     # outing = calendar day (UTC)
L = dict(X=np.array(X), quality=np.array(q), media=np.array(media), time=np.array(tm), event=np.array(ev),
         person=np.zeros(len(X), dtype=int))            # dummy: real data has no answer key
print(f"faces used {len(X)}, skipped {skipped} (confirmed by the owner or unreadable), photos {len(mids)}, "
      f"faces without a date {sum(1 for e in ev if e < 0)}")

policies = [
    ("today (average 0.65, every group a card)", lambda L: baseline_current.plan(L)),
    ("first proposal", lambda L: baseline_proposal.plan(L)),
    ("route P5", lambda L: route_p5.plan(L)),
    ("route P3", lambda L: route_p3.plan(L, **route_p3.FINAL)),
    ("fusion F1a", lambda L: route_f1a.plan(L)),
    ("fusion F1b", lambda L: route_f1b.plan(L, **route_f1b.FINAL)),
]
print("policy | cards to name | yes/no questions listed | loose faces | biggest cards | cards with 3-5 faces")
for name, pol in policies:
    out = pol(L)
    sizes = sorted((len(g) for g in out["groups"] if len(g)), reverse=True)
    print(f"{name} | {len(sizes)} | {len(out.get('questions', []))} | {len(out.get('folded', []))} | "
          f"{sizes[:6]} | {sum(1 for s in sizes if 3 <= s <= 5)}")
print("done")
