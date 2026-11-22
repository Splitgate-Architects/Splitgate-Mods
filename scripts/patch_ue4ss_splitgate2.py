#!/usr/bin/env python3
"""
Splitgate 2 / Arena Reloaded - UE4SS v4.0.0 Patcher (Python reference script)

Patches official UE4SS v4.0.0 (Git SHA #30afe5ff) for PortalWars2-Win64-Shipping.exe:
  1. Remaps Splitgate 2's permuted 64-bit EClassCastFlags back to stock UE 5.5 bits
     via an injected 64-byte LUT + lock-free ring-buffer stub (.sg2c / .sg2d).
  2. Fixes FOptionalProperty::ValuePropertyOffset & FOptionalPropertyLayout (0x78).
  3. Wraps RC::Unreal::UObject::ProcessEvent & Hook::InvokeProcessEventWithoutDetour
     to encrypt the UFunction* argument using Splitgate 2's native ProcessEvent
     encryption scheme (MainExe + 0x1268FE08, resolved ASLR-safely via x64 PEB).

Usage:
    python patch_ue4ss_splitgate2.py <path/to/ue4ss/UE4SS.dll>
"""

import hashlib
import os
import shutil
import struct
import sys

UE55_BITS = {
    'UField': 0, 'FInt8Property': 1, 'UEnum': 2, 'UStruct': 3, 'UScriptStruct': 4,
    'UClass': 5, 'FByteProperty': 6, 'FIntProperty': 7, 'FFloatProperty': 8,
    'FUInt64Property': 9, 'FClassProperty': 10, 'FUInt32Property': 11,
    'FInterfaceProperty': 12, 'FNameProperty': 13, 'FStrProperty': 14,
    'FProperty': 15, 'FObjectProperty': 16, 'FBoolProperty': 17,
    'FUInt16Property': 18, 'UFunction': 19, 'FStructProperty': 20,
    'FArrayProperty': 21, 'FInt64Property': 22, 'FDelegateProperty': 23,
    'FNumericProperty': 24, 'FMulticastDelegateProperty': 25,
    'FObjectPropertyBase': 26, 'FWeakObjectProperty': 27,
    'FLazyObjectProperty': 28, 'FSoftObjectProperty': 29, 'FTextProperty': 30,
    'FInt16Property': 31, 'FDoubleProperty': 32, 'FSoftClassProperty': 33,
    'UPackage': 34, 'ULevel': 35, 'AActor': 36, 'APlayerController': 37,
    'APawn': 38, 'USceneComponent': 39, 'UPrimitiveComponent': 40,
    'USkinnedMeshComponent': 41, 'USkeletalMeshComponent': 42, 'UBlueprint': 43,
    'UDelegateFunction': 44, 'UStaticMeshComponent': 45, 'FMapProperty': 46,
    'FSetProperty': 47, 'FEnumProperty': 48, 'USparseDelegateFunction': 49,
    'FMulticastInlineDelegateProperty': 50, 'FMulticastSparseDelegateProperty': 51,
    'FFieldPathProperty': 52, 'FOptionalProperty': 56, 'FUtf8StrProperty': 60,
    'FAnsiStrProperty': 61,
}

SG2_BITS = {
    'UField': 30, 'FInt8Property': 38, 'UEnum': 25, 'UStruct': 58,
    'UScriptStruct': 45, 'UClass': 3, 'FByteProperty': 46, 'FIntProperty': 39,
    'FFloatProperty': 1, 'FUInt64Property': 52, 'FClassProperty': 61,
    'FUInt32Property': 12, 'FInterfaceProperty': 23, 'FNameProperty': 31,
    'FStrProperty': 41, 'FProperty': 44, 'FObjectProperty': 35,
    'FBoolProperty': 26, 'FUInt16Property': 20, 'UFunction': 19,
    'FStructProperty': 18, 'FArrayProperty': 55, 'FInt64Property': 60,
    'FDelegateProperty': 7, 'FNumericProperty': 51,
    'FMulticastDelegateProperty': 33, 'FObjectPropertyBase': 13,
    'FWeakObjectProperty': 32, 'FLazyObjectProperty': 16,
    'FSoftObjectProperty': 15, 'FTextProperty': 47, 'FInt16Property': 50,
    'FDoubleProperty': 4, 'FSoftClassProperty': 48, 'UPackage': 56, 'ULevel': 11,
    'AActor': 29, 'APlayerController': 40, 'APawn': 6, 'USceneComponent': 42,
    'UPrimitiveComponent': 17, 'USkinnedMeshComponent': 22,
    'USkeletalMeshComponent': 21, 'UBlueprint': 24, 'UDelegateFunction': 14,
    'UStaticMeshComponent': 8, 'FMapProperty': 37, 'FSetProperty': 49,
    'FEnumProperty': 28, 'USparseDelegateFunction': 57,
    'FMulticastInlineDelegateProperty': 34, 'FMulticastSparseDelegateProperty': 27,
    'FFieldPathProperty': 9, 'FOptionalProperty': 10, 'FUtf8StrProperty': 5,
    'FAnsiStrProperty': 36,
}


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) & ~(alignment - 1)


