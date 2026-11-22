"""
patch_ue4ss_splitgate2.py
-------------------------
Patches UE4SS v4.0.0 (Git SHA #30afe5ff) UE4SS.dll to translate Splitgate 2's
obfuscated/shuffled 64-bit EClassCastFlags back to standard Unreal Engine 5.5
EClassCastFlags at runtime.

Idempotent: backs up UE4SS.dll -> UE4SS.dll.orig on first run, and always
patches cleanly from UE4SS.dll.orig.
"""

import ctypes
import os
import shutil
import struct
import sys

DEFAULT_DLL_NAME = "UE4SS.dll"

# Standard UE 5.5 EClassCastFlags bit indices
UE55_BITS = {
    'UField': 0,
    'FInt8Property': 1,
    'UEnum': 2,
    'UStruct': 3,
    'UScriptStruct': 4,
    'UClass': 5,
    'FByteProperty': 6,
    'FIntProperty': 7,
    'FFloatProperty': 8,
    'FUInt64Property': 9,
    'FClassProperty': 10,
    'FUInt32Property': 11,
    'FInterfaceProperty': 12,
    'FNameProperty': 13,
    'FStrProperty': 14,
    'FProperty': 15,
    'FObjectProperty': 16,
    'FBoolProperty': 17,
    'FUInt16Property': 18,
    'UFunction': 19,
    'FStructProperty': 20,
    'FArrayProperty': 21,
    'FInt64Property': 22,
    'FDelegateProperty': 23,
    'FNumericProperty': 24,
    'FMulticastDelegateProperty': 25,
    'FObjectPropertyBase': 26,
    'FWeakObjectProperty': 27,
    'FLazyObjectProperty': 28,
    'FSoftObjectProperty': 29,
    'FTextProperty': 30,
    'FInt16Property': 31,
    'FDoubleProperty': 32,
    'FSoftClassProperty': 33,
    'UPackage': 34,
    'ULevel': 35,
    'AActor': 36,
    'APlayerController': 37,
    'APawn': 38,
    'USceneComponent': 39,
    'UPrimitiveComponent': 40,
    'USkinnedMeshComponent': 41,
    'USkeletalMeshComponent': 42,
    'UBlueprint': 43,
    'UDelegateFunction': 44,
    'UStaticMeshComponent': 45,
    'FMapProperty': 46,
    'FSetProperty': 47,
    'FEnumProperty': 48,
    'USparseDelegateFunction': 49,
    'FMulticastInlineDelegateProperty': 50,
    'FMulticastSparseDelegateProperty': 51,
    'FFieldPathProperty': 52,
    'FOptionalProperty': 56,
    'FUtf8StrProperty': 60,
    'FAnsiStrProperty': 61,
}

# Splitgate 2 (PortalWars2-Win64-Shipping.exe) shuffled EClassCastFlags bit indices
SG2_BITS = {
    'UField': 30,
    'FInt8Property': 38,
    'UEnum': 25,
    'UStruct': 58,
    'UScriptStruct': 45,
    'UClass': 3,
    'FByteProperty': 46,
    'FIntProperty': 39,
    'FFloatProperty': 1,
    'FUInt64Property': 52,
    'FClassProperty': 61,
    'FUInt32Property': 12,
    'FInterfaceProperty': 23,
    'FNameProperty': 31,
    'FStrProperty': 41,
    'FProperty': 44,
    'FObjectProperty': 35,
    'FBoolProperty': 26,
    'FUInt16Property': 20,
    'UFunction': 19,
    'FStructProperty': 18,
    'FArrayProperty': 55,
    'FInt64Property': 60,
    'FDelegateProperty': 7,
    'FNumericProperty': 51,
    'FMulticastDelegateProperty': 33,
    'FObjectPropertyBase': 13,
    'FWeakObjectProperty': 32,
    'FLazyObjectProperty': 16,
    'FSoftObjectProperty': 15,
    'FTextProperty': 47,
    'FInt16Property': 50,
    'FDoubleProperty': 4,
    'FSoftClassProperty': 48,
    'UPackage': 56,
    'ULevel': 11,
    'AActor': 29,
    'APlayerController': 40,
    'APawn': 6,
    'USceneComponent': 42,
    'UPrimitiveComponent': 17,
    'USkinnedMeshComponent': 22,
    'USkeletalMeshComponent': 21,
    'UBlueprint': 24,
    'UDelegateFunction': 14,
    'UStaticMeshComponent': 8,
    'FMapProperty': 37,
    'FSetProperty': 49,
    'FEnumProperty': 28,
    'USparseDelegateFunction': 57,
    'FMulticastInlineDelegateProperty': 34,
    'FMulticastSparseDelegateProperty': 27,
    'FFieldPathProperty': 9,
    'FOptionalProperty': 10,
    'FUtf8StrProperty': 5,
    'FAnsiStrProperty': 36,
}


