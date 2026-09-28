"""Record original addresses of SRW's generated basic-block procedures.

This is a code-dispatch map, not a recovered relocation map. Only SRW's
address-derived names and this project's tc_loc aliases are accepted.
"""

import argparse
from pathlib import Path
import re


def code_map(text):
    result = {}
    addresses = set()
    for line in text.splitlines():
        words = line.split()
        if not words or words[0] != "proc":
            continue
        if len(words) < 2:
            raise ValueError("Procedure without a name")
        name = words[1]
        match = re.fullmatch(r"(?:tc_)?loc_([0-9A-Fa-f]{1,8})", name)
        if not match:
            raise ValueError(f"Procedure needs an explicit guest address: {name}")
        address = int(match[1], 16)
        if name in result or address in addresses or address == 0xFFFFFFFF:
            raise ValueError(f"Duplicate or reserved guest address: {name}")
        result[name] = address
        addresses.add(address)
    if not result:
        raise ValueError("No generated procedures")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, nargs="?")
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    if args.self_check:
        assert code_map("proc tc_loc_401000 global c_entry\nendp\nproc loc_401010\nendp") == {
            "tc_loc_401000": 0x401000, "loc_401010": 0x401010}
        for invalid in ("proc arbitrary", "proc loc_FFFFFFFF", "proc loc_401000\nproc tc_loc_401000"):
            try:
                code_map(invalid)
            except ValueError:
                continue
            raise AssertionError(f"Accepted invalid map: {invalid}")
    else:
        if args.directory is None:
            parser.error("directory is required")
        text = "\n".join(path.read_text() for path in sorted(args.directory.glob("seg*_code.llinc")))
        mapping = code_map(text)
        (args.directory / "code-map.csv").write_text("".join(
            f"{name},{address:08x}\n" for name, address in sorted(mapping.items())))