def build_lut() -> bytes:
    lut = bytearray([0xFF] * 64)
    for name, sg2_bit in SG2_BITS.items():
        if lut[sg2_bit] != 0xFF:
            raise ValueError(f"Duplicate SG2 bit index: {sg2_bit}")
        lut[sg2_bit] = UE55_BITS[name]
    return bytes(lut)


def build_stub(code_va: int, data_va: int):
    lut_off = 0x100
    lut_va = code_va + lut_off
    ring_idx_va = data_va + 0x00
    ring_buf_va = data_va + 0x40

    buf = bytearray()
    offs = {}

    # 1. tail_remap_val_rsp28
    offs['tail_remap_val_rsp28'] = len(buf)
    buf += b'\x48\x83\xC4\x28'
    j1_pos = len(buf)
    buf += b'\xEB\x00'

    # 2. tail_remap_val_rsp48
    offs['tail_remap_val_rsp48'] = len(buf)
    buf += b'\x48\x83\xC4\x48'
    j2_pos = len(buf)
    buf += b'\xEB\x00'

    # 3. tail_remap_ptr_rsp20_rbx
    offs['tail_remap_ptr_rsp20_rbx'] = len(buf)
    buf += b'\x48\x83\xC4\x20\x5B'
    j3_pos = len(buf)
    buf += b'\xEB\x00'

    # 4. remap_val
    offs['remap_val'] = len(buf)
    buf += b'\x49\x89\xC0'
    buf += b'\x31\xC0'
    buf += b'\x4D\x85\xC0'
    jz_done_pos = len(buf)
    buf += b'\x74\x00'
    buf += b'\x4C\x8D\x0D' + struct.pack('<i', lut_va - (code_va + len(buf) + 7))
    loop_pos = len(buf)
    buf += b'\x49\x0F\xBC\xC8'
    buf += b'\x41\x0F\xB6\x0C\x09'
    buf += b'\x80\xF9\x40'
    jae_skip_pos = len(buf)
    buf += b'\x73\x00'
    buf += b'\xBA\x01\x00\x00\x00'
    buf += b'\x48\xD3\xE2'
    buf += b'\x48\x09\xD0'
    skip_pos = len(buf)
    buf += b'\x4D\x8D\x50\xFF'
    buf += b'\x4D\x21\xD0'
    jnz_pos = len(buf)
    buf += bytes([0x75, (loop_pos - (jnz_pos + 2)) & 0xFF])
    done_pos = len(buf)
    buf += b'\xC3'

    # 5. remap_ptr
    offs['remap_ptr'] = len(buf)
    buf += b'\x48\x8B\x00'
    buf += b'\xE8' + struct.pack('<i', offs['remap_val'] - (len(buf) + 5))
    buf += b'\x41\xB8\x01\x00\x00\x00'
    buf += b'\x4C\x8D\x0D' + struct.pack('<i', ring_idx_va - (code_va + len(buf) + 7))
    buf += b'\xF0\x45\x0F\xC1\x01'
    buf += b'\x41\x81\xE0\xFF\x0F\x00\x00'
    buf += b'\x4C\x8D\x0D' + struct.pack('<i', ring_buf_va - (code_va + len(buf) + 7))
    buf += b'\x4F\x8D\x0C\xC1'
    buf += b'\x49\x89\x01'
    buf += b'\x4C\x89\xC8'
    buf += b'\xC3'

    buf[j1_pos + 1] = (offs['remap_val'] - (j1_pos + 2)) & 0xFF
    buf[j2_pos + 1] = (offs['remap_val'] - (j2_pos + 2)) & 0xFF
    buf[j3_pos + 1] = (offs['remap_ptr'] - (j3_pos + 2)) & 0xFF
    buf[jz_done_pos + 1] = (done_pos - (jz_done_pos + 2)) & 0xFF
    buf[jae_skip_pos + 1] = (skip_pos - (jae_skip_pos + 2)) & 0xFF

    assert len(buf) <= lut_off
    buf += b'\xCC' * (lut_off - len(buf))
    buf += build_lut()

    # 6. ProcessEvent UFunction* encryption trampolines (.sg2c + 0x140)
    offs['sg2_invoke_pe_nodetour'] = len(buf)
    buf += bytes.fromhex('48 8b 4c 24 58 eb 05')

    offs['sg2_tail_process_event'] = len(buf)
    buf += bytes.fromhex('48 83 c4 40 5f')

    offs['sg2_call_process_event'] = len(buf)
    buf += bytes.fromhex('53 41 54 41 55 41 56 48 83 ec 38')
    buf += bytes.fromhex('49 89 cc 48 89 d3 4d 89 c5 4d 89 ce')
    buf += b'\x48\xB8' + struct.pack('<Q', 0xBEDC2D2E44F97496)
    buf += bytes.fromhex('48 03 c3 48 c1 c0 0c')
    buf += b'\x48\xB9' + struct.pack('<Q', 0x4C4B20628241E15E)
    buf += bytes.fromhex('48 2b c1 48 89 44 24 20')
    buf += bytes.fromhex('65 4c 8b 14 25 60 00 00 00 4d 8b 52 10')
    buf += b'\x49\x8B\x82' + struct.pack('<I', 0x1268FE08)
    buf += b'\x48\xB9' + struct.pack('<Q', 0x3070B90431743569)
    buf += bytes.fromhex('48 33 c1 48 c1 c0 1a')
    buf += b'\x48\xB9' + struct.pack('<Q', 0xC2E7B448F7CCA0A1)
    buf += bytes.fromhex('48 03 c1')
    buf += b'\x48\xB9' + struct.pack('<Q', 0x06797F05C4913828)
    buf += bytes.fromhex('48 8d 54 24 20 ff d0')
    buf += bytes.fromhex('48 89 44 24 28 4c 89 e1 48 8d 54 24 28 4d 89 e8 41 ff d6')
    buf += bytes.fromhex('48 83 c4 38 41 5e 41 5d 41 5c 5b c3')

    assert len(buf) <= 0x200
    buf += b'\x00' * (0x200 - len(buf))
    return bytes(buf), offs


