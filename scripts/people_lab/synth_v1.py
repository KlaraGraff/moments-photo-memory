"""Synthetic face-embedding libraries that mimic SFace (128-d, cosine distance) on a family photo library.
No real faces: identities are random unit vectors. Calibrated to aggregate numbers from the owner's library
(within-group distance to centre median ~0.25, p90 ~0.41; same person split into sub-groups ~0.67-0.69 apart;
two different main people ~0.92 apart; many strangers with 1-2 faces; burst duplicates 0.01-0.06 apart).
Usage: make_library(seed, n_faces) -> dict with arrays X (n,128 unit), person (n,) [ANSWER KEY: a policy must not read it],\nmedia (n,) photo id, time (n,) days, quality (n,) 0.25-1 detector capture quality, event (n,) outing id.\nEach face is its own photo except that two faces never share a photo here (the app already splits same-photo faces).\nLooks drift with age (time), a few faces per person are far outliers (profile/blur), some people are look-alikes (family)."""
import numpy as np

DIM = 128

def _unit(v):
    return v / np.linalg.norm(v, axis=-1, keepdims=True)

def _towards(c, dist, rng):
    """unit vector at cosine distance ~dist from unit vector c"""
    r = rng.normal(size=c.shape); r -= (r @ c) * c; r = _unit(r)
    cos = 1 - dist
    return _unit(cos * c + np.sqrt(max(1 - cos * cos, 0)) * r)

def make_library(seed=0, n_faces=1200, hard_negative_rate=0.15, outlier_rate=0.04, stranger_share=0.05):
    rng = np.random.default_rng(seed)
    # people: 2 main (owner couple), ~8 frequent, ~25 occasional, many strangers
    sizes = [int(n_faces * 0.33), int(n_faces * 0.25)]
    sizes += list(rng.integers(15, 60, 8))
    sizes += list(rng.integers(3, 12, 25))
    target_named = int(n_faces * (1 - stranger_share))
    sizes = [max(1, int(s * target_named / sum(sizes))) for s in sizes]
    while sum(sizes) < n_faces:
        sizes.append(int(rng.choice([1, 1, 1, 2, 2, 3])))
    centres = []
    for p in range(len(sizes)):
        if centres and rng.random() < hard_negative_rate:
            # family member / look-alike: 0.55-0.75 from someone else
            base = centres[rng.integers(len(centres))]
            centres.append(_towards(base, rng.uniform(0.55, 0.75), rng))
        else:
            centres.append(_unit(rng.normal(size=DIM)))
    X, person, media, time, quality, event = [], [], [], [], [], []
    n_events = max(n_faces // 12, 10)
    event_time = np.sort(rng.uniform(0, 3650, n_events))  # days over ten years
    media_id = 0
    for p, n in enumerate(sizes):
        # sub-modes: age, glasses, pose. Big people get more modes and age drift.
        n_modes = 1 if n < 5 else int(rng.integers(2, 5 if n < 60 else 8))
        modes = [_towards(centres[p], rng.uniform(0.18, 0.34), rng) for _ in range(n_modes)]
        # events this person appears at: main people many, occasional few, strangers one
        k = n_events if n > 150 else max(1, min(n_events, int(np.ceil(n / rng.uniform(3, 8)))))
        my_events = rng.choice(n_events, size=min(k, n_events), replace=False)
        made = 0
        while made < n:
            ev = int(rng.choice(my_events))
            # look drifts with age: the mode mostly follows time; sometimes glasses/pose pick another
            mi = int(event_time[ev] / 3650 * n_modes) if rng.random() < 0.7 else int(rng.integers(n_modes))
            m = modes[min(mi, n_modes - 1)]
            q = float(np.clip(rng.beta(4, 3), 0.25, 1.0))
            spread = 0.07 + 0.22 * (1 - q)          # low quality -> noisier embedding
            burst = 1 if rng.random() > 0.15 else int(rng.integers(2, 5))
            if rng.random() < outlier_rate:   # profile, blur, odd light: far from the usual look
                v0 = _towards(centres[p], rng.uniform(0.45, 0.75), rng)
            else:
                v0 = _towards(m, rng.uniform(0.6, 1.4) * spread, rng)
            for b in range(min(burst, n - made)):
                v = v0 if b == 0 else _towards(v0, rng.uniform(0.01, 0.06), rng)
                X.append(v); person.append(p); media.append(media_id); media_id += 1
                time.append(event_time[ev] + rng.uniform(0, 0.2)); quality.append(q); event.append(ev)
                made += 1
    X = np.array(X); order = rng.permutation(len(X))
    return dict(X=X[order], person=np.array(person)[order], media=np.array(media)[order],
                time=np.array(time)[order], quality=np.array(quality)[order], event=np.array(event)[order])

if __name__ == "__main__":
    from scipy.spatial.distance import pdist
    from scipy.cluster.hierarchy import linkage, fcluster
    L = make_library(0, 1134)
    X, y = L["X"], L["person"]
    print("faces", len(X), "people", len(set(y)), "people with >=3 faces", sum(np.bincount(y) >= 3))
    for t in [0.55, 0.65, 0.7, 0.75]:
        g = fcluster(linkage(pdist(X, "cosine"), "average"), t, "distance")
        c = np.bincount(g)[1:]
        print(f"average {t}: groups {len(c)}, singletons {(c == 1).sum()}, biggest {sorted(c)[-4:][::-1]}")
    big = [p for p in set(y) if (y == p).sum() > 20]
    for p in big[:3]:
        V = X[y == p]; m = _unit(V.mean(0)); d = 1 - V @ m
        print(f"person {p} n={len(V)} dist-to-centre p50 {np.median(d):.3f} p90 {np.percentile(d, 90):.3f}")
