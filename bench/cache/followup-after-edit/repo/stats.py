"""Small statistics helpers for the report generator."""


def mean(xs):
    """The arithmetic mean of a non-empty list of numbers."""
    return sum(xs) / len(xs)


def total(xs):
    """The sum of a list of numbers (0 for an empty list)."""
    return sum(xs)