def patch_ue4ss(dll_path: str) -> None:
    orig_path = dll_path + '.orig'
    if not os.path.exists(orig_path):
        shutil.copy2(dll_path, orig_path)
        print(f'[OK] Backed up original UE4SS.dll -> {orig_path}')
    else:
        print(f'[INFO] Using existing backup: {orig_path}')

    orig_bytes = open(orig_path, 'rb').read()
    data = bytearray(orig_bytes)

    pe_off = struct.unpack_from('<I', orig_bytes, 0x3C)[0]
    assert orig_bytes[pe_off:pe_off + 4] == b'PE\x00\x00', 'Invalid PE header'
    n_sec = struct.unpack_from('<H', orig_bytes, pe_off + 6)[0]
    opt_sz = struct.unpack_from('<H', orig_bytes, pe_off + 20)[0]
    opt_off = pe_off + 24
    sec_off = opt_off + opt_sz

    sec_align = struct.unpack_from('<I', orig_bytes, opt_off + 32)[0]
    file_align = struct.unpack_from('<I', orig_bytes, opt_off + 36)[0]
    size_of_headers = struct.unpack_from('<I', orig_bytes, opt_off + 60)[0]
    assert sec_off + (n_sec + 2) * 40 <= size_of_headers

    secs = []
    for i in range(n_sec):
        o = sec_off + i * 40
        vsz, va, rsz, ra = struct.unpack_from('<IIII', orig_bytes, o + 8)
        secs.append((vsz, va, rsz, ra))

    def rva_to_off(rva: int) -> int:
        for vsz, va, rsz, ra in secs:
            if va <= rva < va + max(vsz, rsz):
                return ra + (rva - va)
        raise ValueError(f'RVA 0x{rva:08X} not mapped')

    last_vsz, last_va, _, _ = secs[-1]
    code_va = align_up(last_va + last_vsz, sec_align)
    code_ra = align_up(len(data), file_align)
    code_vsz, code_rsz = 0x1000, 0x200

    data_va = align_up(code_va + code_vsz, sec_align)
    data_ra = code_ra + code_rsz
    data_vsz, data_rsz = 0x9000, 0x9000

    stub, offs = build_stub(code_va, data_va)

    epilogue_patches = [
        (0x00B786C0, bytes.fromhex('48 83 C4 28 C3'),    'tail_remap_val_rsp28',     False),
        (0x00B786CD, bytes.fromhex('48 83 C4 28 C3'),    'tail_remap_val_rsp28',     False),
        (0x00B788DC, bytes.fromhex('48 83 C4 48 C3'),    'tail_remap_val_rsp48',     False),
        (0x00B788EC, bytes.fromhex('48 83 C4 48 C3'),    'tail_remap_val_rsp48',     False),
        (0x00B231E6, bytes.fromhex('48 83 C4 20 5B C3'), 'tail_remap_ptr_rsp20_rbx', True),
        (0x00B23227, bytes.fromhex('48 83 C4 20 5B C3'), 'tail_remap_ptr_rsp20_rbx', True),
        (0x00B23266, bytes.fromhex('48 83 C4 20 5B C3'), 'tail_remap_ptr_rsp20_rbx', True),
        (0x00B232A7, bytes.fromhex('48 83 C4 20 5B C3'), 'tail_remap_ptr_rsp20_rbx', True),
    ]
    for rva, expected, label, pad_nop in epilogue_patches:
        fo = rva_to_off(rva)
        assert orig_bytes[fo:fo + len(expected)] == expected, f'Mismatch at 0x{rva:08X}'
        tgt_va = code_va + offs[label]
        patch = b'\xE9' + struct.pack('<i', tgt_va - (rva + 5)) + (b'\x90' if pad_nop else b'')
        data[fo:fo + len(patch)] = patch
        print(f'[OK] Patched 0x{rva:08X} -> 0x{tgt_va:08X} ({label})')

    fopt_patches = [
        (0x002A63AD, bytes.fromhex('48 63 47 30 48 83 C0 08'),       bytes.fromhex('B8 78 00 00 00 90 90 90'),       'FOptionalProperty::ValuePropertyOffset = 0x78'),
        (0x002A5D7D, bytes.fromhex('8B 5F 30 E8 5B 4E 89 00 03 C3'), bytes.fromhex('B8 78 00 00 00 90 90 90 90 90'), 'FOptionalPropertyLayout::ValuePropertyOffset = 0x78'),
    ]
    for rva, expected, repl, desc in fopt_patches:
        fo = rva_to_off(rva)
        assert orig_bytes[fo:fo + len(expected)] == expected, f'Mismatch at 0x{rva:08X}'
        data[fo:fo + len(repl)] = repl
        print(f'[OK] Patched 0x{rva:08X} ({desc})')

    pe_patches = [
        (0x00B0DCC1, bytes.fromhex('48 83 C4 40 5F 49 FF E1'), 0xE9, 'sg2_tail_process_event', 'UObject::ProcessEvent encrypted UFunction* wrapper'),
        (0x00B53823, bytes.fromhex('48 8B 4C 24 50 41 FF D1'), 0xE8, 'sg2_invoke_pe_nodetour', 'InvokeProcessEventWithoutDetour encrypted UFunction* wrapper'),
    ]
    for rva, expected, opcode, label, desc in pe_patches:
        fo = rva_to_off(rva)
        assert orig_bytes[fo:fo + len(expected)] == expected, f'Mismatch at 0x{rva:08X}'
        tgt_va = code_va + offs[label]
        patch = bytes([opcode]) + struct.pack('<i', tgt_va - (rva + 5)) + b'\x90\x90\x90'
        data[fo:fo + 8] = patch
        print(f'[OK] Patched 0x{rva:08X} -> 0x{tgt_va:08X} ({desc})')

    data += b'\x00' * (code_ra - len(data))
    data += stub
    data += b'\x00' * data_rsz

    def build_sec_hdr(name: bytes, vsz: int, va: int, rsz: int, ra: int, chars: int) -> bytes:
        return struct.pack('<8sIIIIIIHHI', name.ljust(8, b'\x00'), vsz, va, rsz, ra, 0, 0, 0, 0, chars)

    o_c = sec_off + n_sec * 40
    data[o_c:o_c + 40] = build_sec_hdr(b'.sg2c', code_vsz, code_va, code_rsz, code_ra, 0x60000020)
    data[o_c + 40:o_c + 80] = build_sec_hdr(b'.sg2d', data_vsz, data_va, data_rsz, data_ra, 0xC0000040)

    struct.pack_into('<H', data, pe_off + 6, n_sec + 2)
    struct.pack_into('<I', data, opt_off + 56, align_up(data_va + data_vsz, sec_align))

    with open(dll_path, 'wb') as f:
        f.write(data)
    print(f'[SUCCESS] Patched UE4SS.dll written to: {dll_path}')
    print(f'          SHA-256: {hashlib.sha256(data).hexdigest().upper()}')


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage: python patch_ue4ss_splitgate2.py <path/to/ue4ss/UE4SS.dll>')
        sys.exit(1)
    patch_ue4ss(sys.argv[1])
