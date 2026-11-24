#!/usr/bin/env python3
import pathlib
import sys
import unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / 'scripts'))
from check_gc_metrics import evaluate

class Gates(unittest.TestCase):
    def test_report_only(self):
        self.assertEqual(evaluate({'baseline': {}, 'plus': {}}, {}), [])
    def test_relative_failure(self):
        self.assertEqual(evaluate({'baseline': {'p99': 10}, 'plus': {'p99': 50}},
                                 {'p99': {'ratio': 2}}), ['p99'])
    def test_absolute_slack(self):
        self.assertEqual(evaluate({'baseline': {'p99': 10}, 'plus': {'p99': 50}},
                                 {'p99': {'ratio': 2, 'slack': 30}}), [])
    def test_invalid_budget(self):
        with self.assertRaises(ValueError):
            evaluate({'baseline': {'p99': 10}, 'plus': {'p99': 50}},
                     {'p99': {'ratio': 0.5}})

if __name__ == '__main__': unittest.main()
