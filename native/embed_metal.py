"""Embed the compiled Metal library in the native runtime, without bundle lookup."""
import argparse
from pathlib import Path


def header(data):
    if not data:
        raise ValueError("The Metal library is empty")
    lines = ["/* Generated from tc_fixed.metallib. */",
             "static const unsigned char tc_fixed_metallib[] = {"]
    lines.extend("    " + ",".join(f"0x{v:02x}" for v in data[i:i + 16]) + ","
                 for i in range(0, len(data), 16))
    return "\n".join(lines + ["};", ""])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("destination", type=Path, nargs="?")
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    if args.self_check:
        assert header(bytes(range(17))).count("0x") == 17
        assert "0x00,0x01" in header(b"\x00\x01")
        try:
            header(b"")
        except ValueError:
            pass
        else:
            raise AssertionError("Empty Metal library accepted")
    else:
        if args.source is None or args.destination is None:
            parser.error("source and destination are required")
        args.destination.write_text(header(args.source.read_bytes()))
