"""Recover reachable code and classify address operands without running the game.

The relocation output is deliberately partial: immediate values, indexed
addresses, pointer tables and indirect control flow need further recovery.
"""

import argparse
import csv
import ctypes as C
import hashlib
import json
from pathlib import Path
import re
import struct

from prepare import ROOT, SHA256, NORETURN_ENTRIES, restore_prologues


class Operand(C.Structure):
    _fields_ = [(name, C.c_uint32) for name in ("kind", "value", "bits", "base", "index")]


class Instruction(C.Structure):
    _fields_ = [(name, C.c_uint32) for name in ("length", "flow", "target", "segmented")]
    _fields_ += [("operands", Operand * 3), ("text", C.c_char * 128)]


def decoder():
    library = C.CDLL(str(ROOT / "build/libtc_decode.dylib"))
    library.decode.argtypes = [C.c_char_p, C.c_size_t, C.c_uint32, C.POINTER(Instruction)]
    library.decode.restype = C.c_int

    def decode(data, address):
        result = Instruction()
        return result if library.decode(data, len(data), address, C.byref(result)) else None

    return decode


def self_check(decode):
    branch = decode(bytes.fromhex("75 fe"), 0x401000)
    assert (branch.length, branch.flow, branch.target) == (2, 3, 0x401000)
    load = decode(bytes.fromhex("a1 10 c0 72 00"), 0x609000)
    assert load.operands[1].kind == 1 and load.operands[1].value == 0x72C010
    assert load.operands[1].base == 0 and load.operands[1].bits == 32
    assert decode(bytes.fromhex("ff 51 0c"), 0x401000).flow == 1
    assert decode(bytes.fromhex("c2 10 00"), 0x401000).flow == 4
    assert decode(bytes.fromhex("64 a1 00 00 00 00"), 0x401000).segmented
    assert decode(b"\xe8", 0x401000) is None
    assert switch_shape("cmp ecx, 0x15", "ja 0x4555a3", "jmp dword [ecx*4+0x4555ac]") == (0x4555AC, 22)
    assert switch_shape("cmp ecx, 0x15", "ja 0x4555a3", "jmp dword [eax*4+0x4555ac]") is None
    assert switch_shape("cmp ecx, 0x15", "jg 0x4555a3", "jmp dword [ecx*4+0x4555ac]") is None
    assert remapped_shape("cmp edx, 0x75", "ja 0x470887", "movzx eax, byte [edx+0x4709c0]", "jmp dword [eax*4+0x4709ac]") == (0x4709AC, 0x4709C0, 118)
    assert remapped_shape("cmp ecx, 0x75", "ja 0x470887", "movzx eax, byte [edx+0x4709c0]", "jmp dword [eax*4+0x4709ac]") is None


def switch_shape(compare, branch, jump):
    """Recognize only a contiguous unsigned bound check and indexed dispatch."""
    cmp_match = re.fullmatch(r"cmp (e[a-z]{2}), (0x[0-9a-f]+)", compare)
    jump_match = re.fullmatch(r"jmp dword \[(e[a-z]{2})\*4\+(0x[0-9a-f]+)\]", jump)
    if not cmp_match or not jump_match or not branch.startswith("ja "):
        return None
    if cmp_match[1] != jump_match[1]:
        return None
    count = int(cmp_match[2], 16) + 1
    # ponytail: tables up to 4096 entries; larger tables need explicit analysis.
    return (int(jump_match[2], 16), count) if count <= 4096 else None


def remapped_shape(compare, branch, remap, jump):
    """Recognize a byte remap between the bound check and pointer table."""
    mapping = re.fullmatch(r"movzx (e[a-z]{2}), byte \[(e[a-z]{2})\+(0x[0-9a-f]+)\]", remap)
    if not mapping:
        return None
    # Reuse the direct-table recognizer after requiring the input register match.
    prefix = f"cmp {mapping[2]}, "
    if not compare.startswith(prefix):
        return None
    shape = switch_shape(f"cmp {mapping[1]}, " + compare[len(prefix):], branch, jump)
    return (shape[0], int(mapping[3], 16), shape[1]) if shape else None


