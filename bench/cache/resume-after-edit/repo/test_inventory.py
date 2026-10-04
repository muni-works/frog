import unittest

from inventory import Inventory


class InventoryTest(unittest.TestCase):
    def test_add_and_count(self):
        inv = Inventory()
        inv.add("apple", 3)
        inv.add("apple", 2)
        self.assertEqual(inv.count("apple"), 5)

    def test_removing_everything_drops_the_item(self):
        inv = Inventory()
        inv.add("pear", 2)
        inv.remove("pear", 2)
        self.assertEqual(inv.names(), [])

    def test_cannot_remove_more_than_stock(self):
        inv = Inventory()
        inv.add("fig", 1)
        with self.assertRaises(ValueError):
            inv.remove("fig", 2)


if __name__ == "__main__":
    unittest.main()