def build_lut() -> bytes:
    lut = [0xFF] * 64
    for name, sg2_bit in SG2_BITS.items():
        assert lut[sg2_bit] == 0xFF
        lut[sg2_bit] = UE55_BITS[name]
    return bytes(lut)


def build_stub(code_va: int, data_va: int):
    """
    Assemble the x64 remapping code + 64-byte LUT placed at code_va,
    referencing ring_idx at data_va + 0x00 and ring_buf[4096] at data_va + 0x40.
    Returns (code_bytes, offsets_dict).
    """
    lut_off = 0x100
    lut_va = code_va + lut_off
    ring_idx_va = data_va + 0x00
    ring_buf_va = data_va + 0x40

    buf = bytearray()
    offs = {}

    # 1. tail_remap_val_rsp28: add rsp, 0x28; jmp remap_val
    offs['tail_remap_val_rsp28'] = len(buf)
    buf += b'\x48\x83\xc4\x28'
    j1_pos = len(buf)
    buf += b'\xeb\x00'

    # 2. tail_remap_val_rsp48: add rsp, 0x48; jmp remap_val
    offs['tail_remap_val_rsp48'] = len(buf)
    buf += b'\x48\x83\xc4\x48'
    j2_pos = len(buf)
    buf += b'\xeb\x00'

    # 3. tail_remap_ptr_rsp20_rbx: add rsp, 0x20; pop rbx; jmp remap_ptr
    offs['tail_remap_ptr_rsp20_rbx'] = len(buf)
    buf += b'\x48\x83\xc4\x20\x5b'
    j3_pos = len(buf)
    buf += b'\xeb\x00'

    # 4. remap_val (Windows x64 leaf: input rax, output rax; clobbers rcx,rdx,r8,r9,r10)
    offs['remap_val'] = len(buf)
    buf += b'\x49\x89\xc0'             # mov r8, rax
    buf += b'\x31\xc0'                 # xor eax, eax
    buf += b'\x4d\x85\xc0'             # test r8, r8
    jz_done_pos = len(buf)
    buf += b'\x74\x00'                 # jz .done
    # lea r9, [rip + lut_va]
    buf += b'\x4c\x8d\x0d'
    disp = lut_va - (code_va + len(buf) + 4)
    buf += struct.pack('<i', disp)

    loop_pos = len(buf)
    buf += b'\x49\x0f\xbc\xc8'         # bsf rcx, r8
    buf += b'\x41\x0f\xb6\x0c\x09'     # movzx ecx, byte ptr [r9 + rcx]
    buf += b'\x80\xf9\x40'             # cmp cl, 64
    jae_skip_pos = len(buf)
    buf += b'\x73\x00'                 # jae .skip
    buf += b'\xba\x01\x00\x00\x00'     # mov edx, 1
    buf += b'\x48\xd3\xe2'             # shl rdx, cl
    buf += b'\x48\x09\xd0'             # or rax, rdx

    skip_pos = len(buf)
    buf += b'\x4d\x8d\x50\xff'         # lea r10, [r8 - 1]
    buf += b'\x4d\x21\xd0'             # and r8, r10
    jnz_loop_pos = len(buf)
    buf += b'\x75' + struct.pack('<b', loop_pos - (jnz_loop_pos + 2))

    done_pos = len(buf)
    buf += b'\xc3'                     # ret

    # 5. remap_ptr (input rax = uint64*, output rax = &ring_buf[slot])
    offs['remap_ptr'] = len(buf)
    buf += b'\x48\x8b\x00'             # mov rax, [rax]
    buf += b'\xe8' + struct.pack('<i', offs['remap_val'] - (len(buf) + 5))  # call remap_val
    buf += b'\x41\xb8\x01\x00\x00\x00' # mov r8d, 1
    buf += b'\x4c\x8d\x0d'
    buf += struct.pack('<i', ring_idx_va - (code_va + len(buf) + 4))        # lea r9, [rip + ring_idx]
    buf += b'\xf0\x45\x0f\xc1\x01'     # lock xadd dword ptr [r9], r8d
    buf += b'\x41\x81\xe0\xff\x0f\x00\x00'  # and r8d, 0x0FFF
    buf += b'\x4c\x8d\x0d'
    buf += struct.pack('<i', ring_buf_va - (code_va + len(buf) + 4))        # lea r9, [rip + ring_buf]
    buf += b'\x4f\x8d\x0c\xc1'         # lea r9, [r9 + r8*8]
    buf += b'\x49\x89\x01'             # mov [r9], rax
    buf += b'\x4c\x89\xc8'             # mov rax, r9
    buf += b'\xc3'                     # ret

    # Patch local short jumps
    buf[j1_pos + 1] = (offs['remap_val'] - (j1_pos + 2)) & 0xFF
    buf[j2_pos + 1] = (offs['remap_val'] - (j2_pos + 2)) & 0xFF
    buf[j3_pos + 1] = (offs['remap_ptr'] - (j3_pos + 2)) & 0xFF
    buf[jz_done_pos + 1] = (done_pos - (jz_done_pos + 2)) & 0xFF
    buf[jae_skip_pos + 1] = (skip_pos - (jae_skip_pos + 2)) & 0xFF

    assert len(buf) <= lut_off, f"Code grew past lut_off: {len(buf)}"
    buf += b'\xcc' * (lut_off - len(buf))
    buf += build_lut()
    # Pad to 0x200 bytes (file alignment)
    buf += b'\x00' * (0x200 - len(buf))
    return bytes(buf), offs


