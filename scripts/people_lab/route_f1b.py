"""Route F1 - fuse P5 (quality gating + outing/time context) with P3 (kNN evidence graph).

Policy in about six sentences:
 1. Only good faces (quality >= 0.45) define base groups (average-link at cosine 0.62); a poor face joins the
    group of its nearest good face when that face is closer than 0.55 and 2 of its 3 nearest good faces agree,
    otherwise it starts a 1-face group.
 2. Base groups merge only on graph evidence: at least one mutual-kNN edge under 0.55, shared near neighbours
    (SNN >= 4) and centre distance < 0.68, so one weak signal never joins two big groups.
 3. 1-2 face groups join each other only when both centre (0.42) and single link (0.40) are very tight; a joined
    group of 3+ faces is first offered to the attach rules of step 4 and only becomes a card if it does not fit.
 4. Small groups attach to a big group on P5's context rules (centre < 0.55, shared outing < 0.62, same-year look
    < 0.62) or on P3's graph vote (single link <= 0.58, vote share >= 0.45, mean vote distance <= 0.64, 0.03
    margin over the runner-up); everything else folds into "loose faces".
 5. The remaining cards get P5's "same person?" questions, closest first (centre < 0.67, shared outing < 0.78,
    same-year look < 0.62), skipping cards that share a photo.

Run:  python3 route_f1.py           # final table, seeds 0-4, worst seeds per row
      python3 route_f1.py refs      # P5 / P3 reference tables
      python3 route_f1.py holdout   # seeds 30-34, synth v2 and synth v1
Only `score.evaluate` reads the identity labels; this policy never touches them.
"""
import os
import sys
import time

import numpy as np
from scipy.cluster.hierarchy import fcluster, linkage
from scipy.spatial.distance import pdist


# ---------------------------------------------------------------- reporting helper
def worst_table(rows):
    """Mean table plus the worst seed per row for wrong_faces and lost_faces."""
    cols = ["name_cards", "questions", "effort", "wrong_faces", "lost_faces", "extra_cards"]
    out = ["library | " + " | ".join(cols) + " | worst wrong_faces | worst lost_faces"]
    for key in sorted({(r["variant"], r["n"]) for r in rows}):
        rs = [r for r in rows if (r["variant"], r["n"]) == key]
        mean = {c: round(float(np.mean([r[c] for r in rs])), 1) for c in cols}
        wf = max(rs, key=lambda r: r["wrong_faces"])
        lf = max(rs, key=lambda r: r["lost_faces"])
        out.append(f"{key[0]}-{key[1]} | " + " | ".join(str(mean[c]) for c in cols)
                   + f" | {wf['wrong_faces']} (seed {wf['seed']}) | {lf['lost_faces']} (seed {lf['seed']})")
    return "\n".join(out)


def tables(policy, seeds=(0, 1, 2, 3, 4), sizes=(1134, 5000),
           variants=("calibrated", "hard"), label="", module=None, out=None):
    """score.run printed as mean table + worst seeds; `module` swaps in another synth generator."""
    import score
    old = None
    if module is not None:
        old = sys.modules.get("synth")
        sys.modules["synth"] = module
    try:
        t0 = time.time()
        rows = score.run(policy, seeds=seeds, sizes=sizes, variants=variants)
    finally:
        if module is not None:
            sys.modules["synth"] = old
    text = (f"\n== {label} seeds {tuple(seeds)} ==\n" if label else "") + worst_table(rows)
    text += f"\n({time.time() - t0:.1f}s)"
    print(text)
    if out:
        here = os.path.dirname(os.path.abspath(__file__))
        path = os.path.join(here, "..", out)
        with open(path, "a") as f:
            f.write(text + "\n")
    return rows


# ------------------------------------------------------------------ graph helpers
def _unit(M):
    M = np.atleast_2d(np.asarray(M, dtype=float))
    return M / np.maximum(np.linalg.norm(M, axis=-1, keepdims=True), 1e-12)


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
        snn += (A == B[:, t:t + 1]).any(1)
    sel = (src < dst) & mutual
    return src[sel], dst[sel], dd[sel], snn[sel]


