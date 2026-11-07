"""Merges lcov reports by file and line (a line is covered if any report covered it), writes the
merged report, and prints a per-file summary of axod's crates, least covered first.

Usage: merge_lcov.py <repository root> <output.lcov> <input.lcov>...
"""

import collections
import os
import sys


def read(path, root):
    lines = collections.defaultdict(dict)
    current = None
    with open(path) as report:
        for line in report:
            line = line.strip()
            if line.startswith("SF:"):
                name = line[3:]
                # The binary's report names files by absolute path; Bazel's by relative path.
                current = os.path.relpath(name, root) if os.path.isabs(name) else name
            elif line.startswith("DA:") and current is not None:
                number, hits = line[3:].split(",")[:2]
                number, hits = int(number), int(hits)
                lines[current][number] = lines[current].get(number, 0) + hits
    return lines


def main():
    root, output, inputs = sys.argv[1], sys.argv[2], sys.argv[3:]
    merged = collections.defaultdict(dict)
    for path in inputs:
        for name, lines in read(path, root).items():
            for number, hits in lines.items():
                merged[name][number] = merged[name].get(number, 0) + hits
    names = sorted(name for name in merged if name.startswith("crates/") and name.endswith(".rs"))
    with open(output, "w") as report:
        for name in names:
            report.write(f"SF:{name}\n")
            for number, hits in sorted(merged[name].items()):
                report.write(f"DA:{number},{hits}\n")
            report.write("end_of_record\n")
    rows, totals = [], collections.defaultdict(lambda: [0, 0])
    for name in names:
        lines = merged[name]
        covered = sum(1 for hits in lines.values() if hits)
        crate = name.split("/")[1]
        totals[crate][0] += covered
        totals[crate][1] += len(lines)
        rows.append((covered / max(len(lines), 1), covered, len(lines), name))
    for share, covered, total, name in sorted(rows):
        if total >= 20 and share < 0.9:
            print(f"{100 * share:5.1f}% {covered:5}/{total:<5} {name}")
    print()
    for crate, (covered, total) in sorted(totals.items()):
        print(f"{100 * covered / max(total, 1):5.1f}% {covered:6}/{total:<6} {crate}")


main()
