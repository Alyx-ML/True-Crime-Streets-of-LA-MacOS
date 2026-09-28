"""Supply recovered entry points to SRW using its existing alias mechanism."""
import argparse
import hashlib
import struct
import json
import re
from pathlib import Path

from prepare import ROOT, SHA256, NORETURN_ENTRIES
from recover import decoder


def translated_switches(assembly, data=b"", sections=()):
    """Recover bounded direct tables exposed by SRW's newly decoded code."""
    # SRW comments absolute loads as "push dword A;call x86_mov_reg_mem_32;mov edx, [esp - 4]";
    # keep the final move (flag-preserving, writes only its destination).
    instructions=[line[1:].rsplit(";",1)[-1] if "call x86_mov_" in line else line[1:]
                  for line in assembly.splitlines() if line.startswith(";")]
    tables=set()
    for i,instruction in enumerate(instructions):
        jump=re.fullmatch(r"jmp dword \[(eax|ebx|ecx|edx|esi|edi|ebp)\*4\+(0x[0-9a-f]+)\]",instruction)
        if not jump:continue
        register,table=jump[1],int(jump[2],16)
        preceding=instructions[max(0,i-8):i]
        remap=None
        if preceding:
            mapping=re.fullmatch(rf"movzx {register}, byte \[(eax|ebx|ecx|edx|esi|edi|ebp)\+(0x[0-9a-f]+)\]",preceding[-1])
            if mapping:
                register,remap=mapping[1],int(mapping[2],16)
                preceding=preceding[:-1]
        bounded=False
        for previous in reversed(preceding):
            if re.fullmatch(r"ja (?:short |near )?loc_[0-9A-Fa-f]+",previous) and not bounded:
                bounded=True;continue
            compare=re.fullmatch(rf"cmp {register}, (0x[0-9a-f]+|eax|ebx|ecx|edx|esi|edi|ebp)",previous)
            biased=re.fullmatch(r"cmp (eax|ebx|ecx|edx|esi|edi|ebp), (0x[0-9a-f]+)",previous)
            if not compare and biased and bounded and remap is not None:
                # Remapped index checked as a biased copy: lea ecx, [eax-0x3]; cmp ecx, 0xf (0x4d5719).
                index=preceding.index(previous)
                for line in reversed(preceding[max(0,index-4):index]):
                    lea=re.fullmatch(rf"lea {biased[1]}, \[{register}([+-])(0x[0-9a-f]+)\]",line)
                    if lea:
                        remap+=int(lea[2],16)*(1 if lea[1]=="-" else -1);compare=re.fullmatch(r"(0x[0-9a-f]+)",biased[2]);break
            if compare and bounded and not compare[1].startswith("0x"):
                # Bound held in a register loaded just before (mov edx, 0x3; cmp eax, edx).
                index=preceding.index(previous)
                loads=[re.fullmatch(rf"mov {compare[1]}, (0x[0-9a-f]+)",line) for line in preceding[max(0,index-4):index]]
                loads=[load for load in loads if load]
                if not loads:break
                compare=loads[-1]
            if compare and bounded:
                count=int(compare[1],16)+1
                if remap is not None:
                    if count>4096:break
                    for _,_,rva,size,offset in sections:
                        base=0x400000+rva
                        if base<=remap and remap+count<=base+size:
                            indexes=data[offset+remap-base:offset+remap-base+count]
                            count=max(indexes)+1
                            break
                    else:break
                if count<=4096:tables.add((table,table+4*count))
                break
            # These instructions preserve flags and the dispatch register.
            move=re.fullmatch(r"(?:mov|lea) (eax|ebx|ecx|edx|esi|edi|ebp), .+",previous)
            if move and move[1]!=register:continue
            # Stores to memory preserve flags and registers (0x5f0d53).
            if re.fullmatch(r"mov (?:byte |word |dword )?\[[^\]]+\], .+",previous):continue
            # x87 and SSE data operations leave EFLAGS alone (not FCOMI/COMISS), e.g. 0x5d9fe0.
            mnemonic=previous.split()[0]
            if "comi" not in mnemonic and not previous.split(",")[0].endswith(register) and (
                    mnemonic.startswith("f") or "xmm" in previous):continue
            if re.fullmatch(r"push (eax|ebx|ecx|edx|esi|edi|ebp)",previous):continue
            break
    return tables