def self_test_x64():
    """Execute the assembled x64 remap_val and remap_ptr natively on this CPU to verify 100% correctness."""
    kernel32 = ctypes.windll.kernel32
    kernel32.VirtualAlloc.restype = ctypes.c_void_p
    kernel32.VirtualAlloc.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32]
    kernel32.VirtualFree.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32]

    # Allocate 0xA000 bytes: page 0 = code (0x1000), pages 1..9 = data (0x9000)
    mem = kernel32.VirtualAlloc(None, 0xA000, 0x3000, 0x40)  # MEM_COMMIT|MEM_RESERVE, PAGE_EXECUTE_READWRITE
    assert mem, "VirtualAlloc failed"
    try:
        code_va = 0x013d4000
        data_va = 0x013d5000
        stub, offs = build_stub(code_va, data_va)
        ctypes.memmove(mem, stub, len(stub))

        # Write tiny wrapper: mov rax, rcx; jmp remap_val  (to call remap_val with Win64 arg in rcx)
        wrap_val_off = 0x180
        w1 = b'\x48\x89\xc8\xe9' + struct.pack('<i', offs['remap_val'] - (wrap_val_off + 8))
        ctypes.memmove(mem + wrap_val_off, w1, len(w1))

        # Wrapper for remap_ptr: mov rax, rcx; jmp remap_ptr
        wrap_ptr_off = 0x190
        w2 = b'\x48\x89\xc8\xe9' + struct.pack('<i', offs['remap_ptr'] - (wrap_ptr_off + 8))
        ctypes.memmove(mem + wrap_ptr_off, w2, len(w2))

        fn_val = ctypes.CFUNCTYPE(ctypes.c_uint64, ctypes.c_uint64)(mem + wrap_val_off)
        fn_ptr = ctypes.CFUNCTYPE(ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint64))(mem + wrap_ptr_off)

        test_cases = [
            ('Zero',                0,                  0),
            ('FSoftObjectProperty', 0x000010004000A000, (1<<0)|(1<<15)|(1<<26)|(1<<29)),
            ('FSoftClassProperty',  0x000110004000A000, (1<<0)|(1<<15)|(1<<26)|(1<<29)|(1<<33)),
            ('FIntProperty',        0x0008108040000000, (1<<0)|(1<<15)|(1<<24)|(1<<7)),
            ('FBoolProperty',       0x0000100044000000, (1<<0)|(1<<15)|(1<<17)),
            ('FObjectProperty',     0x0000100840002000, (1<<0)|(1<<15)|(1<<26)|(1<<16)),
            ('FStructProperty',     0x0000100040040000, (1<<0)|(1<<15)|(1<<20)),
            ('FArrayProperty',      0x0080100040000000, (1<<0)|(1<<15)|(1<<21)),
            ('UClass',              (1<<30)|(1<<58)|(1<<3),  (1<<0)|(1<<3)|(1<<5)),
            ('UFunction',           (1<<30)|(1<<58)|(1<<19), (1<<0)|(1<<3)|(1<<19)),
            ('UEnum',               (1<<30)|(1<<25),         (1<<0)|(1<<2)),
            ('AActor',              (1<<29),                 (1<<36)),
        ]
        for name, inp, exp in test_cases:
            got = fn_val(inp)
            assert got == exp, f"remap_val FAILED for {name}: got=0x{got:016X}, exp=0x{exp:016X}"

            box = ctypes.c_uint64(inp)
            ptr = fn_ptr(ctypes.byref(box))
            got_p = ptr.contents.value
            assert got_p == exp, f"remap_ptr FAILED for {name}: got=0x{got_p:016X}, exp=0x{exp:016X}"

        # Also test ring wraparound across 5000 consecutive calls
        last_ptrs = []
        for idx in range(5000):
            v = (1 << 30) | (1 << 58) | (1 << 3)
            box = ctypes.c_uint64(v)
            p = fn_ptr(ctypes.byref(box))
            assert p.contents.value == ((1<<0)|(1<<3)|(1<<5))
            if idx >= 4990:
                last_ptrs.append(ctypes.addressof(p.contents))
        assert len(set(last_ptrs)) == 10, "Ring buffer slots did not advance!"
        print("[OK] Live x64 CPU self-test PASSED for all 12 test cases + 5000-call ring wraparound!")
    finally:
        kernel32.VirtualFree(mem, 0, 0x8000)


