"""Route F1 - fusion of P5 (quality + context) and P3 (mutual-kNN graph).

Policy in words:
 1. Only good faces (quality >= 0.45) define groups: average-link clustering at cosine 0.62.
 2. A poor face joins the group of its nearest good face when that face is closer than 0.55, or the
    centre of a big group (>= 30 faces) when that centre is closer than 0.60; else it is a loose face.
 3. Two big groups merge only on several signals at once: one mutual kNN edge under 0.55, at least 4
    shared near neighbours, centres under 0.62 and a kNN vote share of at least 0.45.
 4. A small group attaches to its nearest big group when the centres are under 0.55, when every one of
    its faces is under 0.58 from that group, or when the centres are under 0.72 and two of (shared
    outing, same-year look, kNN vote >= 0.5) agree; otherwise it stays loose.
 5. Loose groups that clearly belong together are joined (centres < 0.62, closest faces < 0.58) and are
    then offered the same attach test once more; a join of >= 3 faces becomes a card.
 6. The remaining cards get yes/no questions, closest first, under P5's centre, outing and same-year rules.

Usage:  python3 route_f1.py                 # final parameters, seeds 0-4
        python3 route_f1.py refs            # P5/P3 reference tables
        python3 route_f1.py holdout         # seeds 30-34, synth v2 and v1
Only score.evaluate reads the identity labels; this policy never touches them.
"""
import sys
import time

import numpy as np
from scipy.cluster.hierarchy import fcluster, linkage
from scipy.spatial.distance import pdist


# --------------------------------------------------------------------- reporting
def worst_per_row(rows, keys=("wrong_faces", "lost_faces")):
    """Per (variant, n) row: the worst seed for each metric (mean is not enough)."""
    out = {}
    for r in rows:
        key = f"{r['variant']}-{r['n']}"
        d = out.setdefault(key, {})
        for k in keys:
            if k not in d or r[k] > d[k][0]:
                d[k] = (r[k], r["seed"])
    return out


def report(rows, title=""):
    from score import table

    lines = []
    if title:
        lines.append(f"== {title} ==")
    lines.append(table(rows))
    lines.append("worst seed per row (value, seed):")
    for key, d in worst_per_row(rows).items():
        parts = [f"{k} {v[0]:.0f} (seed {v[1]})" for k, v in d.items()]
        lines.append("  " + key + ": " + ", ".join(parts))
    return "\n".join(lines)


def run_rows(policy, seeds=(0, 1, 2, 3, 4), sizes=(1134, 5000), v1=False):
    if v1:
        import synth_v1

        sys.modules["synth"] = synth_v1
    from score import run

    return run(policy, seeds=seeds, sizes=sizes)


# ----------------------------------------------------------------------- helpers
def _unit(V):
    V = np.atleast_2d(np.asarray(V, dtype=float))
    return V / np.maximum(np.linalg.norm(V, axis=1, keepdims=True), 1e-12)


def _knn(X, k, chunk=1024):
    """Indices and cosine distances of the k nearest neighbours of every face (self excluded)."""
    n = len(X)
    k = int(min(k, n - 1))
    nbr = np.empty((n, k), np.int32)
    nd = np.empty((n, k), np.float64)
    for s in range(0, n, chunk):
        e = min(s + chunk, n)
        D = 1.0 - X[s:e] @ X.T
        D[np.arange(e - s), np.arange(s, e)] = np.inf
        part = np.argpartition(D, k - 1, axis=1)[:, :k]
        d = np.take_along_axis(D, part, axis=1)
        o = np.argsort(d, axis=1)
        nbr[s:e] = np.take_along_axis(part, o, axis=1)
        nd[s:e] = np.take_along_axis(d, o, axis=1)
    return nbr, nd


def _edges(nbr, nd, k):
    """Mutual-kNN edges (src < dst) with distance and shared-near-neighbour count (SNN)."""
    n = nbr.shape[0]
    src = np.repeat(np.arange(n), k)
    dst = nbr.ravel()
    dd = nd.ravel()
    mutual = (nbr[dst] == src[:, None]).any(1)
    A = nbr[dst]
    B = nbr[src]
    snn = np.zeros(len(src), np.int16)
    for t in range(k):
        snn += (A == B[:, t : t + 1]).any(1)
    sel = (src < dst) & mutual
    return src[sel], dst[sel], dd[sel], snn[sel]


def _components(n, a, b):
    parent = np.arange(n)

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for u, v in zip(a, b):
        ru, rv = find(u), find(v)
        if ru != rv:
            parent[rv] = ru
    root = np.array([find(x) for x in range(n)])
    _, lab = np.unique(root, return_inverse=True)
    return lab


def _shares_photo(media, ga, gb):
    return len(set(media[ga].tolist()) & set(media[gb].tolist())) > 0