def entry_points(recovery, tables, decoded):
    if recovery["input_sha256"] != SHA256:
        raise ValueError("Recovery belongs to a different executable")
    addresses = {int(value, 16) for value in recovery["seeds"]}
    addresses.update(int(target, 16) for table in tables for target in table["targets"])
    # These four original code exports also need LLVM-safe names.
    addresses.update((0x4AA9F0, 0x4BD820, 0x567E20, 0x5693D0))
    missing = addresses - decoded
    if missing:
        raise ValueError(f"Entries lack decoded instruction boundaries: {sorted(missing)}")
    # The CRT resolves its InitializeCriticalSectionAndSpinCount fallback through
    # an immediate function pointer. The startup trap identified this entry;
    # its 16-byte body calls InitializeCriticalSection and returns TRUE (ret 8).
    # The analogous TLS fallback calls TlsAlloc and discards its callback argument.
    # Array constructor callback reached from initializer 0x4d9cb0.
    # Registered WNDPROC reached by CreateWindow WM_NCCREATE delivery.
    # Worker entries passed to the same thread wrapper at 0x60f42e,
    # 0x60e168 and 0x619da6.
    # Startup object virtual methods reached from 0x6100cc and 0x60ae75.
    addresses.update((0x67099B,0x66979F,0x4CB670,0x612A90,0x60F2B0,0x60DCF0,0x613820,0x529280,0x60AF40))
    # CRT initializer 0x662971 installs these callbacks in 0x6bfd94..0x6bfda8.
    addresses.update((0x6668B7,0x666545,0x6665AA,0x666509,0x666590))
    # Array constructors passed by the recovered callers of iterator 0x401450.
    addresses.update((0x520D10,0x520D50,0x60F4E0,0x6456E6))
    # Shared deleting destructor used by the texture-conversion vtables;
    # observed through the virtual call at 0x64d511.
    addresses.update((0x6526F1,0x6527C2))
    # Shared object virtual method invoked through vtable slot 1 at 0x55f039.
    addresses.add(0x4CB850)
    # Shared callback supplied by object constructors (e.g. 0x5894fc),
    # invoked indirectly at 0x55ce4d.
    addresses.add(0x557DC0)
    # Binary-search comparator passed at 0x4834bf and invoked at 0x662e80.
    addresses.add(0x482230)
    # Resource callback supplied at 0x483672 to registration routine 0x5fdf20.
    addresses.add(0x4828B0)
    # Registered callback 0x4c0110 is invoked by dispatcher 0x5e811f.
    # Object cleanup callback 0x5210f0 is reached while leaving startup playback.
    addresses.update((0x4C0110,0x5E8C40,0x559230,0x55E4F0,0x61E7B0,0x5210F0,0x4AB3E0))
    return sorted(addresses)


