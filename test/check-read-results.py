"""Compare every paired expected/actual JSON result emitted by SQL fixtures.

Default arrays are ordered. O-SQL fixtures explicitly mark their Set/Map-only
transport arrays as unordered; that opt-in does not relax prepared-view tests.
"""
import json
from decimal import Decimal
import sys
from pathlib import Path


def equal(expected, actual, unordered=False):
    if isinstance(expected, dict):
        return (isinstance(actual, dict) and expected.keys() == actual.keys()
                and all(equal(v, actual[k], unordered) for k, v in expected.items()))
    if isinstance(expected, list):
        if not isinstance(actual, list) or len(expected) != len(actual):
            return False
        if not unordered:
            return all(equal(a, b) for a, b in zip(expected, actual))
        remaining = list(actual)
        for member in expected:
            for index, candidate in enumerate(remaining):
                if equal(member, candidate, True):
                    remaining.pop(index)
                    break
            else:
                return False
        return not remaining
    if isinstance(expected, bool):
        return isinstance(actual, bool) and expected == actual
    if isinstance(expected, (int, Decimal)):
        return not isinstance(actual, bool) and isinstance(actual, (int, Decimal)) and expected == actual
    return type(expected) is type(actual) and expected == actual


lines = [line for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
if not lines or len(lines) % 2:
    raise SystemExit(f"Expected nonempty paired JSON rows, got {len(lines)}")

count = 0
for position in range(0, len(lines), 2):
    metadata = json.loads(lines[position], parse_float=Decimal)
    actual = json.loads(lines[position + 1], parse_float=Decimal)
    if not isinstance(metadata, dict) or set(metadata) not in ({"case", "expected"}, {"case", "expected", "unordered"}):
        raise SystemExit(f"Missing test metadata at line {position + 1}: {metadata!r}")
    if "unordered" in metadata and metadata["unordered"] is not True:
        raise SystemExit("unordered fixture metadata must be true when present")
    if not equal(metadata["expected"], actual, metadata.get("unordered", False)):
        raise SystemExit(
            f"FAIL {metadata['case']}\n"
            f"expected: {json.dumps(metadata['expected'], ensure_ascii=False, sort_keys=True, default=str)}\n"
            f"actual:   {json.dumps(actual, ensure_ascii=False, sort_keys=True, default=str)}"
        )
    count += 1
    print(f"PASS {metadata['case']}")
print(f"All {count} result checks passed.")

