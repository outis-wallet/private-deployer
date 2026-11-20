#!/usr/bin/env python3
"""Checks that vectors/addresses.json and vectors/addresses.txt contain the same vectors.

The Cairo test reads the .txt file and wallets read the .json file. scripts/vectors.mjs writes
both. This check catches the case where one file was edited without the other. It does not
compute any address. It only compares the two files.
"""
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
vectors = json.loads((root / "vectors/addresses.json").read_text())["vectors"]
written = [int(line, 16) for line in (root / "vectors/addresses.txt").read_text().split()]

felts = [len(vectors)]
for vector in vectors:
    if vector["source"] not in ("live", "computed"):
        sys.exit(f"unknown source in vectors/addresses.json: {vector['source']}")
    if not isinstance(vector["not_from_zero"], bool):
        sys.exit(f"not_from_zero must be true or false in the .json file, but it is {vector['not_from_zero']!r}")
    felts += [int(vector["caller"], 16), int(vector["class_hash"], 16), int(vector["salt"], 16), 1 if vector["not_from_zero"] else 0]
    felts += [len(vector["calldata"]), *(int(felt, 16) for felt in vector["calldata"]), int(vector["address"], 16)]

if felts != written:
    sys.exit("vectors/addresses.json and vectors/addresses.txt don't match. Run scripts/vectors.mjs to rewrite both.")
print(f"{len(vectors)} vectors, identical in both files.")
