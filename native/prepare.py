"""Recover the first startup layer of the supported executable without running it.

The output is analysis data, not an executable to launch or input ready for SRW.
"""

import argparse
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parent
SHA256 = "2b965435039c425b4bb0f4ab9079d8ce8a87c8022e40a5038301cfac2db59efc"
# Exact-image evidence: 0x664064 calls ExitProcess through IAT 0x676110.
# Both wrappers pass zero as the third argument to 0x664128, selecting its
# exit path through 0x664064. The returning wrapper at 0x66420d passes one.
NORETURN_ENTRIES = (0x664064, 0x6641EB, 0x6641FC)
SECTION_OFFSET = 0x2C5000
START = SECTION_OFFSET + 0x26
END = START + 0x4E5


def decode_startup(source):
    # Fixed offsets are valid only for this exact executable revision.
    if hashlib.sha256(source).hexdigest() != SHA256:
        raise ValueError("Unsupported TrueCrime.exe SHA-256; refusing fixed-offset decoding")
    result = bytearray(source)
    seed = struct.unpack_from("<I", source, SECTION_OFFSET)[0]
    for index in range(0x4E4, -1, -1):
        encrypted = source[START + index]
        result[START + index] = encrypted ^ (seed & 255)
        rotation = encrypted & 31
        seed = (((seed << rotation) | (seed >> (32 - rotation))) + index) & 0xFFFFFFFF
    return result


def restore_prologues(source):
    """Recover bytes copied by 0x75d2a0..0x75d2ac, for static analysis only.

    This does not claim equivalence for the surrounding wrapper's side effects.
    """
    decoded = decode_startup(source)
    restored = bytearray(source)
    patches = []
    for row in range(0x37C, 0x50C, 20):
        address, flags, _, _, displacement = struct.unpack_from("<5I", decoded, SECTION_OFFSET + row)
        offset = address - 0x400000
        if flags != 0 or not 0x1000 <= offset <= 0x275A02 - 5:
            raise ValueError("Unsupported trampoline row")
        original = source[offset:offset + 5]
        if original != b"\xe8" + struct.pack("<I", displacement) or address + 5 + displacement != 0x75D096:
            raise ValueError("Trampoline does not match its saved prologue record")
        saved = decoded[SECTION_OFFSET + row + 8:SECTION_OFFSET + row + 13]
        restored[offset:offset + 5] = saved
        patches.append({"address": hex(address), "table_row": hex(0x75D000 + row),
                        "original": original.hex(), "restored": saved.hex()})
    return restored, patches


def self_check(source):
    """Optional regression check; never run during normal preparation."""
    result = decode_startup(source)
    assert result[START:START + 6] == bytes.fromhex("56 e8 0d 00 00 00")
    assert result[START + 6:START + 19] == b"kernel32.dll\0"
    assert struct.unpack_from("<I", result, SECTION_OFFSET + 0x35C)[0] == 0x665BD1
    assert result[:START] == source[:START]
    assert result[END:] == source[END:]
    restored, patches = restore_prologues(source)
    assert len(patches) == 20
    assert restored[0xBD820:0xBD828] == bytes.fromhex("83 ec 18 a1 54 95 6d 00")
    changed = {i for patch in patches for i in range(int(patch["address"], 16) - 0x400000, int(patch["address"], 16) - 0x400000 + 5)}
    assert all(a == b or i in changed for i, (a, b) in enumerate(zip(source, restored)))
    try:
        decode_startup(b"unsupported input")
    except ValueError:
        pass
    else:
        raise AssertionError("Unsupported input was accepted")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    source = (ROOT.parent / "TrueCrime.exe").read_bytes()
    if args.self_check:
        self_check(source)
        return
    decoded = decode_startup(source)
    output = ROOT / "analysis"
    output.mkdir(exist_ok=True)
    (output / "startup-decoded.analysis.pe").write_bytes(decoded)
    restored, patches = restore_prologues(source)
    (output / "prologues-restored.analysis.pe").write_bytes(restored)
    (output / "prologues.json").write_text(json.dumps(patches, indent=2) + "\n")
    manifest = {
        "input_sha256": SHA256,
        "status": "first startup layer recovered statically; not a runnable port",
        "image_base": "0x00400000",
        "pe_entry": "0x0075d005",
        "decoded_range_inclusive": ["0x0075d026", "0x0075d50a"],
        "startup_destination_pointer": "0x0075d35c",
        "startup_destination": f"0x{struct.unpack_from('<I', decoded, SECTION_OFFSET + 0x35C)[0]:08x}",
        "probable_winmain": "0x00612f60",
        "winmain_evidence": "CRT call at 0x00665d50 passes four WinMain arguments; callee returns with ret 0x10",
        "graphics": {
            "initialization": "0x00609010",
            "create_call": "0x0060901f",
            "import_thunk": "0x0064542a",
            "import_slot": "0x00676314",
            "interface_pointer": "0x0072c010",
            "sdk_version": 220,
        },
        "input": {
            "initialization": "0x005e8e60",
            "create_call": "0x005e8e79",
            "import_thunk": "0x00661050",
            "import_slot": "0x0067601c",
            "interface_pointer": "0x0072ba8c",
            "version": "0x0800",
        },
        "missing": ["complete relocations", "control-flow annotations", "native platform runtime"],
    }
    (output / "startup.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Prepared analysis copy and startup.json. No game code executed.")


if __name__ == "__main__":
    main()
