"""Stock levels for a small shop."""


class Inventory:
    def __init__(self):
        self.items = {}

    def add(self, name, quantity):
        """Add `quantity` of `name` to stock."""
        self.items[name] = self.items.get(name, 0) + quantity

    def remove(self, name, quantity):
        """Take `quantity` of `name` out of stock; an item that runs out is dropped."""
        left = self.items.get(name, 0) - quantity
        if left < 0:
            raise ValueError(f"only {self.items.get(name, 0)} {name} in stock")
        self.items[name] = left

    def count(self, name):
        return self.items.get(name, 0)

    def names(self):
        return sorted(self.items)
