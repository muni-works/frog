"""Print a one-line summary of the numbers in a file, one number per line."""

import sys

import stats


def load(path):
    with open(path) as f:
        return [float(line) for line in f if line.strip()]


def summary(xs):
    return f"n={len(xs)} mean={stats.mean(xs):.2f} total={stats.total(xs):.2f}"


if __name__ == "__main__":
    print(summary(load(sys.argv[1])))
