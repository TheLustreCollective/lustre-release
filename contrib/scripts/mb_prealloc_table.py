#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# Derive an ldiskfs mballoc prealloc_table from the live free-space
# layout reported in /proc/fs/ldiskfs/<device>/mb_groups.
#
# mb_groups prints, per block group, a buddy histogram of free extents:
#
#   #group: bfree gfree frags first pa    [ 2^0  2^1  ... 2^13 ]
#   #0    : 7912  32476 1     24856 0     [ 0    0    ...  0   ]
#
# Each bracket column i counts the free extents of size 2^i blocks.
# prealloc_table is the ascending ladder of preallocation window sizes
# (in blocks) mballoc rounds requests up to.  A window larger than the
# biggest contiguous free space the device can still hand out just gets
# split, fragmenting future allocations -- so we cap the ladder at the
# largest order the free-space histogram can actually satisfy, and emit
# the power-of-two ladder from --floor up to that cap.
#
# Usage:
#   mb_prealloc_table.py sda              # read /proc/fs/ldiskfs/sda/mb_groups
#   mb_prealloc_table.py /tmp/mb_groups   # read a captured file
#   mb_prealloc_table.py -                # read stdin
# Apply with:
#   mb_prealloc_table.py sda | sudo tee /proc/fs/ldiskfs/sda/prealloc_table

import argparse
import os
import sys

# Matches the kernel's EXT4_MAX_PREALLOC_TABLE.
MAX_TABLE_ENTRIES = 64

# Auto min-count: keep a window size only if at least one in this many
# block groups can supply it.  Scaling with the group count (i.e. device
# size) stops a handful of lucky large extents from setting the ceiling on
# a big device, while staying permissive on a small one.
DEFAULT_MIN_COUNT_DIVISOR = 64
DEFAULT_MIN_COUNT_FLOOR = 2


def auto_min_count(groups):
    return max(DEFAULT_MIN_COUNT_FLOOR, groups // DEFAULT_MIN_COUNT_DIVISOR)


def read_source(source):
    if source == "-":
        return sys.stdin.read()
    path = source if os.path.exists(source) else \
        "/proc/fs/ldiskfs/%s/mb_groups" % source
    with open(path) as f:
        return f.read()


def parse_histogram(text):
    """Sum the per-group buddy histogram into hist[order] = free extents."""
    hist = []
    groups = 0
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("#") or line.startswith("#group"):
            continue  # header or noise
        lb, rb = line.find("["), line.rfind("]")
        if lb < 0 or rb < lb:
            print("warning: skipping malformed line: %s" % line,
                  file=sys.stderr)
            continue
        try:
            counts = [int(x) for x in line[lb + 1:rb].split()]
        except ValueError:
            print("warning: non-integer histogram: %s" % line,
                  file=sys.stderr)
            continue
        if len(counts) > len(hist):
            hist.extend([0] * (len(counts) - len(hist)))
        for i, c in enumerate(counts):
            hist[i] += c
        groups += 1
    return hist, groups


def order_of(blocks):
    """Smallest power-of-two order whose size is >= blocks."""
    n = 1
    order = 0
    while n < blocks:
        n <<= 1
        order += 1
    return order


def build_table(hist, floor_blocks, min_count, max_blocks):
    # avail[i] = free extents able to host a contiguous 2^i run
    # (any chunk of order >= i qualifies).
    suffix = 0
    avail = [0] * len(hist)
    for i in range(len(hist) - 1, -1, -1):
        suffix += hist[i]
        avail[i] = suffix

    floor_order = order_of(floor_blocks)
    cap_order = order_of(max_blocks) if max_blocks else len(hist) - 1

    top = -1
    for i in range(floor_order, min(cap_order, len(hist) - 1) + 1):
        if avail[i] >= min_count:
            top = i
    if top < floor_order:
        # No free space meets the threshold; emit the floor alone so the
        # table stays valid (the kernel rejects an empty table).
        return [1 << floor_order], avail
    table = [1 << i for i in range(floor_order, top + 1)]
    return table[:MAX_TABLE_ENTRIES], avail


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="device name, mb_groups file path, or - for stdin")
    ap.add_argument("--floor", type=int, default=4, metavar="BLOCKS",
                    help="smallest prealloc window in blocks (default: 4)")
    ap.add_argument("--min-count", type=int, default=None, metavar="N",
                    help="min free extents required to keep an order "
                         "(default: auto = max(%d, groups/%d))" %
                         (DEFAULT_MIN_COUNT_FLOOR, DEFAULT_MIN_COUNT_DIVISOR))
    ap.add_argument("--max-blocks", type=int, default=0, metavar="BLOCKS",
                    help="hard cap on the largest window (default: largest order seen)")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="print the aggregated histogram to stderr")
    args = ap.parse_args()

    if args.floor < 1 or (args.min_count is not None and args.min_count < 1):
        ap.error("--floor and --min-count must be >= 1")

    hist, groups = parse_histogram(read_source(args.source))
    if groups == 0:
        print("error: no group lines parsed from input", file=sys.stderr)
        return 1

    min_count = args.min_count if args.min_count is not None \
        else auto_min_count(groups)

    table, avail = build_table(hist, args.floor, min_count, args.max_blocks)

    if args.verbose:
        print("groups parsed: %d, min-count: %d (%s)" %
              (groups, min_count,
               "explicit" if args.min_count is not None else "auto"),
              file=sys.stderr)
        for i in range(len(hist)):
            print("  2^%-2d (%6d blk): free=%-8d avail>=%d" %
                  (i, 1 << i, hist[i], avail[i]), file=sys.stderr)

    print(" ".join(str(b) for b in table))
    return 0


if __name__ == "__main__":
    sys.exit(main())
