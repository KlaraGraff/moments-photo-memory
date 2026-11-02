"""The app's rule today (simplified): average-link at 0.65 over all unnamed faces, every group is a card."""
import numpy as np
from scipy.spatial.distance import pdist
from scipy.cluster.hierarchy import linkage, fcluster

def plan(L):
    g = fcluster(linkage(pdist(L["X"], "cosine"), "average"), 0.65, "distance")
    groups = [list(np.where(g == k)[0]) for k in np.unique(g)]
    return dict(groups=groups, questions=[], folded=[])

if __name__ == "__main__":
    from score import run, table
    print(table(run(plan)))
