"""Starting point for the chosen design: auto-merge < 0.65, ask once for groups 0.65-0.75 apart (centre distance),
fold groups with 1-2 faces unless they sit < 0.55 from a big group's centre (then join it)."""
import numpy as np
from scipy.spatial.distance import pdist
from scipy.cluster.hierarchy import linkage, fcluster

def plan(L, auto=0.65, ask=0.75, absorb=0.55, min_size=3):
    X = L["X"]
    g = fcluster(linkage(pdist(X, "cosine"), "average"), auto, "distance")
    groups = [list(np.where(g == k)[0]) for k in np.unique(g)]
    big = [gr for gr in groups if len(gr) >= min_size]
    small = [gr for gr in groups if len(gr) < min_size]
    unit = lambda v: v / np.linalg.norm(v)
    C = np.array([unit(X[gr].mean(0)) for gr in big]) if big else np.zeros((0, X.shape[1]))
    folded = []
    for gr in small:
        if len(C):
            d = 1 - C @ unit(X[gr].mean(0)); j = int(d.argmin())
            if d[j] < absorb: big[j] = big[j] + gr; continue
        folded += gr
    C = np.array([unit(X[gr].mean(0)) for gr in big]) if big else C
    pairs = []
    for i in range(len(big)):
        for j in range(i + 1, len(big)):
            d = 1 - C[i] @ C[j]
            if d < ask: pairs.append((d, i, j))
    pairs.sort()
    return dict(groups=big, questions=[(i, j) for _, i, j in pairs], folded=folded)

if __name__ == "__main__":
    from score import run, table
    print(table(run(plan)))
