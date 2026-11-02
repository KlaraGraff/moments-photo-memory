"""Scores a people-grouping policy by how much work it leaves the owner and how many mistakes it makes.

A policy is a function plan(L) -> dict:
  groups:    list of lists of face indices. Each group is one card the owner names (if it has >= 1 face and is not folded).
  questions: list of (group_a, group_b) index pairs, asked in order: "are these the same person?" shown as one
             representative photo each. A truthful owner answers yes iff the majority person of both groups is the same;
             a yes merges the two groups (later questions see merged groups).
  folded:    list of face indices put in "loose faces" (never asked about).
Every face must appear exactly once in groups or folded.

The simulated owner names every remaining group. Naming two groups of the same person costs one name each, and the
app's same-name merge joins them afterwards (that is the pain being fixed: it is still a card to name).
Metrics (lower is better unless noted):
  name_cards     cards the owner has to name (groups left after questions)
  questions      yes/no questions asked
  effort         name_cards + 0.3 * questions   (typing a name ~ 3x a yes/no tap)
  wrong_faces    faces sitting in a group whose majority is another person (silent mistakes; must stay tiny)
  lost_faces     faces of people with >= 3 faces that were folded away
  extra_cards    name_cards - number of distinct majority people among them (cards wasted on duplicates)
"""
import numpy as np, collections

def evaluate(L, plan):
    y = L["person"]; n = len(y)
    groups = [list(g) for g in plan["groups"] if len(g)]
    folded = list(plan.get("folded", []))
    seen = collections.Counter([i for g in groups for i in g] + folded)
    assert len(seen) == n and max(seen.values()) == 1, "every face exactly once"
    maj = lambda g: collections.Counter(y[g].tolist()).most_common(1)[0][0]
    parent = list(range(len(groups)))
    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]; a = parent[a]
        return a
    members = {i: list(g) for i, g in enumerate(groups)}
    q = 0
    for a, b in plan.get("questions", []):
        ra, rb = find(a), find(b)
        if ra == rb: continue
        q += 1
        if maj(members[ra]) == maj(members[rb]):
            parent[rb] = ra; members[ra] += members.pop(rb)
    final = list(members.values())
    wrong = sum(len(g) - collections.Counter(y[g].tolist()).most_common(1)[0][1] for g in final)
    big_people = {p for p, c in collections.Counter(y.tolist()).items() if c >= 3}
    lost = sum(1 for i in folded if y[i] in big_people)
    people_shown = len({maj(g) for g in final})
    return dict(name_cards=len(final), questions=q, effort=round(len(final) + 0.3 * q, 1),
                wrong_faces=wrong, lost_faces=lost, extra_cards=len(final) - people_shown,
                people_with_3plus=len(big_people))

VARIANTS = {
    # calibrated to the owner's library at threshold 0.65 (~122 groups for 1134 faces)
    "calibrated": dict(outlier_rate=0.04, stranger_share=0.05, hard_negative_rate=0.15),
    # harder: more outliers, more strangers, more look-alike family members
    "hard": dict(outlier_rate=0.07, stranger_share=0.10, hard_negative_rate=0.30),
}

def run(policy, seeds=(0, 1, 2, 3, 4), sizes=(1134, 5000), variants=("calibrated", "hard")):
    from synth import make_library
    rows = []
    for v in variants:
        for n in sizes:
            for s in seeds:
                L = make_library(s, n, **VARIANTS[v])
                rows.append(dict(variant=v, n=n, seed=s, **evaluate(L, policy(L))))
    return rows

def summary(rows):
    out = {}
    for key in sorted({(r["variant"], r["n"]) for r in rows}):
        rs = [r for r in rows if (r["variant"], r["n"]) == key]
        out[f"{key[0]}-{key[1]}"] = {k: round(float(np.mean([r[k] for r in rs])), 1) for k in rs[0] if k not in ("variant", "n", "seed")}
    return out

def table(rows):
    s = summary(rows)
    cols = ["name_cards", "questions", "effort", "wrong_faces", "lost_faces", "extra_cards"]
    lines = ["library | " + " | ".join(cols)]
    for k, v in s.items():
        lines.append(k + " | " + " | ".join(str(v[c]) for c in cols))
    return "\n".join(lines)
