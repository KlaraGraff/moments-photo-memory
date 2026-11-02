"""Route P3 - kNN-graph people grouping (mutual-kNN merges, rank-order evidence, questions).

Policy in a few sentences:
  1. Build a cosine k-nearest-neighbour graph over all faces (k = 15); keep every pair's shared-neighbour
     count (SNN) and whether the edge is mutual.
  2. Start from average-link clusters at a conservative cosine threshold (0.62).  These are pure but a
     person is often split into several sub-groups (age, glasses, pose, outliers).
  3. Merge base groups the graph links strongly: at least one mutual edge under a distance cap, enough
     shared near neighbours and close centres.  A person's sub-modes touch through boundary faces and share
     a neighbourhood; two look-alikes are separate islands, so they stay apart.
  4. 1-2 face groups are not asked about (product rule).  They are merged with each other when their
     centres are almost identical, and attached to a big group only when the kNN vote is clear and close;
     everything else folds into "loose faces".
  5. Ask "same person?" about the remaining close group pairs, closest first: a yes costs 0.3 of a name and
     saves a whole card.

Usage:  python3 route_p3.py                  # final parameters, seeds 0-4
        python3 route_p3.py 10 11 12 13 14   # any seed list
Only `score.evaluate` reads the identity labels; this policy never touches them.
"""
import sys
import time

import numpy as np
from scipy.cluster.hierarchy import fcluster, linkage
from scipy.spatial.distance import pdist


# ---------------------------------------------------------------- graph helpers
def _unit(M):
    return M / np.linalg.norm(M, axis=-1, keepdims=True)


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


# ---------------------------------------------------------------------- policy
def plan(L, k=15, base=0.62, cap=0.55, snn_min=4, cross_min=1, merge_dcent=0.72,
         ask=0.70, min_size=3,
         ss_centre=0.50, ab_dmin=0.60, ab_share=0.40, ab_md=0.64, ab_margin=0.0):
    X = L["X"]
    n = len(X)

    # 1. conservatively pure base clusters
    Z = linkage(pdist(X, "cosine"), "average")
    g = fcluster(Z, base, "distance")
    lab = g - 1
    base_groups = [list(np.where(lab == c)[0]) for c in range(lab.max() + 1)]
    nb = len(base_groups)

    # 2. merge base clusters that the kNN graph links strongly
    nbr, nd = _knn(X, k)
    src, dst, dd, snn = _edges(nbr, nd, k)
    ca, cb, cnt, maxs = _cluster_pairs(lab, src, dst, dd, snn, cap, nb)
    C0 = _centres(X, base_groups)
    dcent = 1.0 - np.sum(C0[ca] * C0[cb], axis=1) if len(ca) else np.zeros(0)
    good = (cnt >= cross_min) & (maxs >= snn_min) & (dcent < merge_dcent)
    comp = _components(nb, ca[good], cb[good])
    merged = {}
    for c in range(nb):
        merged.setdefault(int(comp[c]), []).extend(base_groups[c])
    groups = list(merged.values())

    big = [gr for gr in groups if len(gr) >= min_size]
    small = [gr for gr in groups if len(gr) < min_size]

    # 3. merge 1-2 face groups with each other (same person split across sub-modes)
    if len(small) > 1:
        C = _centres(X, small)
        D = 1 - C @ C.T
        iu = np.triu_indices(len(small), 1)
        pa, pb = iu[0][D[iu] < ss_centre], iu[1][D[iu] < ss_centre]
        comp = _components(len(small), pa, pb)
        joined = {}
        for c, gr in enumerate(small):
            joined.setdefault(int(comp[c]), []).extend(gr)
        small = list(joined.values())
        for gr in list(small):
            if len(gr) >= min_size:
                big.append(gr)
                small.remove(gr)

    # 4. attach or fold the remaining 1-2 face groups
    folded = []
    if big:
        C = _centres(X, big)
        # which big group owns the base cluster of each face
        owner = -1 * np.ones(nb, np.int32)
        for bi, gr in enumerate(big):
            for f in gr:
                bc = lab[f]
                if owner[bc] < 0:
                    owner[bc] = bi
        n2b = owner[lab]
        for gr in small:
            votes = np.zeros(len(big))
            dsum = np.zeros(len(big))
            for f in gr:
                ob = n2b[nbr[f]]
                for b in np.unique(ob[ob >= 0]):
                    m = ob == b
                    votes[b] += float(m.sum())
                    dsum[b] += float(nd[f][m].sum())
            if votes.max() == 0:
                folded += gr
                continue
            b = int(votes.argmax())
            share = votes[b] / (k * len(gr))
            md = dsum[b] / max(votes[b], 1)
            per = np.array([(1 - X[gr] @ X[bg].T).min() for bg in big])
            order = np.sort(per)
            margin = float(order[1] - order[0]) if len(order) > 1 else 9.0
            if per[b] <= ab_dmin and share >= ab_share and md <= ab_md and margin >= ab_margin:
                big[b] = big[b] + gr
            else:
                folded += gr
    else:
        folded = [f for gr in small for f in gr]

    # 5. ask about close big-group pairs, closest first
    C = _centres(X, big) if big else np.zeros((0, X.shape[1]))
    pairs = []
    for i in range(len(big)):
        for j in range(i + 1, len(big)):
            d = 1 - C[i] @ C[j]
            if d < ask:
                pairs.append((d, i, j))
    pairs.sort()
    return dict(groups=big, questions=[(i, j) for _, i, j in pairs], folded=folded)


# ------------------------------------------------------------------------ main
FINAL = dict(k=15, base=0.62, cap=0.55, snn_min=4, cross_min=1, merge_dcent=0.72,
             ask=0.70, min_size=3, ss_centre=0.50,
             ab_dmin=0.60, ab_share=0.40, ab_md=0.64, ab_margin=0.0)


if __name__ == "__main__":
    from score import run, table

    seeds = tuple(int(a) for a in sys.argv[1:]) or (0, 1, 2, 3, 4)
    t0 = time.time()
    rows = run(lambda L: plan(L, **FINAL), seeds=seeds)
    print(table(rows))
    print(f"\nseeds {seeds}  {time.time() - t0:.1f}s")