def _time_buckets(X, idx, tm, window):
    idx = np.asarray(idx)
    b = (tm[idx] // window).astype(int)
    out = {}
    for k in np.unique(b):
        m = idx[b == k]
        out[int(k)] = (_unit(X[m].mean(0))[0], len(m))
    return out


def _time_distance(A, B):
    common = set(A) & set(B)
    if not common:
        return np.inf
    s = 0.0
    wsum = 0
    for k in common:
        a, na = A[k]
        b, nb = B[k]
        w = min(na, nb)
        s += w * (1.0 - float(a @ b))
        wsum += w
    return s / wsum


DEFAULTS = dict(
    q_good=0.45,        # faces at least this good define the groups
    auto=0.62,          # average-link cut on the good faces
    attach=0.55,        # poor face -> group of its nearest good face
    attach_big=0.60,    # ... or the centre of a big group when that centre is this close
    attach_big_size=30, # a big group means at least this many faces
    poor_auto=0.0,      # poor faces that fit nowhere cluster among themselves at this cut (0 = off)
    min_size=3,         # groups this big are cards, smaller ones are loose faces
    graph_k=15,         # neighbours per face for the graph evidence
    # graph merge of two big groups: several independent signals at once
    graph_cap=0.55,     # a mutual kNN edge must be closer than this
    snn_min=4,          # ... and share at least this many near neighbours
    merge_dcent=0.62,   # ... and the two group centres must be closer than this
    vote_min=0.45,      # ... and one group's neighbours must land mostly in the other
    # small-group attach
    absorb=0.55,        # centre this close: attach on one signal alone
    absorb_wide=0.72,   # up to here: attach only when two more signals agree
    absorb_time=0.62,   # (P5) same-year look closer than this
    ab_vote=0.50,       # (P3) share of the group's neighbours in that big group
    hint_need=2,        # extra signals needed between `absorb` and `absorb_wide` (9 = off)
    face_close=0.58,    # every face of the small group this close to the big group attaches it
    # join leftover fragments of one identity (P3 rule)
    join_c=0.62,
    join_ds=0.58,
    join_min=3,         # only a join this big is worth a card
    rescue_min=0,       # loose group this big gets a question instead of being folded (0 = off)
    # questions: P5 rules
    ask_centre=0.70,
    ask_event=0.78,
    ask_time=0.62,
    window=365.0,       # days per time bucket
)


def _group_pairs(lab, big, src, dst, dd, snn, cap, nface):
    """Per pair of group ids: mutual-edge count, max SNN, centre distance, kNN vote share."""
    nbig = len(big)
    gid = -np.ones(nface, np.int32)
    for bi, g in enumerate(big):
        gid[np.asarray(g)] = bi
    a, b, s = gid[src], gid[dst], snn
    ok = (a >= 0) & (b >= 0) & (a != b) & (dd <= cap)
    a, b, s = a[ok], b[ok], s[ok]
    out = dict(cnt=np.zeros((nbig, nbig), np.int32), snn=np.zeros((nbig, nbig), np.int32))
    if not len(a):
        return out
    lo, hi = np.minimum(a, b).astype(np.int64), np.maximum(a, b).astype(np.int64)
    key = lo * nbig + hi
    key, inv = np.unique(key, return_inverse=True)
    cnt = np.bincount(inv, minlength=len(key))
    mx = np.zeros(len(key), np.int32)
    np.maximum.at(mx, inv, s)
    np.add.at(out["cnt"], (key // nbig, key % nbig), cnt)
    out["snn"][key // nbig, key % nbig] = mx
    return out


def _votes(groups, X, nbr, k):
    """Share of each group's kNN that land in every other group (rows sum to <= 1)."""
    n = len(groups)
    o = np.full(len(X), -1, np.int32)
    for gi, g in enumerate(groups):
        o[np.asarray(g)] = gi
    V = np.zeros((n, n))
    for gi, g in enumerate(groups):
        ob = o[nbr[np.asarray(g)]]
        good = ob >= 0
        if not good.any():
            continue
        c = np.bincount(ob[good].ravel(), minlength=n)
        V[gi] = c / max(len(g) * k, 1)
    return V


def plan(L, **params):
    p = dict(DEFAULTS)
    p.update(params)
    X = np.asarray(L["X"], dtype=float)
    q = np.asarray(L["quality"])
    ev = np.asarray(L["event"])
    tm = np.asarray(L["time"])
    media = np.asarray(L["media"])
    n = len(X)
    k = int(min(p["graph_k"], n - 1))

    good_idx = np.where(q >= p["q_good"])[0]
    poor_idx = np.where(q < p["q_good"])[0]

    # 1. quality gating: only good faces define groups
    lab = np.full(n, -1, np.int32)          # face -> base group
    groups = []
    if len(good_idx) >= 2:
        g = fcluster(linkage(pdist(X[good_idx], "cosine"), "average"), p["auto"], "distance")
        for u in np.unique(g):
            groups.append(good_idx[g == u].tolist())
    elif len(good_idx) == 1:
        groups = [good_idx.tolist()]
    for gi, gr in enumerate(groups):
        lab[gr] = gi

    # 2. poor faces attach to the group of their nearest good face, or stand alone
    if len(poor_idx):
        loose = []
        if groups:
            U = _unit(X[good_idx])
            D = 1.0 - _unit(X[poor_idx]) @ U.T
            best = D.argmin(1)
            bd = D[np.arange(len(poor_idx)), best]
            # a big group has a stable centre, so a poor face may still join one
            big0 = [gi for gi, gr in enumerate(groups) if len(gr) >= p["attach_big_size"]]
            Cb0 = _unit(np.array([X[groups[gi]].mean(0) for gi in big0])) if big0 else None
            Db0 = 1.0 - _unit(X[poor_idx]) @ Cb0.T if big0 else None
            for i, idx in enumerate(poor_idx):
                if bd[i] < p["attach"]:
                    gi = int(lab[good_idx[best[i]]])
                    groups[gi].append(int(idx))
                elif big0 and Db0[i].min() < p["attach_big"]:
                    groups[big0[int(Db0[i].argmin())]].append(int(idx))
                else:
                    loose.append(int(idx))
        else:
            loose = [int(i) for i in poor_idx]
        # poor faces that fit no good face cluster among themselves: a poor face alone
        # is the weakest possible evidence, a small poor cluster already has a centre.
        if p["poor_auto"] > 0 and len(loose) >= 2:
            pl = fcluster(linkage(pdist(X[loose], "cosine"), "average"), p["poor_auto"], "distance")
            for u in np.unique(pl):
                groups.append([loose[i] for i in np.where(pl == u)[0]])
        else:
            groups.extend([i] for i in loose)

    big = [gr for gr in groups if len(gr) >= p["min_size"]]
    small = [gr for gr in groups if len(gr) < p["min_size"]]

    # graph evidence over all faces
    nbr, nd = _knn(X, k)
    src, dst, dd, snn = _edges(nbr, nd, k)

    # 3. merge two big groups only on several signals at once
    if len(big) > 1:
        ev_ = _group_pairs(lab, big, src, dst, dd, snn, p["graph_cap"], n)
        V = _votes(big, X, nbr, k)
        vote = np.maximum(V, V.T)
        C = _unit(np.array([X[gr].mean(0) for gr in big]))
        dc = 1.0 - C @ C.T
        iu = np.triu_indices(len(big), 1)
        good_pair = ((ev_["cnt"][iu] >= 1) & (ev_["snn"][iu] >= p["snn_min"])
                     & (dc[iu] < p["merge_dcent"]) & (vote[iu] >= p["vote_min"]))
        comp = _components(len(big), iu[0][good_pair], iu[1][good_pair])
        merged = {}
        for ci, gr in enumerate(big):
            merged.setdefault(int(comp[ci]), []).extend(gr)
        big = list(merged.values())

    # 4. small groups: attach when the evidence agrees, else fold into loose faces
    loose = []
    if small and big:
        C = _unit(np.array([X[gr].mean(0) for gr in big]))
        ev_big = [set(ev[gr].tolist()) for gr in big]
        tb_big = [_time_buckets(X, gr, tm, p["window"]) for gr in big]
        Vb = _votes(big + small, X, nbr, k)
        Vsb = Vb[len(big):, :len(big)]
        for si, sg in enumerate(small):
            d = 1.0 - C @ _unit(X[sg].mean(0))[0]
            if d.min() >= p["absorb_wide"] and p["face_close"] <= 0:
                loose.append(sg)
                continue
            j = int(d.argmin())
            ev_sg = set(ev[sg].tolist())
            share = len(ev_sg & ev_big[j]) > 0
            td = _time_distance(_time_buckets(X, sg, tm, p["window"]), tb_big[j])
            vote = float(Vsb[si, j])
            hints = int(share) + int(td < p["absorb_time"]) + int(vote >= p["ab_vote"])
            # every face of the small group close to the same big group is one more signal
            per_face = float(np.max(np.min(1.0 - X[sg] @ X[big[j]].T, axis=1)))
            ok = bool(d[j] < p["absorb"] or td < p["absorb_time"]
                      or (d[j] < p["absorb_wide"] and hints >= p["hint_need"])
                      or per_face < p["face_close"])
            if ok and not _shares_photo(media, big[j], sg):
                big[j].extend(sg)
            else:
                loose.append(sg)
    else:
        loose = list(small)

    # 4b. join leftover fragments of one identity, then give the joined fragment one more
    # chance to attach: a fragment of several faces has a real centre and a real neighbourhood.
    if len(loose) > 1 and big:
        C = _unit(np.array([X[gr].mean(0) for gr in loose]))
        Df = 1.0 - C @ C.T
        iu = np.triu_indices(len(loose), 1)
        pa, pb = [], []
        for a, b in zip(*iu):
            if Df[a, b] >= p["join_c"]:
                continue
            if 1.0 - float(np.max(X[loose[a]] @ X[loose[b]].T)) <= p["join_ds"]:
                pa.append(a)
                pb.append(b)
        comp = _components(len(loose), np.array(pa, int), np.array(pb, int))
        joined = {}
        for ci, gr in enumerate(loose):
            joined.setdefault(int(comp[ci]), []).extend(gr)
        loose = list(joined.values())
        Cb = _unit(np.array([X[gr].mean(0) for gr in big]))
        Vb = _votes(big + loose, X, nbr, k)
        Vsb = Vb[len(big):, :len(big)]
        keep = []
        for gi, gr in enumerate(loose):
            d = 1.0 - Cb @ _unit(X[gr].mean(0))[0]
            j = int(d.argmin())
            share = len(set(ev[gr].tolist()) & set(ev[big[j]].tolist())) > 0
            vote = float(Vsb[gi, j])
            hints = int(share) + int(vote >= p["ab_vote"])
            if (d[j] < p["absorb"] or (d[j] < p["absorb_wide"] and hints >= 2)) \
                    and not _shares_photo(media, big[j], gr):
                big[j].extend(gr)
            else:
                keep.append(gr)
        loose = keep

    # 4c. rescue: a loose group of >= rescue_min faces is one card + one question to its
    # nearest big group, so real people are not silently lost; a "yes" merges it for 0.3.
    rescue_q = []
    if p["rescue_min"] and loose and big:
        C = _unit(np.array([X[gr].mean(0) for gr in big]))
        keep = []
        for sg in loose:
            if len(sg) < p["rescue_min"]:
                keep.append(sg)
                continue
            d = 1.0 - C @ _unit(X[sg].mean(0))[0]
            bi = int(d.argmin())
            if _shares_photo(media, big[bi], sg):
                keep.append(sg)
                continue
            big.append(sg)
            rescue_q.append((float(d[bi]), len(big) - 1, bi))
        loose = keep

    # loose groups become the flat "loose faces" list
    folded = [f for gr in loose for f in gr]

    # 5. questions on the remaining cards, closest first (P5 rules)
    m = len(big)
    scored = []
    if m > 1:
        C = _unit(np.array([X[gr].mean(0) for gr in big]))
        D = 1.0 - C @ C.T
        np.fill_diagonal(D, 9.0)
        ev_big = [set(ev[gr].tolist()) for gr in big]
        tb_big = [_time_buckets(X, gr, tm, p["window"]) for gr in big]
        for i in range(m):
            for j in range(i + 1, m):
                dij = float(D[i, j])
                if dij > max(p["ask_centre"], p["ask_event"]):
                    continue
                share = len(ev_big[i] & ev_big[j]) > 0
                td = np.inf
                if dij >= p["ask_centre"]:
                    td = _time_distance(tb_big[i], tb_big[j])
                if dij >= p["ask_centre"] and not share and not td < p["ask_time"]:
                    continue
                if dij >= p["ask_event"] and not td < p["ask_time"]:
                    continue
                if _shares_photo(media, big[i], big[j]):
                    continue
                scored.append((min(dij, td), i, j))
    scored.sort()
    if rescue_q:
        rescue_q.sort()
        scored += [(d, i, j) for d, i, j in rescue_q]
    return dict(groups=big, questions=[(i, j) for _, i, j in scored], folded=folded)


# ------------------------------------------------------------------------ main
def _holdout():
    out = []
    for v1 in (False, True):
        rows = run_rows(plan, seeds=(30, 31, 32, 33, 34), v1=v1)
        out.append(report(rows, "route_f1 seeds 30-34 synth " + ("v1" if v1 else "v2")))
    return "\n\n".join(out)


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "refs":
        import route_p3
        import route_p5

        out = [
            report(run_rows(route_p5.plan), "route_p5 seeds 0-4"),
            report(run_rows(route_p3.plan), "route_p3 seeds 0-4"),
        ]
        text = "\n\n".join(out)
        print(text)
        with open("../out/references.txt", "w") as f:
            f.write(text + "\n")
    elif args and args[0] == "holdout":
        text = _holdout()
        print(text)
        with open("../out/holdout.txt", "w") as f:
            f.write(text + "\n")
    else:
        seeds = tuple(int(a) for a in args) or (0, 1, 2, 3, 4)
        t0 = time.time()
        rows = run_rows(plan, seeds=seeds)
        print(report(rows, f"route_f1 seeds {seeds}"))
        print(f"\n{time.time() - t0:.1f}s")
