#!/usr/bin/env python3
"""Decode a Luma3DS crash dump (crash_dump_*.dmp) against the LÖVE Potion ELF.

    symbolize.py DUMP ELF [--addr2line PATH] [--objdump PATH]

Prints the exception, the registers, whether the dump's code bytes match the
ELF (proof the ELF is the build that crashed), the function and source line
for PC, LR and every return-address-looking word on the dumped stack, and a
disassembly around PC.
"""
import argparse
import struct
import subprocess
import sys

EXCEPTIONS = {0: "FIQ", 1: "undefined instruction", 2: "prefetch abort",
              3: "data abort", 4: "SVC/assertion"}
FAULTS = {0x1: "alignment", 0x5: "translation (section)", 0x7: "translation (page)",
          0x3: "access flag (section)", 0x6: "access flag (page)",
          0x9: "domain (section)", 0xB: "domain (page)",
          0xD: "permission (section)", 0xF: "permission (page)", 0x8: "external abort"}
REG_NAMES = ["r%d" % i for i in range(13)] + ["sp", "lr", "pc", "cpsr",
             "dfsr", "ifsr", "far", "fpexc", "fpinst", "fpinst2"]


def load_dump(path):
    d = open(path, "rb").read()
    (m0, m1, vmin, vmaj, proc, core, typ, total, regsz, codesz, stacksz,
     addsz) = struct.unpack_from("<IIHHHHIIIIII", d, 0)
    if (m0, m1) != (0xDEADC0DE, 0xDEADCAFE):
        sys.exit("not a Luma3DS crash dump")
    off = 40
    regs = dict(zip(REG_NAMES, struct.unpack_from("<%dI" % (regsz // 4), d, off)))
    off += regsz
    code = d[off:off + codesz]
    off += codesz
    stack = d[off:off + stacksz]
    off += stacksz
    extra = d[off:off + addsz]
    return dict(version=f"{vmaj}.{vmin}", proc=proc, core=core, type=typ,
                regs=regs, code=code, stack=stack, extra=extra)


def load_segments(elf_path):
    e = open(elf_path, "rb").read()
    if e[:4] != b"\x7fELF" or e[4] != 1:
        sys.exit("ELF must be 32-bit")
    phoff, = struct.unpack_from("<I", e, 0x1C)
    phentsize, phnum = struct.unpack_from("<HH", e, 0x2A)
    segs = []
    for i in range(phnum):
        p_type, p_off, p_vaddr, _, p_filesz, _, p_flags, _ = struct.unpack_from(
            "<IIIIIIII", e, phoff + i * phentsize)
        if p_type == 1:
            segs.append((p_vaddr, e[p_off:p_off + p_filesz], p_flags))
    return segs


def addr2line(tool, elf, addrs):
    if not addrs:
        return {}
    out = subprocess.run([tool, "-f", "-C", "-i", "-p", "-e", elf] + [hex(a) for a in addrs],
                         capture_output=True, text=True).stdout.strip().split("\n")
    # -i can print extra "(inlined by)" lines; group them back per address
    result, cur = {}, -1
    for line in out:
        if line.startswith(" (inlined by)"):
            result[addrs[cur]] += "\n      " + line.strip()
        else:
            cur += 1
            if cur < len(addrs):
                result[addrs[cur]] = line.strip()
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump")
    ap.add_argument("elf")
    ap.add_argument("--addr2line", default="arm-none-eabi-addr2line")
    ap.add_argument("--objdump", default="arm-none-eabi-objdump")
    a = ap.parse_args()

    dump = load_dump(a.dump)
    r = dump["regs"]
    process = dump["extra"][:8].split(b"\0")[0].decode(errors="replace")
    print(f"Luma3DS dump v{dump['version']}, ARM{dump['proc']} core {dump['core']}, "
          f"{EXCEPTIONS.get(dump['type'], dump['type'])}, process {process}")
    if dump["type"] == 3:
        dfsr = r["dfsr"]
        status = (dfsr & 0xF) | ((dfsr >> 6) & 0x10)
        print(f"  {FAULTS.get(status, hex(status))} fault on a "
              f"{'write' if dfsr & 0x800 else 'read'} at 0x{r['far']:08x}")
    print("  " + "  ".join(f"{n}={r[n]:08x}" for n in REG_NAMES[:16]))

    segs = load_segments(a.elf)
    text = [(v, b) for v, b, f in segs if f & 1]
    lo = min(v for v, _ in text)
    hi = max(v + len(b) for v, b in text)

    # Prove the ELF is the binary that crashed: find the dumped code bytes.
    match = None
    for v, b in text:
        i = b.find(dump["code"])
        if i >= 0:
            match = v + i
    if match is None:
        print("WARNING: the dumped code bytes are not in this ELF -- it is not the "
              "build that crashed; symbols below may be wrong")
    else:
        print(f"ELF matches the crashed build (code dump found at 0x{match:08x})")

    words = struct.unpack_from("<%dI" % (len(dump["stack"]) // 4), dump["stack"])
    cands = []
    for i, w in enumerate(words):
        if lo <= w < hi and w & 1 == 0 and w not in cands:
            cands.append(w)
    names = addr2line(a.addr2line, a.elf, [r["pc"], r["lr"]] + cands)
    print(f"\nPC 0x{r['pc']:08x}  {names.get(r['pc'], '?')}")
    print(f"LR 0x{r['lr']:08x}  {names.get(r['lr'], '?') if r['lr'] else '(0)'}")
    print("\nCode addresses on the stack (likely callers, innermost first):")
    for w in cands:
        # a return address points after the BL; look up the call itself
        print(f"  0x{w:08x}  {names.get(w, '?')}")
    print("\nDisassembly around PC:")
    dis = subprocess.run([a.objdump, "-d", "-C", f"--start-address={r['pc'] - 32:#x}",
                          f"--stop-address={r['pc'] + 16:#x}", a.elf],
                         capture_output=True, text=True).stdout
    print("\n".join(l for l in dis.splitlines() if ":\t" in l or l.endswith(">:")))


if __name__ == "__main__":
    main()
