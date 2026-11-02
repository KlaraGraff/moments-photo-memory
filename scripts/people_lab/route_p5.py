"""Route P5: use detection quality and the outing/time context as extra evidence.

Policy in words:
1. Only good faces (quality >= q_good) define groups: average-link clustering at `auto`.
2. A poor face joins the group of its nearest good face when that face is closer than `attach`
   (a poor embedding is noisy, so one close good face is better evidence than a group mean);
   otherwise the poor face starts a small group of its own.
3. A group with fewer than `min_size` faces is folded into "loose faces", unless a bigger group is
   a confident match: centre distance < `absorb`, or it shares an outing and its centre distance is
   < `absorb_event`, or it looks like it in the same year (time-wise distance < `absorb_time`).
   Then it is attached instead of folded. Faces from two groups that share a photo never merge.
4. The remaining groups are the cards. Pairs become "same person?" questions, closest first, when
   the centre distance is below `ask_centre`, when the two groups share an outing and sit below
   `ask_event`, or when their same-year looks are closer than `ask_time` (age drift between far
   apart years no longer hides one person).

Time-wise distance: faces are bucketed by `window` days; two buckets are compared by their mean
vector, weighted by the smaller bucket size. Nothing here reads the answer key; only score.py does.
"""
import numpy as np
from scipy.spatial.distance import pdist
from scipy.cluster.hierarchy import linkage, fcluster

DEFAULTS = dict(
    q_good=0.45,        # faces at least this good define the groups
    auto=0.62,          # average-link cut on the good faces
    attach=0.55,        # poor face -> group of its nearest good face
    min_size=3,         # groups this big are cards, smaller ones are loose faces
    absorb=0.55,        # small group -> big group by centre distance
    absorb_event=0.70,  # ... or when it shares an outing
    absorb_time=0.62,   # ... or when its same-year look matches
    ask_centre=0.70,    # question: centre distance below this
    ask_event=0.78,     # question: shares an outing and centre distance below this
    ask_time=0.62,      # question: same-year look distance below this
    window=365.0,       # days per time bucket
)


def _unit(v):
    v = np.asarray(v, dtype=float)
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-12)


def _centre(X, idx):
    return _unit(X[idx].mean(0))


def _shares_photo(media, ga, gb):
    return len(set(media[ga].tolist()) & set(media[gb].tolist())) > 0


def _time_buckets(X, idx, tm, window):
    """{bucket: (mean unit vector, n faces)} for the faces of one group."""
    idx = np.asarray(idx)
    b = (tm[idx] // window).astype(int)
    out = {}
    for k in np.unique(b):
        m = idx[b == k]
        out[int(k)] = (_unit(X[m].mean(0)), len(m))
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


def plan(L, **params):
    p = dict(DEFAULTS)
    p.update(params)
    X = np.asarray(L["X"], dtype=float)
    q = np.asarray(L["quality"])
    ev = np.asarray(L["event"])
    tm = np.asarray(L["time"])
    media = np.asarray(L["media"])

    good_idx = np.where(q >= p["q_good"])[0]
    poor_idx = np.where(q < p["q_good"])[0]

    groups = []
    if len(good_idx) >= 2:
        lab = fcluster(linkage(pdist(X[good_idx], "cosine"), "average"), p["auto"], "distance")
        groups = [good_idx[lab == k].tolist() for k in np.unique(lab)]
    elif len(good_idx) == 1:
        groups = [good_idx.tolist()]

    # 2. poor faces attach to the group holding their nearest good face, or stand alone
    if len(poor_idx):
        if groups:
            labels = np.array([-1] * len(X))
            for gi, g in enumerate(groups):
                labels[g] = gi
            U = _unit(X[good_idx])
            D = 1.0 - _unit(X[poor_idx]) @ U.T
            best = D.argmin(1)
            bd = D[np.arange(len(poor_idx)), best]
            for i, idx in enumerate(poor_idx):
                if bd[i] < p["attach"]:
                    groups[int(labels[good_idx[best[i]]])].append(int(idx))
                else:
                    groups.append([int(idx)])
        else:
            groups = [[int(i)] for i in poor_idx]

    # 3. small groups: attach to a confident bigger group, or fold away
    big = [list(g) for g in groups if len(g) >= p["min_size"]]
    small = [list(g) for g in groups if len(g) < p["min_size"]]
    folded = []
    if small and big:
        C = _unit(np.array([X[g].mean(0) for g in big]))
        ev_big = [set(ev[g].tolist()) for g in big]
        tb_big = [_time_buckets(X, g, tm, p["window"]) for g in big]
        for sg in small:
            d = 1.0 - C @ _centre(X, sg)
            share = np.array([len(set(ev[sg].tolist()) & e) > 0 for e in ev_big])
            tb = _time_buckets(X, sg, tm, p["window"])
            td = np.array([_time_distance(tb, t) for t in tb_big])
            ok = (d < p["absorb"]) | (share & (d < p["absorb_event"])) | (td < p["absorb_time"])
            if ok.any():
                cand = np.where(ok)[0]
                j = int(cand[np.argmin(d[cand])])
                if not _shares_photo(media, big[j], sg):
                    big[j].extend(sg)
                    continue
            folded.extend(sg)

    # 4. questions on the remaining cards, closest first
    m = len(big)
    scored = []
    if m > 1:
        C = _unit(np.array([X[g].mean(0) for g in big]))
        D = 1.0 - C @ C.T
        np.fill_diagonal(D, 9.0)
        ev_big = [set(ev[g].tolist()) for g in big]
        tb_big = [_time_buckets(X, g, tm, p["window"]) for g in big]
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
    return dict(groups=big, questions=[(i, j) for _, i, j in scored], folded=folded)


if __name__ == "__main__":
    from score import run, table
    print(table(run(plan)))