def startup_entries(data, assembly=""):
    """Read verified startup initializer and callback tables from the original image."""
    if hashlib.sha256(data).hexdigest()!=SHA256:
        raise ValueError("Startup tables belong to an unsupported executable")
    pe=struct.unpack_from("<I",data,0x3c)[0]
    section_table=pe+24+struct.unpack_from("<H",data,pe+20)[0]
    sections=[struct.unpack_from("<8sIIII",data,section_table+40*i)
              for i in range(struct.unpack_from("<H",data,pe+6)[0])]
    entries=set()
    # The first cell is the optional pre-initializer; the two arrays are the
    # error-returning C initializers and the void C++ global constructors.
    # The final eight-cell table is the printf state machine used during startup;
    # 0x666c98..0x666ca9 bounds its index to 0..7 before the indirect jump.
    # Constructor 0x60ae50 installs the six-method table at 0x68b2c0.
    # Constructors 0x5fe0cc and 0x5fe13e install the two-method table at 0x68ae84;
    # startup calls its second method through 0x4e4c36.
    # D3DX initializer 0x6533c3 copies 0x39 scalar function pointers from
    # 0x6bc9f8 into its active dispatch table when optional CPU features are absent.
    # CRT numeric parser 0x670da3 bounds its state to 0..11 before dispatching
    # through 0x67114d. It becomes reachable through the CRT callbacks above.
    # Asset dispatch 0x60162a bounds ECX to 0..8; intervening MOVZX/LEA
    # preserve flags and ECX before JA and the indexed jump at 0x60163b.
    # Texture-record dispatch 0x5efce6 bounds EAX to 0..5, with a
    # flag-preserving store before JA and its jump through 0x5efd14.
    # Base object constructors install the twelve-method table at 0x67bcc4;
    # its shared methods include the observed 0x4cb850 and 0x55bce0 callbacks.
    # Constructor 0x55edb3 installs the fourteen-method derived table at
    # 0x681388; slot 11 is the observed callback 0x55d330.
    # Object constructors also install the nineteen-method table at 0x67bd48;
    # slot 16 contains 0x4ca810, reached from 0x55d469.
    # The derived table at 0x682e58 contains callback 0x56b980 in slot 2,
    # invoked by 0x590554. All fifteen contiguous methods precede non-code data.
    # Constructors 0x5621a2 and 0x56e332 install the base/derived tables
    # at 0x681db0 and 0x682678; slot 19 is 0x562440, called at 0x589521.
    # Constructor 0x55ed22 installs the fourteen-method sibling at 0x681350;
    # its slot 11 (0x55e190) is invoked by 0x58daea.
    # The six-way dispatch through 0x5590a8 is bounded before its PUSH ESI;
    # its last branch is the observed 0x55901f entry.
    # Constructors/destructor stores at 0x555fc3, 0x5560a9 and 0x55720d
    # install 0x6813c0; slot 14 is 0x55ccf0, reached from 0x56086a.
    # Bounded four-way switch at 0x55e838 dispatches through 0x55e9f4.
    # Derived object table 0x683358 has nineteen methods; slot 14 is
    # 0x581140, invoked by the virtual call at 0x560962.
    # Its nineteen-method sibling at 0x6833a8 supplies 0x583720 for the
    # following initialization call (return address 0x560975).
    # Nineteen-method siblings 0x6817a0/0x6817f0 include the shared
    # callbacks at slots 16..18 and the observed slot-13 target 0x55a920.
    # Five-way dispatch at 0x55d6d4 bounds EAX to 0..4 before its
    # flag-preserving PUSH/MOV and jump through 0x55d920.
    # The two-method callback object table at 0x6795dc begins with 0x4821e0,
    # reached through slot zero by resource callback 0x4828b0.
    # Adjacent resource-object tables at 0x6795ac..0x6795dc contain their
    # constructors and stream methods, including slot-5 callback 0x4827a0.
    # Dispatcher 0x4bec5d bounds the input to 0..11 and remaps it through
    # 0x4bffa8 (values 0..4) into the five-target table at 0x4bff94.
    # Object dispatch at 0x55bd6c bounds EAX to 0..5 for table 0x55c014.
    # Constructor 0x55b7aa installs the ten-method table at 0x681084;
    # its slot 9 is called at 0x55c1fe (return address 0x55c204).
    # Input reached switch 0x563835: EAX is bounded to 0..39 before table
    # 0x564f80. Its nested switch 0x563870 bounds EAX to 0..3 at 0x565020.
    # Dispatch 0x5653ed uses table 0x565f14 after unsigned EAX <= 0x24;
    # intervening pushes and MOV EDI/EBP immediates preserve EAX and flags.
    # Nested menu switches: 0x564653 bounds EAX to 0..27 at 0x565030;
    # 0x565c2d bounds EAX to 0..3 at 0x565fa8.
    # The three sibling submenu switches at 0x5650a0/0x5650b0/0x5650c0
    # each compare EAX with 3 before unsigned dispatch (MOV stores preserve flags).
    # Options dispatch at 0x580421 uses seven entries after unsigned EAX <= 6;
    # PUSH ESI / MOV ESI, ECX preserve the bounds-check flags.
    # Options selection dispatch 0x575c43 and its sibling 0x575cec each
    # bound EAX to 0..11. Include the neighboring menu dispatch families:
    # each uses CMP / unsigned JA with only flag-preserving PUSH/MOV between.
    # Constructor installs 0x68ca44; its sixth method handles the callback
    # reached through 0x4e6235 during shutdown.
    # Constructor-installed six-method table 0x67acbc supplies 0x4ab470,
    # invoked through slot 5 at 0x4bf40e.
    # Actor state records consumed by 4b8990 have a callback every 24 bytes.
    # Include the complete contiguous record table, including new-game 5bcc90.
    # memmove (663250) indexes alignment, word-count and byte-tail tables,
    # including the backwards-copy table indexed with a negated word count.
    for start,end in ((0x681f38,0x681f84),(0x6632b4,0x6632c0),(0x663330,0x663350),(0x66339c,0x6633ac),
                      (0x663440,0x66344c),(0x6634cc,0x6634ec),(0x663538,0x663548),(0x6a4d70,0x6a6360),(0x681e58,0x681e80),(0x67acbc,0x67acd4),(0x68ca44,0x68ca5c),*sorted(translated_switches(assembly,data,sections)),(0x575d88,0x575db8),(0x575db8,0x575de8),
                      (0x575254,0x57526c),(0x575760,0x575774),
                      (0x576248,0x576298),(0x5769e8,0x576a28),
                      (0x5774d0,0x5774ec),(0x578e10,0x578e6c),
                      (0x57e35c,0x57e3d4),(0x57f81c,0x57f838),
                      (0x58063c,0x580658),(0x6bfd2c,0x6bfd30),(0x69b42c,0x69b448),(0x69b000,0x69b428),
                      (0x6673fe,0x66741e),(0x68b2c0,0x68b2d8),(0x68ae84,0x68ae8c),
                      (0x6bc9f8,0x6bcadc),(0x67114d,0x67117d),(0x60186c,0x601890),
                      (0x5efd14,0x5efd2c),(0x67bcc4,0x67bcf4),(0x681388,0x6813c0),
                      (0x67bd48,0x67bd94),(0x682e58,0x682e94),
                      (0x681db0,0x681e00),(0x682678,0x6826cc),(0x681350,0x681388),
                      (0x5590a8,0x5590c0),(0x6813c0,0x68140c),(0x55e9f4,0x55ea04),
                      (0x683358,0x6833a4),(0x6833a8,0x6833f4),
                      (0x6817a0,0x6817ec),(0x6817f0,0x68183c),(0x55d920,0x55d934),
                      (0x6795ac,0x6795e4),(0x4bff94,0x4bffa8),(0x55c014,0x55c02c),
                      (0x681084,0x6810ac),(0x564f80,0x565020),(0x565020,0x565030),(0x565f14,0x565fa8),(0x565030,0x5650a0),(0x565fa8,0x565fb8),(0x5650a0,0x5650d0)):
        for _,_,rva,raw_size,offset in sections:
            base=0x400000+rva
            if base<=start and end<=base+raw_size:
                for address in range(start,end,24 if start==0x6a4d70 else 4):
                    target=struct.unpack_from("<I",data,offset+address-base)[0]
                    if target and not 0x401000<=target<0x676000:
                        raise ValueError(f"Invalid startup target {target:#x}")
                    if target:entries.add(target)
                break
        else:
            raise ValueError("Startup table is outside the executable")
    # The startup UI objects share a nineteen-method base interface. Require a
    # decoded constructor store, the two known inherited method slots, and a
    # full code-pointer span in .rdata before including a derived table.
    stores={int(value,16) for value in re.findall(r"mov dword \[[^\]]+\], 0x([0-9a-f]+)",assembly)}
    for name,_,rva,raw_size,offset in sections:
        if name.rstrip(b"\0")!=b".rdata":continue
        base=0x400000+rva
        for address in stores:
            if not base<=address<=base+raw_size-76:continue
            methods=struct.unpack_from("<19I",data,offset+address-base)
            inherited=(methods[1:3]==(0x4cb850,0x55c030) or
                       (methods[1] in (0x4cb850,0x4cb610) and methods[2:4]==(0x55bce0,0x55bd20)))
            # Shorter derived tables end at a zero cell, e.g. 0x68201c has 14
            # methods (slot 3 0x566aa0 is called at 0x55c078).
            length=methods.index(0) if 0 in methods else 19
            if inherited and length>=4 and all(0x401000<=v<0x676000 for v in methods[:length]):
                entries.update(methods[:length])
                # Derived menu objects also dispatch through slot 19 (offset
                # 0x4c), e.g. Options 0x578e05 -> 0x578e70. Some tables end
                # after slot 18; include the next cell only when it is a code
                # pointer. An adjacent table's first method is also a valid root.
                if length==19 and address+80<=base+raw_size:
                    target=struct.unpack_from("<I",data,offset+address-base+76)[0]
                    if 0x401000<=target<0x676000:entries.add(target)
    # Callback immediates stored into objects, e.g.
    # constructor 0x610230 stores 0x610210 at [eax]. Only accept .text targets
    # that follow INT3 padding, i.e. function starts, not interior addresses.
    # Stored, loaded into a register (getter 0x4707f0 returns 0x46c4c0) or pushed.
    immediates={int(value,16) for value in re.findall(
        r"(?:mov (?:dword \[[^\]]+\]|e[a-z]{2}), |\bpush (?:dword )?)0x([0-9a-f]+)",assembly)}
    text=[(0x400000+rva,raw_size,offset) for name,_,rva,raw_size,offset in sections
          if name.rstrip(b"\0")==b".text"][0]
    decode=decoder()
    # Bytes inside already decoded instructions are never entry points (0x4b0039).
    interior=set()
    for address,encoding in re.findall(r"^([0-9a-f]{8})  ([0-9a-f]+) ",assembly,re.M):
        start=int(address,16);interior.update(range(start+1,start+len(encoding)//2))
    def function_start(v,aligned=True):
        if v in interior:return False
        if not (0x401000<=v<0x676000 and text[0]+3<=v<text[0]+text[1]):return False
        # Follows INT3 padding, or a RET / RET n when already 16-byte aligned
        # (0x5216b0 follows RET 8). A C2 byte inside ADD (0x4b0031) is not RET.
        o=text[2]+v-text[0]
        # Instruction immediates may name unaligned D3DX functions (0x655884).
        after_ret=(v%16==0 or not aligned) and (data[o-1]==0xc3 or
                               (data[o-3]==0xc2 and data[o-1]==0 and data[o-2]%4==0))
        # ...or after an in-code jump table whose last cell is a code address (0x4700a0).
        after_table=v%16==0 and 0x401000<=struct.unpack_from("<I",data,o-4)[0]<0x676000
        if not (data[o-1]==0xcc or after_ret or after_table):return False
        # Data tables also follow INT3 padding (0x65fd20): require straight-line
        # code that reaches RET/JMP without an invalid instruction.
        address=v
        for _ in range(256):
            i=decode(data[text[2]+address-text[0]:text[2]+address-text[0]+15],address)
            if not i:return False
            mnemonic=i.text.split()[0] if i.text else b""
            if mnemonic in (b"ret",b"jmp"):return True
            if mnemonic==b"int3":return False
            address+=i.length
        return True
    entries.update(v for v in immediates if function_start(v,aligned=False))
    # Aligned .data/.rdata cells holding function starts: vtables and callback
    # tables, including statically initialized objects without constructors
    # (0x6a8494 -> one-method table 0x67ff80 -> 0x523340).
    for name,_,rva,raw_size,offset in sections:
        if name.rstrip(b"\0") not in (b".data",b".rdata"):continue
        entries.update(filter(function_start,struct.unpack_from(f"<{raw_size//4}I",data,offset)))
    # Absolute indirect tail jumps (not computed tables) identify pointer cells
    # directly. Include their on-disk code targets, e.g. D3DX scalar dispatch.
    # Imports, zero-initialized cells and non-code values are not translation roots.
    for slot in {int(value,16) for value in re.findall(r"\bjmp dword \[0x([0-9a-f]+)\]",assembly)}:
        for _,_,rva,raw_size,offset in sections:
            base=0x400000+rva
            if base<=slot and slot+4<=base+raw_size:
                target=struct.unpack_from("<I",data,offset+slot-base)[0]
                if 0x401000<=target<0x676000:entries.add(target)
                break
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, nargs="?")
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    if args.self_check:
        switch=";cmp eax, 0x6\n;push esi\n;mov esi, ecx\n;ja near loc_580635\n;jmp dword [eax*4+0x58063c]"
        assert translated_switches(switch)=={(0x58063c,0x580658)}
        assert not translated_switches(switch.replace("mov esi, ecx","mov eax, ecx"))
        assert not translated_switches(switch.replace("ja near","jg near"))
        assert not translated_switches(switch.replace("push esi","inc ecx"))
        vector=";cmp eax, 0x3\n;fsqrt\n;movss xmm0, [edx]\n;lea edx, [esp+0xc]\n;ja near loc_5DA03E\n;jmp dword [eax*4+0x5da044]"
        assert translated_switches(vector)=={(0x5da044,0x5da054)}
        assert not translated_switches(vector.replace("fsqrt","fcomi st0, st1"))
        assert translated_switches(vector.replace("cmp eax, 0x3","mov edx, 0x3\n;cmp eax, edx"))=={(0x5da044,0x5da054)}
        assert translated_switches(vector.replace("fsqrt","mov [ecx+0x8], al"))=={(0x5da044,0x5da054)}
        biased=";lea ecx, [eax-0x1]\n;cmp ecx, 0x2\n;ja near loc_401100\n;movzx edx, byte [eax+0x402000]\n;jmp dword [edx*4+0x403000]"
        assert translated_switches(biased,b"\0\0\2\1\0",[(b"",0,0x2000,5,0)])=={(0x403000,0x40300c)}
        load=";cmp eax, 0xd\n;ja near loc_4E475F\n;push dword 0x70ce4c;call x86_mov_reg_mem_32;mov edx, [esp - 4]\n;jmp dword [eax*4+0x4e4790]"
        assert translated_switches(load)=={(0x4e4790,0x4e47c8)}
        remapped=";cmp eax, 0x3\n;ja short loc_401100\n;movzx edx, byte [eax+0x402000]\n;jmp dword [edx*4+0x403000]"
        assert translated_switches(remapped,b"\0\2\1\2",[(b"",0,0x2000,4,0)])=={(0x403000,0x40300c)}
        recovery = {"input_sha256": SHA256, "seeds": ["0x401000"]}
        tables = [{"targets": ["0x401020", "0x401020"]}]
        decoded = {0x401000, 0x401020, 0x4AA9F0, 0x4BD820, 0x567E20, 0x5693D0}
        assert entry_points(recovery, tables, decoded) == sorted(decoded | {0x67099B,0x66979F,0x4CB670,0x612A90,0x60F2B0,0x60DCF0,0x613820,0x529280,0x60AF40,0x6668B7,0x666545,0x6665AA,0x666509,0x666590,0x520D10,0x520D50,0x60F4E0,0x6456E6,0x6526F1,0x6527C2,0x4CB850,0x557DC0,0x482230,0x4828B0,0x4C0110,0x5E8C40,0x559230,0x55E4F0,0x61E7B0,0x5210F0,0x4AB3E0})
        try:
            entry_points(recovery, tables, decoded - {0x401020})
        except ValueError:
            pass
        else:
            raise AssertionError("Accepted an undecoded entry")
        assert 0x6629A9 in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert {0x5FE160,0x5F2620} <= startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x670DB3 in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x6017C4 in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x5EFCFA in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert {0x55BCE0,0x55BD20,0x55BD50} <= startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x55D330 in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x55E190 in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x55901F in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x55CCF0 in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x55E83F in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x581140 in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x583720 in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert {0x55A920,0x55A990} <= startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x55D8FE in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x4821E0 in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x4827A0 in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x4BEC6B in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x55BD73 in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x564A0F in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x5649F7 in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x5653F4 in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert {0x56383E,0x563877} <= startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x559D10 in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        original=(ROOT.parent / "TrueCrime.exe").read_bytes()
        assert {0x580428,0x58047A,0x58050C,0x58053F,0x580591,0x5805FE,0x58061D} <= startup_entries(original)
        assert 0x575C80 in startup_entries(original)
        assert 0x578E70 in startup_entries(original,"mov dword [esi], 0x683218")
        assert 0x579240 in startup_entries(original,"mov dword [esi], 0x6833f8")
        assert 0x55AB30 in startup_entries(original,";mov dword [esi], 0x681e08")
        assert {0x4CA810,0x4CA820,0x4CA850} <= startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x56B980 in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert {0x562440,0x562210,0x562220,0x562230} <= startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes())
        assert 0x523340 in startup_entries(original)
        assert 0x65FD20 not in startup_entries(original)
        assert 0x5216B0 in startup_entries(original,"mov dword [eax], 0x5216b0")
        assert 0x46C4C0 in startup_entries(original,"mov eax, 0x46c4c0")
        assert 0x4700A0 in startup_entries(original,"mov eax, 0x4700a0")
        assert 0x655884 in startup_entries(original,"mov dword [eax+0xc], 0x655884")
        assert 0x4B0034 not in startup_entries(original,"mov dword [eax], 0x4b0034")
        assert 0x566AA0 in startup_entries(original,"mov dword [esi], 0x68201c")
        assert 0x610210 in startup_entries(original,"mov dword [eax], 0x610210")
        assert 0x610214 not in startup_entries(original,"mov dword [eax], 0x610214")
        assert 0x64708A in startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes(),"jmp dword [0x6bc994]")
        return
    if args.directory is None:
        parser.error("directory is required")
    recovery = json.loads((ROOT / "analysis/recovery.json").read_text())
    tables = json.loads((ROOT / "analysis/jump-tables.json").read_text())
    assembly=(ROOT / "analysis/reachable.asm").read_text()
    decoded = {int(line.split()[0], 16) for line in assembly.splitlines()}
    # SRW expands beyond the original recovery roots. Reuse its decoded
    # constructor stores with the same validated vtable shape, so refreshes
    # include sibling methods instead of waiting for each indirect call.
    constructor_assembly=assembly
    for source in sorted(args.directory.glob("seg*_code.llinc")):
        constructor_assembly+="\n"+source.read_text()
    addresses = sorted(set(entry_points(recovery, tables, decoded)) |
                       startup_entries((ROOT.parent / "TrueCrime.exe").read_bytes(),constructor_assembly))
    args.directory.joinpath("noret_procedures.sci").write_text(
        "".join(f"loc_{address:X}\n" for address in NORETURN_ENTRIES))
    args.directory.joinpath("global_aliases.sci").write_text(
        "".join(f"loc_{address:X},tc_loc_{address:X}\n" for address in addresses)
        + "loc_6A4CC0,tc_data_6A4CC0\n")
    args.directory.joinpath("entry-seeds.json").write_text(json.dumps({
        "input_sha256": SHA256, "entries": [hex(value) for value in addresses],
        "method": "recovery roots, original exports, bounded switches, verified startup tables/fallbacks and absolute indirect-jump pointer targets",
        "complete_code_coverage": False,
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