def _cluster_pairs(lab, src, dst, dd, snn, cap, ncl):
    """Per cluster pair: number of mutual edges under `cap` and their largest SNN."""
    a, b = lab[src], lab[dst]
    sel = (a != b) & (dd <= cap)
    if not sel.any():
        z = np.zeros(0, np.int64)
        return z, z, np.zeros(0, np.int64), np.zeros(0, np.int32)
    a, b, snn = a[sel], b[sel], snn[sel]
    key = np.minimum(a, b).astype(np.int64) * ncl + np.maximum(a, b)
    key, inv = np.unique(key, return_inverse=True)
    cnt = np.bincount(inv, minlength=len(key))
    maxs = np.zeros(len(key), np.int32)
    np.maximum.at(maxs, inv, snn)
    return key // ncl, key % ncl, cnt, maxs


def _components(n, a, b):
    """Connected components (n nodes) of an undirected edge list."""
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


def _centres(X, groups):
    return _unit(np.array([X[g].mean(0) for g in groups]))


def _centre(X, idx):
    return _unit(X[np.asarray(idx)].mean(0))[0]


def _time_buckets(X, idx, tm, window):
    """{bucket: (mean unit vector, n faces)} for the faces of one group."""
    idx = np.asarray(idx)
    b = (tm[idx] // window).astype(int)
    out = {}
    for k in np.unique(b):
        m = idx[b == k]
        out[int(k)] = (_unit(X[m].mean(0))[0], len(m))
    return out


def _time_distance(A, B):
    """Mean distance of the buckets two groups have in common, weighted by the smaller bucket."""
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


def _shares_photo(media, ga, gb):
    return len(set(media[ga].tolist()) & set(media[gb].tolist())) > 0


# ---------------------------------------------------------------------- parameters
DEFAULTS = dict(
    q_good=0.45, auto=0.62, attach=0.55, poor_votes=3, poor_agree=2, min_size=3,
    k=15, cap=0.55, snn_min=4, cross_min=1, merge_dcent=0.68,
    ss_centre=0.42, ss_single=0.40, join_card="promote",
    ab_dmin=0.58, ab_share=0.45, ab_md=0.64, ab_margin=0.03,
    absorb=0.55, absorb_event=0.62, absorb_time=0.62,
    ask_centre=0.67, ask_event=0.78, ask_time=0.62, window=365.0,
)


# --------------------------------------------------------------------------- policy
def plan(L, **params):
    p = dict(DEFAULTS)
    p.update(params)
    X = np.asarray(L["X"], dtype=float)
    q = np.asarray(L["quality"], dtype=float)
    ev = np.asarray(L["event"])
    tm = np.asarray(L["time"])
    media = np.asarray(L["media"])
    n = len(X)

    good_idx = np.where(q >= p["q_good"])[0]
    poor_idx = np.where(q < p["q_good"])[0]

    # 1. good faces define base groups
    groups = []
    if len(good_idx) >= 2:
        lab = fcluster(linkage(pdist(X[good_idx], "cosine"), "average"), p["auto"], "distance")
        groups = [good_idx[lab == k].tolist() for k in np.unique(lab)]
    elif len(good_idx) == 1:
        groups = [good_idx.tolist()]
    base_groups = [list(g) for g in groups]

    # the kNN graph is needed for merges and for the small-group votes
    nbr, nd = _knn(X, p["k"])
    src, dst, dd, snn = _edges(nbr, nd, p["k"])
    gid = -np.ones(n, np.int32)
    for gi, g in enumerate(base_groups):
        gid[g] = gi
    nb = len(base_groups)

    # 2. merge base groups on kNN-graph evidence (mutual edge + shared neighbours + centre distance)
    if nb > 1:
        ca, cb, cnt, maxs = _cluster_pairs(gid, src, dst, dd, snn, p["cap"], nb)
        C0 = _centres(X, base_groups)
        dcent = 1.0 - np.sum(C0[ca] * C0[cb], axis=1) if len(ca) else np.zeros(0)
        ok = (cnt >= p["cross_min"]) & (maxs >= p["snn_min"]) & (dcent < p["merge_dcent"])
        comp = _components(nb, ca[ok], cb[ok])
        merged = {}
        for c in range(nb):
            merged.setdefault(int(comp[c]), []).extend(base_groups[c])
        groups = list(merged.values())

    # 3. poor faces attach to the group of their nearest good face, or stand alone
    if len(poor_idx) and groups:
        labels = -np.ones(n, np.int32)
        for gi, g in enumerate(groups):
            labels[g] = gi
        U = _unit(X[good_idx])
        D = 1.0 - _unit(X[poor_idx]) @ U.T
        best = D.argmin(1)
        bd = D[np.arange(len(poor_idx)), best]
        # the m nearest good faces must agree on the group (a look-alike sits next to a stranger's face)
        m = int(min(p["poor_votes"], len(good_idx)))
        near = np.argsort(D, axis=1)[:, :m]
        near_g = labels[good_idx[near]]
        agree = np.array([np.bincount(r[r >= 0], minlength=len(groups)).max() if (r >= 0).any() else 0
                          for r in near_g])
        for i, idx in enumerate(poor_idx):
            g1 = int(labels[good_idx[best[i]]])
            if bd[i] < p["attach"] and agree[i] >= p["poor_agree"]:
                groups[g1].append(int(idx))
            else:
                groups.append([int(idx)])
    elif len(poor_idx):
        groups = [[int(i)] for i in poor_idx]

    # 4. small groups: join each other when very tight, else attach on P5 rules OR P3 kNN votes
    big = [list(g) for g in groups if len(g) >= p["min_size"]]
    small = [list(g) for g in groups if len(g) < p["min_size"]]

    if len(small) > 1:
        C = _centres(X, small)
        D = 1.0 - C @ C.T
        iu = np.triu_indices(len(small), 1)
        keep = []
        for a, b in zip(iu[0][D[iu] < p["ss_centre"]], iu[1][D[iu] < p["ss_centre"]]):
            if 1.0 - float(np.max(X[small[a]] @ X[small[b]].T)) <= p["ss_single"]:
                keep.append((a, b))
        if keep:
            comp = _components(len(small), [a for a, b in keep], [b for a, b in keep])
            joined = {}
            for c, gr in enumerate(small):
                joined.setdefault(int(comp[c]), []).extend(gr)
            rest = []
            for gr in joined.values():
                if len(gr) >= p["min_size"] and p["join_card"] == "card":
                    big.append(gr)
                else:
                    rest.append(gr)
            small = rest

    folded = []
    if small and big:
        C = _centres(X, big)
        ev_big = [set(ev[g].tolist()) for g in big]
        tb_big = [_time_buckets(X, g, tm, p["window"]) for g in big]
        owner = -np.ones(nb, np.int32)
        for bi, gr in enumerate(big):
            for f in gr:
                bc = gid[f]
                if bc >= 0 and owner[bc] < 0:
                    owner[bc] = bi
        n2b = owner[gid]
        for sg in small:
            d = 1.0 - C @ _centre(X, sg)
            share = np.array([len(set(ev[sg].tolist()) & e) > 0 for e in ev_big])
            tb = _time_buckets(X, sg, tm, p["window"])
            td = np.array([_time_distance(tb, t) for t in tb_big])
            ok = (d < p["absorb"]) | (share & (d < p["absorb_event"])) | (td < p["absorb_time"])
            target = -1
            if ok.any():
                cand = np.where(ok)[0]
                target = int(cand[np.argmin(d[cand])])
            if target < 0:
                # P3 vote rule: kNN neighbours of the small group's faces vote for big groups
                votes = np.zeros(len(big))
                dsum = np.zeros(len(big))
                for f in sg:
                    ob = n2b[nbr[f]]
                    for b in np.unique(ob[ob >= 0]):
                        m = ob == b
                        votes[b] += float(m.sum())
                        dsum[b] += float(nd[f][m].sum())
                if votes.max() > 0:
                    b = int(votes.argmax())
                    share_v = votes[b] / (p["k"] * len(sg))
                    md = dsum[b] / max(votes[b], 1)
                    per = np.array([(1.0 - X[sg] @ X[bg].T).min() for bg in big])
                    order = np.sort(per)
                    margin = float(order[1] - order[0]) if len(order) > 1 else 9.0
                    if (per[b] <= p["ab_dmin"] and share_v >= p["ab_share"]
                            and md <= p["ab_md"] and margin >= p["ab_margin"]):
                        target = b
            if target >= 0 and not _shares_photo(media, big[target], sg):
                big[target].extend(sg)
            elif len(sg) >= p["min_size"] and p["join_card"] == "promote":
                big.append(list(sg))
            else:
                folded.extend(sg)
    elif small:
        folded = [f for gr in small for f in gr]

    # 5. P5 questions on the remaining cards, closest first
    m = len(big)
    scored = []
    if m > 1:
        C = _centres(X, big)
        D = 1.0 - C @ C.T
        np.fill_diagonal(D, 9.0)
        ev_big = [set(ev[g].tolist()) for g in big]
        tb_big = [_time_buckets(X, g, tm, p["window"]) for g in big]
        for i in range(m):
            for j in range(i + 1, m):
                dij = float(D[i, j])
                if dij > max(p["ask_centre"], p["ask_event"]):
                    continue
                share_i = len(ev_big[i] & ev_big[j]) > 0
                td = np.inf
                if dij >= p["ask_centre"]:
                    td = _time_distance(tb_big[i], tb_big[j])
                if dij >= p["ask_centre"] and not share_i and not td < p["ask_time"]:
                    continue
                if dij >= p["ask_event"] and not td < p["ask_time"]:
                    continue
                if _shares_photo(media, big[i], big[j]):
                    continue
                scored.append((min(dij, td), i, j))
        # optional extra pairs that the kNN graph links strongly but the centre is far (off by default: no effect)
        if p.get("ask_sl", 1.0) < 1.0:
            flat = np.concatenate(big)
            starts = np.cumsum([0] + [len(g) for g in big])
            gidx = np.repeat(np.arange(m), [len(g) for g in big])
            have = {(min(a, b), max(a, b)) for _, a, b in scored}
            for i in range(m):
                S = X[big[i]] @ X[flat].T
                best = np.max(S[:, gidx != i], axis=1) if m > 1 else np.zeros(len(big[i]))
                sl = 1.0 - float(best.max()) if len(best) else 9.0
                if sl > p["ask_sl"]:
                    continue
                # which group holds the closest face
                j = int(np.argmax(best))
                j = int(gidx[np.flatnonzero(gidx != i)[j]])
                if j <= i or D[i, j] > p["ask_sl_centre"]:
                    continue
                if (i, j) in have or _shares_photo(media, big[i], big[j]):
                    continue
                scored.append((sl, i, j))
                have.add((i, j))
    scored.sort()
    return dict(groups=big, questions=[(i, j) for _, i, j in scored], folded=folded)


# ---------------------------------------------------------------------------- main
FINAL = dict(DEFAULTS)

if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "final"
    if what == "refs":
        import route_p3
        import route_p5
        tables(lambda L: route_p5.plan(L), label="route_p5", out="out/references.txt")
        tables(lambda L: route_p3.plan(L, **route_p3.FINAL), label="route_p3", out="out/references.txt")
    elif what == "holdout":
        import synth_v1
        tables(lambda L: plan(L, **FINAL), seeds=(30, 31, 32, 33, 34), label="F1 v2", out="out/holdout.txt")
        tables(lambda L: plan(L, **FINAL), seeds=(30, 31, 32, 33, 34), label="F1 v1",
               module=synth_v1, out="out/holdout.txt")
    else:
        tables(lambda L: plan(L, **FINAL), seeds=(0, 1, 2, 3, 4), label="F1 final")
