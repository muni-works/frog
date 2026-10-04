import unittest

import stats


class StatsTest(unittest.TestCase):
    def test_mean(self):
        self.assertEqual(stats.mean([1, 2, 3, 4]), 2.5)

    def test_total(self):
        self.assertEqual(stats.total([]), 0)
        self.assertEqual(stats.total([2, 3]), 5)


if __name__ == "__main__":
    unittest.main()
