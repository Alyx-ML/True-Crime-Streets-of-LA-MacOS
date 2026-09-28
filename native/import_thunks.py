"""Emit native-import guest entry procedures from the shared import definition."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent


def graphics_thunks(definitions, prefix="TC_D3D_METHOD", kinds=6,
                    base=0xf0010000, dispatcher="tc_d3d_dispatch"):
    output, seen = [], set()
    for line in definitions.splitlines():
        if not line.startswith(prefix):
            continue
        match = re.fullmatch(re.escape(prefix) + r'\(([0-9]+), ([0-9]+), ([0-9]+), ([A-Za-z0-9_]+)\)', line)
        if not match:
            raise ValueError(f"Invalid graphics method: {line}")
        kind, method, argc = map(int, match.groups()[:3])
        if kind >= kinds or method >= 256 or not 1 <= argc <= 16 or (kind, method) in seen:
            raise ValueError(f"Invalid or duplicate graphics method: {line}")
        seen.add((kind, method))
        address = base + kind * 0x1000 + method * 16
        output += [f"proc tc_loc_{address:X}",
                   f"call {dispatcher} $, {kind * 256 + method}",
                   "POP tmp1", f"add esp, esp, {argc * 4}", "tcall tmp1", "endp", ""]
    return "\n".join(output)


def thunks(definitions, imports):
    output = []
    slots, addresses = set(), set()
    pattern = r'TC_IMPORT\((0x[0-9a-f]+), (0x[0-9a-f]+), ([0-9]+), ([a-z_]+), "([^"]+)"\)'
    for line in definitions.splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(pattern, line)
        if not match:
            raise ValueError(f"Invalid import definition: {line}")
        slot, address, size, handler, symbol = match.groups()
        slot, address, size = int(slot, 16), int(address, 16), int(size)
        if (slot in slots or address in addresses or size % 4 or size > 256 or
                not 0xf0000000 <= address < 0xf0010000 or
                imports.get(hex(slot)) != symbol):
            raise ValueError(f"Unsupported or duplicate import: {symbol}")
        slots.add(slot)
        addresses.add(address)
        output += [f"proc tc_loc_{address:X}", f"call tc_import_dispatch $, {slot}", "POP tmp1"]
        if size:
            output.append(f"add esp, esp, {size}")
        output += ["tcall tmp1", "endp", ""]
    return "\n".join(output)


def modern_menu_hooks(directory):
    path = directory / "seg01_code.llinc"
    text = path.read_text()
    hooks = {
        "loc_578630": "call tc_menu_refresh $, esi, 0",
        "loc_570B40": "call tc_menu_refresh $, ecx, 1",
        "tc_loc_578660": "call tc_menu_event $, ecx\nctcallnz eax, tc_loc_F0040000",
        "tc_loc_575E30": "call tc_menu_event $, ecx\nctcallnz eax, tc_loc_F0040000",
    }
    for name, hook in hooks.items():
        pattern = rf"(^proc {name}(?: [^\n]*)?\n)"
        match = re.search(pattern, text, re.M)
        if not match:
            raise ValueError(f"Missing original menu entry: {name}")
        if text[match.end():].startswith("; Native original-menu extension\n"):
            continue
        extension = "; Native original-menu extension\n" + hook + "\n"
        if name in ("tc_loc_578660", "tc_loc_575E30"):
            continuation = "tc_loc_F0040010" if name == "tc_loc_578660" else "tc_loc_F0040020"
            extension += f"tcall {continuation}\nendp\n\nproc {continuation}\n"
        text = text[:match.end()] + extension + text[match.end():]
    if "proc tc_loc_F0040000\n" not in text:
        text += "\nproc tc_loc_F0040000\nPOP tmp1\nadd esp, esp, 8\ntcall tmp1\nendp\n"
    path.write_text(text)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, nargs="?")
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    if args.self_check:
        import tempfile
        from code_map import code_map
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = directory / "seg01_code.llinc"
            source.write_text("".join(f"proc {name}\nPOP tmp1\ntcall tmp1\nendp\n" for name in
                ("loc_578630", "loc_570B40", "tc_loc_578660", "tc_loc_575E30")))
            modern_menu_hooks(directory)
            patched = source.read_text()
            modern_menu_hooks(directory)
            assert source.read_text() == patched
            assert "ctcallnz eax, tc_loc_F0040000\ntcall tc_loc_F0040010\nendp" in patched
            assert "ctcallnz eax, tc_loc_F0040000\ntcall tc_loc_F0040020\nendp" in patched
            code_map(patched)
        graphics = graphics_thunks("TC_D3D_METHOD(1, 72, 5, DrawPrimitiveUP)")
        assert "proc tc_loc_F0011480" in graphics
        assert "call tc_d3d_dispatch $, 328\nPOP tmp1\nadd esp, esp, 20" in graphics
        directinput = graphics_thunks("TC_DI_METHOD(1, 9, 3, GetDeviceState)",
                                     "TC_DI_METHOD", 2, 0xf0020000, "tc_di_dispatch")
        assert "proc tc_loc_F0021090" in directinput
        assert "call tc_di_dispatch $, 265\nPOP tmp1\nadd esp, esp, 12" in directinput
        example = 'TC_IMPORT(0x0067604c, 0xf0000010, 4, tc_performance_counter, "kernel32.dll!QueryPerformanceCounter")'
        imports = {"0x67604c": "kernel32.dll!QueryPerformanceCounter"}
        assert thunks(example, imports).splitlines() == [
            "proc tc_loc_F0000010", "call tc_import_dispatch $, 6774860",
            "POP tmp1", "add esp, esp, 4", "tcall tmp1", "endp"]
        try:
            thunks(example + "\n" + example, imports)
        except ValueError:
            pass
        else:
            raise AssertionError("Duplicate import accepted")
    else:
        if args.directory is None:
            parser.error("directory is required")
        modern_menu_hooks(args.directory)
        definitions = (ROOT / "runtime/tc_imports.def").read_bytes()
        graphics_definitions = (ROOT / "runtime/tc_d3d8_methods.def").read_bytes()
        input_definitions = (ROOT / "runtime/tc_dinput_methods.def").read_bytes()
        sound_definitions = (ROOT / "runtime/tc_dsound_methods.def").read_bytes()
        output = thunks(definitions.decode(), json.loads((ROOT / "analysis/imports.json").read_text()))
        output += "\n" + graphics_thunks(graphics_definitions.decode())
        output += "\n" + graphics_thunks(input_definitions.decode(), "TC_DI_METHOD", 2,
                                         0xf0020000, "tc_di_dispatch")
        output += "\n" + graphics_thunks(sound_definitions.decode(), "TC_DS_METHOD", 4,
                                         0xf0030000, "tc_ds_dispatch")
        (args.directory / "import-definitions.sha256").write_text(hashlib.sha256(definitions + graphics_definitions + input_definitions + sound_definitions).hexdigest() + "\n")
        (args.directory / "seg_imports_code.llinc").write_text(output)
        main = args.directory / "truecrime.llasm"
        include = "include seg_imports_code.llinc\n"
        text = main.read_text()
        if include not in text:
            main.write_text(text + "\n" + include)
