"""Check SyncTeX frame<->page agreement for a Beamer deck.

Ground truth: a frame's page is the PDF page whose text contains the frame's
title (pdftotext), independent of SyncTeX.
"""
import re, subprocess, sys, unicodedata
from collections import Counter, defaultdict

src, pdf, dump = sys.argv[1:4]
lines = open(src, encoding="utf-8").read().split("\n")


def norm(s):
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


def clean_tex(s):
    s = re.sub(r"\\[a-zA-Z@]+\*?(\[[^]]*\])?", " ", s)  # drop commands
    return norm(s.replace("{", " ").replace("}", " ").replace("~", " "))


def uncomment(l):
    return re.sub(r"(?<!\\)%.*", "", l)


# frames: (begin, end, title)
frames, stack = [], []
for i, l in enumerate(lines, 1):
    c = uncomment(l)
    if re.search(r"\\begin\{frame\}", c):
        stack.append(i)
    if re.search(r"\\end\{frame\}", c) and stack:
        b = stack.pop()
        body = "\n".join(uncomment(x) for x in lines[b - 1:i])
        m = re.search(r"\\begin\{frame\}(?:<[^>]*>)?(?:\[[^]]*\])?\{([^}]*)\}", body) \
            or re.search(r"\\frametitle\{([^}]*)\}", body)
        frames.append((b, i, clean_tex(m.group(1)) if m else ""))

npages = int(re.search(r"Pages:\s+(\d+)", subprocess.run(
    ["pdfinfo", pdf], capture_output=True, text=True).stdout).group(1))
ptext = [norm(subprocess.run(["pdftotext", "-f", str(p), "-l", str(p), pdf, "-"],
                             capture_output=True, text=True).stdout)
         for p in range(1, npages + 1)]

fwd, bwd = {}, defaultdict(list)
for r in open(dump):
    f = r.split()
    if f[0] == "F" and f[1] == "deck.tex":
        fwd[int(f[2])] = int(f[3])
    elif f[0] == "B":
        bwd[int(f[1])].append((f[3], int(f[4])))

ok_frames = no_truth = ambiguous = 0
line_hits = line_total = 0
bad = []
truth_page_of_frame = {}
for b, e, t in frames:
    if len(t.split()) < 2:
        no_truth += 1
        continue
    key = " ".join(t.split()[:6])
    pages = [p + 1 for p, txt in enumerate(ptext) if key in txt]
    if len(pages) != 1:
        ambiguous += 1
        continue
    truth = pages[0]
    truth_page_of_frame[(b, e)] = truth
    got = [fwd[l] for l in range(b, e + 1) if l in fwd]
    hits = sum(p == truth for p in got)
    line_hits += hits
    line_total += len(got)
    if hits == len(got):
        ok_frames += 1
    else:
        bad.append((b, e, truth, Counter(got).most_common(3)))

print(f"frames in source: {len(frames)}, pages: {npages}")
print(f"frames with a unique title match: {len(truth_page_of_frame)} "
      f"(no usable title: {no_truth}, title on 0 or >1 pages: {ambiguous})")
print(f"forward: frames whose every line lands on the right page: "
      f"{ok_frames}/{len(truth_page_of_frame)}; lines: {line_hits}/{line_total}")
for b, e, truth, mc in bad[:10]:
    print(f"   frame lines {b}-{e}: expected page {truth}, got {mc}")

# backward: page grid points -> line inside that page's frame?
pg2frame = {p: fe for fe, p in truth_page_of_frame.items()}
bh = bt = 0
bbad = []
for p, (b, e) in sorted(pg2frame.items()):
    for f, l in bwd.get(p, []):
        bt += 1
        if f == "deck.tex" and b <= l <= e:
            bh += 1
        else:
            bbad.append((p, b, e, f, l))
print(f"backward: grid points landing inside the page's frame: {bh}/{bt}")
for x in bbad[:10]:
    print("   page %d frame %d-%d -> %s:%d" % x)

# frame-level forward: the \end{frame} line of each frame
fh = 0
fbad = []
for (b, e), truth in truth_page_of_frame.items():
    if fwd.get(e) == truth:
        fh += 1
    else:
        fbad.append((b, e, truth, fwd.get(e)))
print(f"frame-level forward (\\end{{frame}} line): {fh}/{len(truth_page_of_frame)}")
for x in fbad:
    print("   frame %d-%d expected page %s got %s" % x)
# frame-level backward: every point on a page -> the enclosing frame of the reported line
bl = Counter()
for p, (b, e) in sorted(pg2frame.items()):
    for f, l in bwd.get(p, []):
        bl["end-line" if (f == "deck.tex" and l == e) else ("inside" if f == "deck.tex" and b <= l <= e else f)] += 1
print("backward reported line:", dict(bl))
