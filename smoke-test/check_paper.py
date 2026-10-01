"""How smooth would scroll sync be on a multi-file paper?

Puts every source line in reading order (following \\input), maps it to a PDF
position (page + y) with the forward results, and counts the places where the
PDF position moves backwards as the source moves forwards.  Does the same for
the backward results: PDF grid points in reading order -> source position.
"""
import re, sys

root, dump = sys.argv[1:3]
d = root.rsplit("/", 1)[0]


def order(fname, seq):
    for i, l in enumerate(open(f"{d}/{fname}", encoding="utf-8", errors="replace").read().split("\n"), 1):
        seq.append((fname, i))
        m = re.match(r"\s*\\(?:input|include)\{([^}]+)\}", l)
        if m:
            n = m.group(1)
            order(n if n.endswith(".tex") else n + ".tex", seq)
    return seq


seq = order(root.rsplit("/", 1)[1], [])
rank = {k: i for i, k in enumerate(seq)}

fwd, bwd = [], []
for r in open(dump):
    f = r.split()
    if f[0] == "F":
        fwd.append((rank[(f[1], int(f[2]))], int(f[3]) + float(f[4])))  # page + top y
    else:
        bwd.append((int(f[1]) + float(f[2]), rank.get((f[3], int(f[4])), -1)))

fwd.sort()
back = [(a, b) for a, b in zip(fwd, fwd[1:]) if b[1] < a[1] - 0.02]
big = [(a, b) for a, b in back if a[1] - b[1] > 0.5]
print(f"forward: {len(fwd)} source lines with a PDF position (of {len(seq)})")
print(f"  PDF position goes back while the source goes forward: {len(back)} times, "
      f"by more than half a page: {len(big)}")
for a, b in big[:8]:
    print(f"   {seq[a[0]]} -> {a[1]:.2f}   then {seq[b[0]]} -> {b[1]:.2f}")

bwd.sort()
bb = [(a, b) for a, b in zip(bwd, bwd[1:]) if b[1] < a[1]]
print(f"backward: {len(bwd)} grid points; source goes back while the PDF goes forward: {len(bb)}")
for a, b in bb[:8]:
    print(f"   pdf {a[0]:.1f} -> {seq[a[1]]}   then pdf {b[0]:.1f} -> {seq[b[1]]}")