def recover(decode, seeds):
    data = (ROOT.parent / "TrueCrime.exe").read_bytes()
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError("Unsupported executable SHA-256")
    data, patches = restore_prologues(data)
    data = bytes(data)
    seeds = list(dict.fromkeys(seeds + [int(patch["address"], 16) for patch in patches]))
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    count = struct.unpack_from("<H", data, pe + 6)[0]
    table = pe + 24 + struct.unpack_from("<H", data, pe + 20)[0]
    base = struct.unpack_from("<I", data, pe + 24 + 28)[0]
    sections = []
    for i in range(count):
        name, virtual_size, rva, raw_size, offset = struct.unpack_from("<8sIIII", data, table + 40 * i)
        flags = struct.unpack_from("<I", data, table + 40 * i + 36)[0]
        sections.append((base + rva, virtual_size, offset, raw_size, flags, name.rstrip(b"\0")))

    def section_at(address):
        return next((s for s in sections if s[0] <= address < s[0] + s[1]), None)

    def read_at(address, size):
        section = section_at(address)
        if not section or address - section[0] + size > min(section[1], section[3]):
            return None
        offset = section[2] + address - section[0]
        return data[offset:offset + size]

    def string_at(address):
        section = section_at(address)
        if not section:
            raise ValueError(f"Unmapped PE string {address:#x}")
        offset = section[2] + address - section[0]
        end = min(section[2] + section[3], offset + 1024)
        terminator = data.find(b"\0", offset, end)
        if terminator < 0:
            raise ValueError(f"Unterminated PE string {address:#x}")
        return data[offset:terminator].decode("ascii")

    imports = {}
    import_rva, import_size = struct.unpack_from("<II", data, pe + 24 + 104)
    for descriptor in range(import_size // 20):
        raw_descriptor = read_at(base + import_rva + descriptor * 20, 20)
        if raw_descriptor is None:
            raise ValueError("Unmapped PE import descriptor")
        lookup, _, _, name_rva, first_thunk = struct.unpack("<5I", raw_descriptor)
        if not any((lookup, name_rva, first_thunk)):
            break
        module = string_at(base + name_rva)
        table_section = section_at(base + (lookup or first_thunk))
        if table_section is None:
            raise ValueError("Unmapped PE import lookup table")
        max_entries = (table_section[0] + min(table_section[1], table_section[3]) - base - (lookup or first_thunk)) // 4
        for index in range(max_entries):
            raw_thunk = read_at(base + (lookup or first_thunk) + index * 4, 4)
            if raw_thunk is None:
                raise ValueError("Unmapped PE import lookup entry")
            thunk = struct.unpack("<I", raw_thunk)[0]
            if not thunk:
                break
            name = f"ordinal:{thunk & 0xffff}" if thunk & 0x80000000 else string_at(base + thunk + 2)
            imports[base + first_thunk + index * 4] = f"{module}!{name}"
        else:
            raise ValueError("Unterminated PE import lookup table")

    pending = list(seeds)
    decoded = {}
    owners = {}
    references = []
    unresolved = []
    targets = set(seeds)
    previous = {}
    tables = []
    import_sites = []
    while pending:
        address = pending.pop()
        if address in decoded:
            continue
        section = section_at(address)
        # The original revolt section contains encoded/self-modifying code.
        if not section or not section[4] & 0x20000000 or section[5] == b"revolt":
            unresolved.append((address, "target outside static executable sections"))
            continue
        if address in owners:
            unresolved.append((address, f"target overlaps instruction at {owners[address]:#x}"))
            continue
        relative = address - section[0]
        if relative >= section[3]:
            unresolved.append((address, "target has no file bytes"))
            continue
        offset = section[2] + relative
        raw = data[offset:offset + min(15, section[3] - relative)]
        instruction = decode(raw, address)
        if instruction is None:
            unresolved.append((address, "invalid or truncated instruction"))
            continue
        if any(address + i in owners for i in range(instruction.length)):
            unresolved.append((address, "instruction overlaps an existing decoded range"))
            continue
        raw = raw[:instruction.length]
        text = instruction.text.decode("ascii")
        decoded[address] = (raw.hex(), text)
        previous[address + instruction.length] = address
        for i in range(instruction.length):
            owners[address + i] = address
        for operand in instruction.operands:
            if not operand.kind or operand.bits != 32 or not section_at(operand.value):
                continue
            encoded = struct.pack("<I", operand.value)
            positions = [i for i in range(len(raw) - 3) if raw[i:i + 4] == encoded]
            category = "immediate_candidate"
            if operand.kind == 1:
                category = "absolute_memory" if not (operand.base or operand.index or instruction.segmented) else "displacement_candidate"
            if len(positions) != 1:
                unresolved.append((address, "ambiguous address operand encoding"))
                continue
            references.append((address, address + positions[0], operand.value, category, text))
        if instruction.flow in (1, 2, 3):
            if instruction.target:
                targets.add(instruction.target)
                pending.append(instruction.target)
            else:
                operand = instruction.operands[0]
                if (operand.kind == 1 and not (operand.base or operand.index or instruction.segmented)
                        and operand.value in imports):
                    import_sites.append((address, operand.value, imports[operand.value], text))
                    if instruction.flow == 1 and imports[operand.value].lower() != "kernel32.dll!exitprocess":
                        pending.append(address + instruction.length)
                    continue
                branch = previous.get(address)
                compare = previous.get(branch)
                shape = switch_shape(decoded[compare][1], decoded[branch][1], text) if compare is not None else None
                mapping = None
                indices = range(shape[1]) if shape else ()
                if shape is None and compare is not None:
                    bound = previous.get(compare)
                    mapped = remapped_shape(decoded[bound][1], decoded[compare][1], decoded[branch][1], text) if bound is not None else None
                    if mapped:
                        mapping_bytes = read_at(mapped[1], mapped[2])
                        if mapping_bytes is not None:
                            shape = (mapped[0], mapped[2])
                            indices = sorted(set(mapping_bytes))
                            mapping = {"instruction": hex(branch), "address": hex(mapped[1]),
                                       "byte_count": mapped[2], "indices": list(mapping_bytes)}
                            compare = bound
                entries = []
                for index in indices:
                    pointer = read_at(shape[0] + index * 4, 4)
                    target = struct.unpack("<I", pointer)[0] if pointer else None
                    if target is None or not section_at(target) or not section_at(target)[4] & 0x20000000:
                        entries = []
                        break
                    entries.append((index, target))
                if entries:
                    tables.append({"dispatch": hex(address), "bound_compare": hex(compare),
                                   "table": hex(shape[0]), "targets": [hex(t) for _, t in entries],
                                   "entry_indices": [i for i, _ in entries], "remap": mapping,
                                   "evidence": "bounded unsigned fallthrough path; other incoming paths not proven"})
                    for index, target in entries:
                        references.append((address, shape[0] + index * 4, target, "switch_entry", text))
                        targets.add(target)
                        pending.append(target)
                    # Promote the table-base operand only after recognizing its bounded use.
                    references = [(a, b, c, "switch_base" if a == address and c == shape[0] else d, e)
                                  for a, b, c, d, e in references]
                    if mapping:
                        references = [(a, b, c, "switch_base" if a == int(mapping["instruction"], 16) and c == int(mapping["address"], 16) else d, e)
                                      for a, b, c, d, e in references]
                else:
                    unresolved.append((address, f"indirect control flow: {text}"))
        if instruction.flow not in (2, 4) and not (instruction.flow == 1 and instruction.target in NORETURN_ENTRIES):
            pending.append(address + instruction.length)

    output = ROOT / "analysis"
    output.mkdir(exist_ok=True)
    with (output / "reachable.asm").open("w") as stream:
        for address, (raw, text) in sorted(decoded.items()):
            stream.write(f"{address:08x}  {raw:30s}  {text}\n")
    with (output / "address-references.csv").open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["instruction", "operand_location", "target", "classification", "assembly"])
        writer.writerows((hex(a), hex(b), hex(c), d, e) for a, b, c, d, e in sorted(references))
    with (output / "relocations.partial.csv").open("w") as stream:
        for _, source, target, category, _ in sorted(references):
            if category in ("absolute_memory", "switch_entry", "switch_base"):
                stream.write(f"{source:#x},{target:#x}\n")
    with (output / "unresolved.csv").open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["address", "reason"])
        writer.writerows((hex(a), reason) for a, reason in sorted(set(unresolved)))
    with (output / "import-sites.csv").open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["instruction", "import_slot", "symbol", "assembly"])
        writer.writerows((hex(a), hex(b), symbol, text) for a, b, symbol, text in sorted(import_sites))
    (output / "imports.json").write_text(json.dumps({hex(a): symbol for a, symbol in sorted(imports.items())}, indent=2) + "\n")
    summary = {
        "input_sha256": SHA256,
        "noreturn_entries": [hex(address) for address in NORETURN_ENTRIES],
        "analysis_image": "20 prologues restored from the trampoline table; wrapper equivalence not established",
        "seeds": [hex(s) for s in seeds],
        "instructions": len(decoded),
        "instruction_bytes": len(owners),
        "direct_targets": len(targets),
        "absolute_memory_references": sum(r[3] == "absolute_memory" for r in references),
        "bounded_switch_tables": len(tables),
        "byte_remapped_switch_tables": sum(t["remap"] is not None for t in tables),
        "switch_relocations": sum(r[3] in ("switch_entry", "switch_base") for r in references),
        "address_candidates": sum(r[3] in ("immediate_candidate", "displacement_candidate") for r in references),
        "unresolved_sites": len(set(unresolved)),
        "known_import_slots": len(imports),
        "direct_import_sites": len(import_sites),
        "complete_relocation_map": False,
        "limitations": "Follows direct calls, branches and bounded direct/byte-remapped switch tables; calls return unless covered by explicit no-return evidence. Other indirect flow, exceptions and data pointers remain unresolved. Reachability does not prove original code/data boundaries.",
    }
    (output / "jump-tables.json").write_text(json.dumps(tables, indent=2) + "\n")
    (output / "recovery.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument("--seed", action="append", type=lambda text: int(text, 0))
    args = parser.parse_args()
    decode = decoder()
    if args.self_check:
        self_check(decode)
    else:
        recover(decode, args.seed or [0x609010, 0x5E8E60, 0x665BD1, 0x612F60])