def patch_ue4ss(dll_path: str):
    orig_path = dll_path + ".orig"
    if not os.path.exists(orig_path):
        shutil.copy2(dll_path, orig_path)
        print(f"[OK] Backed up original DLL to {orig_path}")
    else:
        print(f"[INFO] Using existing backup {orig_path}")

    with open(orig_path, "rb") as f:
        data = bytearray(f.read())

    pe_off = struct.unpack_from('<I', data, 0x3C)[0]
    assert data[pe_off:pe_off+4] == b'PE\0\0'
    n_sec = struct.unpack_from('<H', data, pe_off + 6)[0]
    opt_sz = struct.unpack_from('<H', data, pe_off + 20)[0]
    opt_off = pe_off + 24
    sec_off = opt_off + opt_sz

    sec_align = struct.unpack_from('<I', data, opt_off + 32)[0]
    file_align = struct.unpack_from('<I', data, opt_off + 36)[0]
    size_of_headers = struct.unpack_from('<I', data, opt_off + 60)[0]
    assert sec_off + (n_sec + 2) * 40 <= size_of_headers, "Not enough PE header space for 2 sections!"

    secs = []
    for i in range(n_sec):
        o = sec_off + i * 40
        vsz, va, rsz, ra = struct.unpack_from('<IIII', data, o + 8)
        secs.append((va, vsz, ra, rsz))

    def rva_to_off(rva):
        for va, vsz, ra, rsz in secs:
            if va <= rva < va + max(vsz, rsz):
                return ra + (rva - va)
        raise ValueError(f"RVA {hex(rva)} not mapped")

    def align_up(v, a):
        return (v + a - 1) & ~(a - 1)

    last_va, last_vsz, last_ra, last_rsz = secs[-1]
    code_va = align_up(last_va + last_vsz, sec_align)
    code_ra = align_up(len(data), file_align)
    code_vsz = 0x1000
    code_rsz = 0x200

    data_va = align_up(code_va + code_vsz, sec_align)
    data_ra = code_ra + code_rsz
    data_vsz = 0x9000
    data_rsz = 0x9000

    stub, offs = build_stub(code_va, data_va)
    assert len(stub) == code_rsz

    # Verify and patch all 8 epilogue sites
    patches = [
        # (rva, expected_bytes, target_label, pad_nop)
        (0x00b786c0, b'\x48\x83\xc4\x28\xc3',     'tail_remap_val_rsp28',     False),
        (0x00b786cd, b'\x48\x83\xc4\x28\xc3',     'tail_remap_val_rsp28',     False),
        (0x00b788dc, b'\x48\x83\xc4\x48\xc3',     'tail_remap_val_rsp48',     False),
        (0x00b788ec, b'\x48\x83\xc4\x48\xc3',     'tail_remap_val_rsp48',     False),
        (0x00b231e6, b'\x48\x83\xc4\x20\x5b\xc3', 'tail_remap_ptr_rsp20_rbx', True),
        (0x00b23227, b'\x48\x83\xc4\x20\x5b\xc3', 'tail_remap_ptr_rsp20_rbx', True),
        (0x00b23266, b'\x48\x83\xc4\x20\x5b\xc3', 'tail_remap_ptr_rsp20_rbx', True),
        (0x00b232a7, b'\x48\x83\xc4\x20\x5b\xc3', 'tail_remap_ptr_rsp20_rbx', True),
    ]

    for rva, expected, label, pad_nop in patches:
        fo = rva_to_off(rva)
        actual = bytes(data[fo:fo+len(expected)])
        assert actual == expected, f"Mismatch at 0x{rva:08x}: got {actual.hex(' ')}, expected {expected.hex(' ')}"
        tgt_va = code_va + offs[label]
        rel32 = tgt_va - (rva + 5)
        rep = b'\xe9' + struct.pack('<i', rel32) + (b'\x90' if pad_nop else b'')
        assert len(rep) == len(expected)
        data[fo:fo+len(rep)] = rep
        print(f"[OK] Patched 0x{rva:08x} -> 0x{tgt_va:08x} ({label})")

    # Patch FOptionalProperty::GetValueProperty & FOptionalPropertyLayout::GetValueProperty
    # (UE4SS computes RepNotifyFunc + 8 assuming RepNotifyFunc is the last field of FProperty,
    #  but in Splitgate 2 FOptionalProperty::ValueProperty is at 0x78 while RepNotifyFunc is at 0x60)
    fopt_patches = [
        (0x002a63ad, b'\x48\x63\x47\x30\x48\x83\xc0\x08',             b'\xb8\x78\x00\x00\x00\x90\x90\x90',             'FOptionalProperty::ValuePropertyOffset = 0x78'),
        (0x002a5d7d, b'\x8b\x5f\x30\xe8\x5b\x4e\x89\x00\x03\xc3',     b'\xb8\x78\x00\x00\x00\x90\x90\x90\x90\x90',     'FOptionalPropertyLayout::ValuePropertyOffset = 0x78'),
    ]
    for rva, expected, rep, desc in fopt_patches:
        fo = rva_to_off(rva)
        actual = bytes(data[fo:fo+len(expected)])
        assert actual == expected, f"Mismatch at 0x{rva:08x}: got {actual.hex(' ')}, expected {expected.hex(' ')}"
        data[fo:fo+len(rep)] = rep
        print(f"[OK] Patched 0x{rva:08x} ({desc})")

    # Append padding up to code_ra, then .sg2c, then .sg2d
    if len(data) < code_ra:
        data += b'\x00' * (code_ra - len(data))
    data += stub
    data += b'\x00' * data_rsz

    # Write section header for .sg2c (RX = 0x60000020)
    sh_c = struct.pack('<8sIIIIIIHHI', b'.sg2c\x00\x00\x00', code_vsz, code_va, code_rsz, code_ra, 0, 0, 0, 0, 0x60000020)
    # Write section header for .sg2d (RW = 0xC0000040)
    sh_d = struct.pack('<8sIIIIIIHHI', b'.sg2d\x00\x00\x00', data_vsz, data_va, data_rsz, data_ra, 0, 0, 0, 0, 0xC0000040)

    o_c = sec_off + n_sec * 40
    data[o_c:o_c+40] = sh_c
    data[o_c+40:o_c+80] = sh_d

    # Update NumberOfSections and SizeOfImage
    new_size_of_image = align_up(data_va + data_vsz, sec_align)
    struct.pack_into('<H', data, pe_off + 6, n_sec + 2)
    struct.pack_into('<I', data, opt_off + 56, new_size_of_image)

    with open(dll_path, "wb") as f:
        f.write(data)

    print(f"[SUCCESS] Wrote patched {dll_path}")
    print(f"          Added .sg2c @ VA 0x{code_va:08x} (RX) and .sg2d @ VA 0x{data_va:08x} (RW)")
    print(f"          New SizeOfImage = 0x{new_size_of_image:08x}, Sections = {n_sec + 2}")


if __name__ == "__main__":
    self_test_x64()
    if len(sys.argv) > 1:
        path = sys.argv[1]
    else:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        candidates = [
            os.path.join(script_dir, DEFAULT_DLL_NAME),
            os.path.join(script_dir, "ue4ss", DEFAULT_DLL_NAME),
            os.path.join(os.getcwd(), DEFAULT_DLL_NAME),
        ]
        path = next((p for p in candidates if os.path.exists(p)), None)
        if path is None:
            print("ERROR: Could not locate UE4SS.dll automatically.")
            print("Usage: python patch_ue4ss_splitgate2.py \"<path-to>\\PortalWars2\\Binaries\\Win64\\ue4ss\\UE4SS.dll\"")
            sys.exit(1)
    if not os.path.exists(path):
        print(f"ERROR: File not found: {path}")
        sys.exit(1)
    patch_ue4ss(path)
