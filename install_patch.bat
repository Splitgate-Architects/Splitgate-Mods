@echo off
setlocal
title Splitgate 2 / Arena Reloaded - UE4SS Patcher

set "BAT_SELF=%~f0"
set "BAT_DIR=%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$txt = [System.IO.File]::ReadAllText($env:BAT_SELF); $m = '###__PS_' + 'START__###'; $idx = $txt.IndexOf($m); $code = $txt.Substring($idx + $m.Length); & ([scriptblock]::Create($code)) -BatDir $env:BAT_DIR"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if "%EXIT_CODE%"=="0" (
    echo Done! You can now launch Splitgate 2.
) else (
    echo Patching failed with exit code %EXIT_CODE%.
)
echo.
if not defined NO_PAUSE pause
exit /b %EXIT_CODE%

###__PS_START__###
<#
.SYNOPSIS
    Splitgate 2 / Splitgate: Arena Reloaded - UE4SS v4.0.0 Local Patcher
    (Pure Windows PowerShell embedded in .bat - no Python required!)

.DESCRIPTION
    Place this script and the included "ue4ss" folder into your game's
    "PortalWars2\Binaries\Win64" directory (after extracting official UE4SS v4.0.0),
    then double-click install_patch.bat.

    Only ever modifies UE4SS.dll inside its own folder — never scans or touches
    any other game installation on your system.
#>
param(
    [string]$BatDir = ""
)

$ErrorActionPreference = "Stop"

# Standard UE 5.5 EClassCastFlags bit indices
$UE55_BITS = @{
    'UField'                          = 0
    'FInt8Property'                   = 1
    'UEnum'                           = 2
    'UStruct'                         = 3
    'UScriptStruct'                   = 4
    'UClass'                          = 5
    'FByteProperty'                   = 6
    'FIntProperty'                    = 7
    'FFloatProperty'                  = 8
    'FUInt64Property'                 = 9
    'FClassProperty'                  = 10
    'FUInt32Property'                 = 11
    'FInterfaceProperty'              = 12
    'FNameProperty'                   = 13
    'FStrProperty'                    = 14
    'FProperty'                       = 15
    'FObjectProperty'                 = 16
    'FBoolProperty'                   = 17
    'FUInt16Property'                 = 18
    'UFunction'                       = 19
    'FStructProperty'                 = 20
    'FArrayProperty'                  = 21
    'FInt64Property'                  = 22
    'FDelegateProperty'               = 23
    'FNumericProperty'                = 24
    'FMulticastDelegateProperty'      = 25
    'FObjectPropertyBase'             = 26
    'FWeakObjectProperty'             = 27
    'FLazyObjectProperty'             = 28
    'FSoftObjectProperty'             = 29
    'FTextProperty'                   = 30
    'FInt16Property'                  = 31
    'FDoubleProperty'                 = 32
    'FSoftClassProperty'              = 33
    'UPackage'                        = 34
    'ULevel'                          = 35
    'AActor'                          = 36
    'APlayerController'               = 37
    'APawn'                           = 38
    'USceneComponent'                 = 39
    'UPrimitiveComponent'             = 40
    'USkinnedMeshComponent'           = 41
    'USkeletalMeshComponent'          = 42
    'UBlueprint'                      = 43
    'UDelegateFunction'               = 44
    'UStaticMeshComponent'            = 45
    'FMapProperty'                    = 46
    'FSetProperty'                    = 47
    'FEnumProperty'                   = 48
    'USparseDelegateFunction'         = 49
    'FMulticastInlineDelegateProperty'= 50
    'FMulticastSparseDelegateProperty'= 51
    'FFieldPathProperty'              = 52
    'FOptionalProperty'               = 56
    'FUtf8StrProperty'                = 60
    'FAnsiStrProperty'                = 61
}

# Splitgate 2 (PortalWars2-Win64-Shipping.exe) shuffled EClassCastFlags bit indices
$SG2_BITS = @{
    'UField'                          = 30
    'FInt8Property'                   = 38
    'UEnum'                           = 25
    'UStruct'                         = 58
    'UScriptStruct'                   = 45
    'UClass'                          = 3
    'FByteProperty'                   = 46
    'FIntProperty'                    = 39
    'FFloatProperty'                  = 1
    'FUInt64Property'                 = 52
    'FClassProperty'                  = 61
    'FUInt32Property'                 = 12
    'FInterfaceProperty'              = 23
    'FNameProperty'                   = 31
    'FStrProperty'                    = 41
    'FProperty'                       = 44
    'FObjectProperty'                 = 35
    'FBoolProperty'                   = 26
    'FUInt16Property'                 = 20
    'UFunction'                       = 19
    'FStructProperty'                 = 18
    'FArrayProperty'                  = 55
    'FInt64Property'                  = 60
    'FDelegateProperty'               = 7
    'FNumericProperty'                = 51
    'FMulticastDelegateProperty'      = 33
    'FObjectPropertyBase'             = 13
    'FWeakObjectProperty'             = 32
    'FLazyObjectProperty'             = 16
    'FSoftObjectProperty'             = 15
    'FTextProperty'                   = 47
    'FInt16Property'                  = 50
    'FDoubleProperty'                 = 4
    'FSoftClassProperty'              = 48
    'UPackage'                        = 56
    'ULevel'                          = 11
    'AActor'                          = 29
    'APlayerController'               = 40
    'APawn'                           = 6
    'USceneComponent'                 = 42
    'UPrimitiveComponent'             = 17
    'USkinnedMeshComponent'           = 22
    'USkeletalMeshComponent'          = 21
    'UBlueprint'                      = 24
    'UDelegateFunction'               = 14
    'UStaticMeshComponent'            = 8
    'FMapProperty'                    = 37
    'FSetProperty'                    = 49
    'FEnumProperty'                   = 28
    'USparseDelegateFunction'         = 57
    'FMulticastInlineDelegateProperty'= 34
    'FMulticastSparseDelegateProperty'= 27
    'FFieldPathProperty'              = 9
    'FOptionalProperty'               = 10
    'FUtf8StrProperty'                = 5
    'FAnsiStrProperty'                = 36
}

function Add-Bytes([System.Collections.Generic.List[byte]]$List, [byte[]]$Bytes) {
    $List.AddRange($Bytes)
}

function Add-Int32LE([System.Collections.Generic.List[byte]]$List, [int]$Value) {
    $List.AddRange([System.BitConverter]::GetBytes([int]$Value))
}

function Add-UInt32LE([System.Collections.Generic.List[byte]]$List, [uint32]$Value) {
    $List.AddRange([System.BitConverter]::GetBytes([uint32]$Value))
}

function Add-UInt16LE([System.Collections.Generic.List[byte]]$List, [uint16]$Value) {
    $List.AddRange([System.BitConverter]::GetBytes([uint16]$Value))
}

function Build-Lut {
    $lut = New-Object byte[] 64
    for ($i = 0; $i -lt 64; $i++) { $lut[$i] = 0xFF }
    foreach ($name in $SG2_BITS.Keys) {
        $sg2Bit = $SG2_BITS[$name]
        if ($lut[$sg2Bit] -ne 0xFF) {
            throw "Duplicate SG2 bit index: $sg2Bit"
        }
        $lut[$sg2Bit] = [byte]$UE55_BITS[$name]
    }
    return $lut
}

function Build-Stub([uint32]$CodeVA, [uint32]$DataVA) {
    $lutOff = 0x100
    $lutVA = $CodeVA + $lutOff
    $ringIdxVA = $DataVA + 0x00
    $ringBufVA = $DataVA + 0x40

    $buf = New-Object System.Collections.Generic.List[byte]
    $offs = @{}

    # 1. tail_remap_val_rsp28: add rsp, 0x28; jmp remap_val
    $offs['tail_remap_val_rsp28'] = $buf.Count
    Add-Bytes $buf ([byte[]]@(0x48, 0x83, 0xC4, 0x28))
    $j1Pos = $buf.Count
    Add-Bytes $buf ([byte[]]@(0xEB, 0x00))

    # 2. tail_remap_val_rsp48: add rsp, 0x48; jmp remap_val
    $offs['tail_remap_val_rsp48'] = $buf.Count
    Add-Bytes $buf ([byte[]]@(0x48, 0x83, 0xC4, 0x48))
    $j2Pos = $buf.Count
    Add-Bytes $buf ([byte[]]@(0xEB, 0x00))

    # 3. tail_remap_ptr_rsp20_rbx: add rsp, 0x20; pop rbx; jmp remap_ptr
    $offs['tail_remap_ptr_rsp20_rbx'] = $buf.Count
    Add-Bytes $buf ([byte[]]@(0x48, 0x83, 0xC4, 0x20, 0x5B))
    $j3Pos = $buf.Count
    Add-Bytes $buf ([byte[]]@(0xEB, 0x00))

    # 4. remap_val (Windows x64 leaf: input rax, output rax; clobbers rcx, rdx, r8, r9, r10)
    $offs['remap_val'] = $buf.Count
    Add-Bytes $buf ([byte[]]@(0x49, 0x89, 0xC0)) # mov r8, rax
    Add-Bytes $buf ([byte[]]@(0x31, 0xC0))       # xor eax, eax
    Add-Bytes $buf ([byte[]]@(0x4D, 0x85, 0xC0)) # test r8, r8
    $jzDonePos = $buf.Count
    Add-Bytes $buf ([byte[]]@(0x74, 0x00))       # jz .done

    # lea r9, [rip + lut_va]
    Add-Bytes $buf ([byte[]]@(0x4C, 0x8D, 0x0D))
    $disp = [int]([int64]$lutVA - ([int64]$CodeVA + $buf.Count + 4))
    Add-Int32LE $buf $disp

    $loopPos = $buf.Count
    Add-Bytes $buf ([byte[]]@(0x49, 0x0F, 0xBC, 0xC8))       # bsf rcx, r8
    Add-Bytes $buf ([byte[]]@(0x41, 0x0F, 0xB6, 0x0C, 0x09)) # movzx ecx, byte ptr [r9 + rcx]
    Add-Bytes $buf ([byte[]]@(0x80, 0xF9, 0x40))             # cmp cl, 64
    $jaeSkipPos = $buf.Count
    Add-Bytes $buf ([byte[]]@(0x73, 0x00))                   # jae .skip
    Add-Bytes $buf ([byte[]]@(0xBA, 0x01, 0x00, 0x00, 0x00)) # mov edx, 1
    Add-Bytes $buf ([byte[]]@(0x48, 0xD3, 0xE2))             # shl rdx, cl
    Add-Bytes $buf ([byte[]]@(0x48, 0x09, 0xD0))             # or rax, rdx

    $skipPos = $buf.Count
    Add-Bytes $buf ([byte[]]@(0x4D, 0x8D, 0x50, 0xFF))       # lea r10, [r8 - 1]
    Add-Bytes $buf ([byte[]]@(0x4D, 0x21, 0xD0))             # and r8, r10
    $jnzLoopPos = $buf.Count
    $relLoop = ($loopPos - ($jnzLoopPos + 2)) -band 0xFF
    Add-Bytes $buf ([byte[]]@(0x75, [byte]$relLoop))

    $donePos = $buf.Count
    Add-Bytes $buf ([byte[]]@(0xC3))                         # ret

    # 5. remap_ptr (input rax = uint64*, output rax = &ring_buf[slot])
    $offs['remap_ptr'] = $buf.Count
    Add-Bytes $buf ([byte[]]@(0x48, 0x8B, 0x00))             # mov rax, [rax]
    $callDisp = [int]($offs['remap_val'] - ($buf.Count + 5))
    Add-Bytes $buf ([byte[]]@(0xE8))
    Add-Int32LE $buf $callDisp
    Add-Bytes $buf ([byte[]]@(0x41, 0xB8, 0x01, 0x00, 0x00, 0x00)) # mov r8d, 1
    Add-Bytes $buf ([byte[]]@(0x4C, 0x8D, 0x0D))
    Add-Int32LE $buf ([int]([int64]$ringIdxVA - ([int64]$CodeVA + $buf.Count + 4)))
    Add-Bytes $buf ([byte[]]@(0xF0, 0x45, 0x0F, 0xC1, 0x01))                   # lock xadd [r9], r8d
    Add-Bytes $buf ([byte[]]@(0x41, 0x81, 0xE0, 0xFF, 0x0F, 0x00, 0x00))       # and r8d, 0x0FFF
    Add-Bytes $buf ([byte[]]@(0x4C, 0x8D, 0x0D))
    Add-Int32LE $buf ([int]([int64]$ringBufVA - ([int64]$CodeVA + $buf.Count + 4)))
    Add-Bytes $buf ([byte[]]@(0x4F, 0x8D, 0x0C, 0xC1))       # lea r9, [r9 + r8*8]
    Add-Bytes $buf ([byte[]]@(0x49, 0x89, 0x01))             # mov [r9], rax
    Add-Bytes $buf ([byte[]]@(0x4C, 0x89, 0xC8))             # mov rax, r9
    Add-Bytes $buf ([byte[]]@(0xC3))                         # ret

    # Patch local short jumps
    $buf[$j1Pos + 1]      = [byte](($offs['remap_val'] - ($j1Pos + 2)) -band 0xFF)
    $buf[$j2Pos + 1]      = [byte](($offs['remap_val'] - ($j2Pos + 2)) -band 0xFF)
    $buf[$j3Pos + 1]      = [byte](($offs['remap_ptr'] - ($j3Pos + 2)) -band 0xFF)
    $buf[$jzDonePos + 1]  = [byte](($donePos - ($jzDonePos + 2)) -band 0xFF)
    $buf[$jaeSkipPos + 1] = [byte](($skipPos - ($jaeSkipPos + 2)) -band 0xFF)

    if ($buf.Count -gt $lutOff) {
        throw "Code stub grew past lut_off ($($buf.Count) > $lutOff)"
    }
    while ($buf.Count -lt $lutOff) { $buf.Add(0xCC) }
    Add-Bytes $buf (Build-Lut)
    while ($buf.Count -lt 0x200) { $buf.Add(0x00) }

    return @{ Bytes = $buf.ToArray(); Offsets = $offs }
}

function Align-Up([uint32]$Value, [uint32]$Alignment) {
    return [uint32](($Value + $Alignment - 1) -band (-bnot ($Alignment - 1)))
}

function Compare-ByteSlice([byte[]]$Data, [int]$Offset, [byte[]]$Expected) {
    for ($i = 0; $i -lt $Expected.Length; $i++) {
        if ($Data[$Offset + $i] -ne $Expected[$i]) { return $false }
    }
    return $true
}

function Format-HexBytes([byte[]]$Data, [int]$Offset, [int]$Length) {
    return (($Data[$Offset..($Offset + $Length - 1)] | ForEach-Object { $_.ToString("x2") }) -join " ")
}

function Patch-UE4SS([string]$DllPath) {
    $origPath = "$DllPath.orig"
    if (-not (Test-Path $origPath)) {
        Copy-Item -Path $DllPath -Destination $origPath -Force
        Write-Host "[OK] Backed up original UE4SS.dll -> $origPath" -ForegroundColor Green
    } else {
        Write-Host "[INFO] Using existing backup: $origPath" -ForegroundColor Cyan
    }

    $origBytes = [System.IO.File]::ReadAllBytes($origPath)
    $data = New-Object System.Collections.Generic.List[byte]($origBytes.Length + 0xA000)
    $data.AddRange($origBytes)

    $peOff = [System.BitConverter]::ToInt32($origBytes, 0x3C)
    if ($origBytes[$peOff] -ne 0x50 -or $origBytes[$peOff + 1] -ne 0x45 -or $origBytes[$peOff + 2] -ne 0 -or $origBytes[$peOff + 3] -ne 0) {
        throw "Invalid PE header in $origPath"
    }

    $nSec = [System.BitConverter]::ToUInt16($origBytes, $peOff + 6)
    $optSz = [System.BitConverter]::ToUInt16($origBytes, $peOff + 20)
    $optOff = $peOff + 24
    $secOff = $optOff + $optSz

    $secAlign = [System.BitConverter]::ToUInt32($origBytes, $optOff + 32)
    $fileAlign = [System.BitConverter]::ToUInt32($origBytes, $optOff + 36)
    $sizeOfHeaders = [System.BitConverter]::ToUInt32($origBytes, $optOff + 60)

    if (($secOff + ($nSec + 2) * 40) -gt $sizeOfHeaders) {
        throw "Not enough PE header space for 2 new sections!"
    }

    $secs = @()
    for ($i = 0; $i -lt $nSec; $i++) {
        $o = $secOff + $i * 40
        $secs += [PSCustomObject]@{
            VSz = [System.BitConverter]::ToUInt32($origBytes, $o + 8)
            VA  = [System.BitConverter]::ToUInt32($origBytes, $o + 12)
            RSz = [System.BitConverter]::ToUInt32($origBytes, $o + 16)
            RA  = [System.BitConverter]::ToUInt32($origBytes, $o + 20)
        }
    }

    function Rva-ToOff([uint32]$Rva) {
        foreach ($s in $secs) {
            $span = [Math]::Max([uint64]$s.VSz, [uint64]$s.RSz)
            if ($Rva -ge $s.VA -and $Rva -lt ($s.VA + $span)) {
                return [int]($s.RA + ($Rva - $s.VA))
            }
        }
        throw ("RVA 0x{0:X8} not mapped in PE sections" -f $Rva)
    }

    $lastSec = $secs[$secs.Count - 1]
    $codeVA = Align-Up ($lastSec.VA + $lastSec.VSz) $secAlign
    $codeRA = Align-Up ([uint32]$data.Count) $fileAlign
    [uint32]$codeVSz = 0x1000
    [uint32]$codeRSz = 0x200

    $dataVA = Align-Up ($codeVA + $codeVSz) $secAlign
    $dataRA = [uint32]($codeRA + $codeRSz)
    [uint32]$dataVSz = 0x9000
    [uint32]$dataRSz = 0x9000

    $stubResult = Build-Stub $codeVA $dataVA
    $stub = $stubResult.Bytes
    $offs = $stubResult.Offsets

    # 8 CastFlags getter epilogue patches
    $epiloguePatches = @(
        @{ Rva = [uint32]0x00B786C0; Expected = [byte[]]@(0x48,0x83,0xC4,0x28,0xC3);      Label = 'tail_remap_val_rsp28';     PadNop = $false }
        @{ Rva = [uint32]0x00B786CD; Expected = [byte[]]@(0x48,0x83,0xC4,0x28,0xC3);      Label = 'tail_remap_val_rsp28';     PadNop = $false }
        @{ Rva = [uint32]0x00B788DC; Expected = [byte[]]@(0x48,0x83,0xC4,0x48,0xC3);      Label = 'tail_remap_val_rsp48';     PadNop = $false }
        @{ Rva = [uint32]0x00B788EC; Expected = [byte[]]@(0x48,0x83,0xC4,0x48,0xC3);      Label = 'tail_remap_val_rsp48';     PadNop = $false }
        @{ Rva = [uint32]0x00B231E6; Expected = [byte[]]@(0x48,0x83,0xC4,0x20,0x5B,0xC3); Label = 'tail_remap_ptr_rsp20_rbx'; PadNop = $true  }
        @{ Rva = [uint32]0x00B23227; Expected = [byte[]]@(0x48,0x83,0xC4,0x20,0x5B,0xC3); Label = 'tail_remap_ptr_rsp20_rbx'; PadNop = $true  }
        @{ Rva = [uint32]0x00B23266; Expected = [byte[]]@(0x48,0x83,0xC4,0x20,0x5B,0xC3); Label = 'tail_remap_ptr_rsp20_rbx'; PadNop = $true  }
        @{ Rva = [uint32]0x00B232A7; Expected = [byte[]]@(0x48,0x83,0xC4,0x20,0x5B,0xC3); Label = 'tail_remap_ptr_rsp20_rbx'; PadNop = $true  }
    )

    foreach ($p in $epiloguePatches) {
        $fo = Rva-ToOff $p.Rva
        if (-not (Compare-ByteSlice $origBytes $fo $p.Expected)) {
            $gotHex = Format-HexBytes $origBytes $fo $p.Expected.Length
            $expHex = Format-HexBytes $p.Expected 0 $p.Expected.Length
            throw ("Byte mismatch at 0x{0:X8}: got [{1}], expected [{2}]. Make sure you are using UE4SS v4.0.0 (Git SHA #30afe5ff, standard release)!" -f $p.Rva, $gotHex, $expHex)
        }
        $tgtVA = $codeVA + [uint32]$offs[$p.Label]
        $rel32 = [int]([int64]$tgtVA - ([int64]$p.Rva + 5))
        $relBytes = [System.BitConverter]::GetBytes($rel32)

        $data[$fo]     = 0xE9
        $data[$fo + 1] = $relBytes[0]
        $data[$fo + 2] = $relBytes[1]
        $data[$fo + 3] = $relBytes[2]
        $data[$fo + 4] = $relBytes[3]
        if ($p.PadNop) { $data[$fo + 5] = 0x90 }

        Write-Host ("[OK] Patched 0x{0:X8} -> 0x{1:X8} ({2})" -f $p.Rva, $tgtVA, $p.Label) -ForegroundColor DarkGreen
    }

    # 2 FOptionalProperty::GetValueProperty / FOptionalPropertyLayout::GetValueProperty patches
    $foptPatches = @(
        @{
            Rva      = [uint32]0x002A63AD
            Expected = [byte[]]@(0x48,0x63,0x47,0x30,0x48,0x83,0xC0,0x08)
            Replace  = [byte[]]@(0xB8,0x78,0x00,0x00,0x00,0x90,0x90,0x90)
            Desc     = 'FOptionalProperty::ValuePropertyOffset = 0x78'
        }
        @{
            Rva      = [uint32]0x002A5D7D
            Expected = [byte[]]@(0x8B,0x5F,0x30,0xE8,0x5B,0x4E,0x89,0x00,0x03,0xC3)
            Replace  = [byte[]]@(0xB8,0x78,0x00,0x00,0x00,0x90,0x90,0x90,0x90,0x90)
            Desc     = 'FOptionalPropertyLayout::ValuePropertyOffset = 0x78'
        }
    )

    foreach ($p in $foptPatches) {
        $fo = Rva-ToOff $p.Rva
        if (-not (Compare-ByteSlice $origBytes $fo $p.Expected)) {
            $gotHex = Format-HexBytes $origBytes $fo $p.Expected.Length
            $expHex = Format-HexBytes $p.Expected 0 $p.Expected.Length
            throw ("Byte mismatch at 0x{0:X8}: got [{1}], expected [{2}]. Make sure you are using UE4SS v4.0.0 (Git SHA #30afe5ff, standard release)!" -f $p.Rva, $gotHex, $expHex)
        }
        for ($i = 0; $i -lt $p.Replace.Length; $i++) {
            $data[$fo + $i] = $p.Replace[$i]
        }
        Write-Host ("[OK] Patched 0x{0:X8} ({1})" -f $p.Rva, $p.Desc) -ForegroundColor DarkGreen
    }

    # Append padding up to codeRA, then .sg2c, then .sg2d
    while ($data.Count -lt $codeRA) { $data.Add(0x00) }
    $data.AddRange($stub)
    $zeroData = New-Object byte[] $dataRSz
    $data.AddRange($zeroData)

    function Build-SectionHeader([string]$Name, [uint32]$VSz, [uint32]$VA, [uint32]$RSz, [uint32]$RA, [uint32]$Chars) {
        $sh = New-Object System.Collections.Generic.List[byte](40)
        $nameBytes = [System.Text.Encoding]::ASCII.GetBytes($Name)
        for ($i = 0; $i -lt 8; $i++) {
            if ($i -lt $nameBytes.Length) { $sh.Add($nameBytes[$i]) } else { $sh.Add(0) }
        }
        Add-UInt32LE $sh $VSz
        Add-UInt32LE $sh $VA
        Add-UInt32LE $sh $RSz
        Add-UInt32LE $sh $RA
        Add-UInt32LE $sh 0
        Add-UInt32LE $sh 0
        Add-UInt16LE $sh 0
        Add-UInt16LE $sh 0
        Add-UInt32LE $sh $Chars
        return $sh.ToArray()
    }

    $shC = Build-SectionHeader ".sg2c" $codeVSz $codeVA $codeRSz $codeRA ([uint32]0x60000020)
    $shD = Build-SectionHeader ".sg2d" $dataVSz $dataVA $dataRSz $dataRA ([Convert]::ToUInt32("C0000040", 16))

    $oC = $secOff + $nSec * 40
    for ($i = 0; $i -lt 40; $i++) { $data[$oC + $i] = $shC[$i] }
    for ($i = 0; $i -lt 40; $i++) { $data[$oC + 40 + $i] = $shD[$i] }

    # Update NumberOfSections and SizeOfImage
    $newSizeOfImage = Align-Up ($dataVA + $dataVSz) $secAlign
    $nSecBytes = [System.BitConverter]::GetBytes([uint16]($nSec + 2))
    $data[$peOff + 6] = $nSecBytes[0]
    $data[$peOff + 7] = $nSecBytes[1]

    $soiBytes = [System.BitConverter]::GetBytes([uint32]$newSizeOfImage)
    for ($i = 0; $i -lt 4; $i++) { $data[$optOff + 56 + $i] = $soiBytes[$i] }

    [System.IO.File]::WriteAllBytes($DllPath, $data.ToArray())
    $hash = (Get-FileHash -Path $DllPath -Algorithm SHA256).Hash

    Write-Host ""
    Write-Host "[SUCCESS] Patched UE4SS.dll written to: $DllPath" -ForegroundColor Green
    Write-Host ("          Added .sg2c @ VA 0x{0:X8} (RX) and .sg2d @ VA 0x{1:X8} (RW)" -f $codeVA, $dataVA)
    Write-Host "          SHA-256: $hash"
}

# --- Main (strictly local folder only) ---
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Splitgate 2 / Arena Reloaded - UE4SS v4.0.0 Patcher       " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$curDir = if ($BatDir) { $BatDir.TrimEnd("\") } else { (Get-Location).Path }

# Support placing install_patch.bat in Binaries\Win64 (recommended) OR inside Binaries\Win64\ue4ss
$win64Dir = $null
$ue4ssDir = $null

if (Test-Path (Join-Path $curDir "ue4ss\UE4SS.dll")) {
    $win64Dir = $curDir
    $ue4ssDir = Join-Path $curDir "ue4ss"
} elseif ((Split-Path -Leaf $curDir) -ieq "ue4ss" -and (Test-Path (Join-Path $curDir "UE4SS.dll"))) {
    $ue4ssDir = $curDir
    $win64Dir = Split-Path -Parent $curDir
}

if (-not $ue4ssDir) {
    Write-Host "[ERROR] ue4ss\UE4SS.dll was not found in this folder:" -ForegroundColor Red
    Write-Host "        $curDir" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "How to install:" -ForegroundColor Cyan
    Write-Host "  1. Extract official UE4SS v4.0.0 (UE4SS_v4.0.0.zip) into PortalWars2\Binaries\Win64\"
    Write-Host "  2. Copy this release's 'ue4ss' folder and 'install_patch.bat' into PortalWars2\Binaries\Win64\ (replace existing files)"
    Write-Host "  3. Run install_patch.bat from inside PortalWars2\Binaries\Win64\"
    exit 1
}

if (-not (Test-Path (Join-Path $win64Dir "PortalWars2-Win64-Shipping.exe"))) {
    Write-Host "[ERROR] PortalWars2-Win64-Shipping.exe was not found in:" -ForegroundColor Red
    Write-Host "        $win64Dir" -ForegroundColor Yellow
    Write-Host "Please place UE4SS and these files into your Splitgate 2 'PortalWars2\Binaries\Win64\' folder." -ForegroundColor Yellow
    exit 1
}

# Verify required Splitgate 2 config files are present
$missing = @()
foreach ($rel in @("MemberVariableLayout.ini", "VTableLayout.ini", "UE4SS-settings.ini", "UE4SS_Signatures\GUObjectArray.lua")) {
    if (-not (Test-Path (Join-Path $ue4ssDir $rel))) {
        $missing += $rel
    }
}
if ($missing.Count -gt 0) {
    Write-Host "[ERROR] Missing Splitgate 2 UE4SS config file(s) in $ue4ssDir :" -ForegroundColor Red
    foreach ($m in $missing) { Write-Host "  - $m" -ForegroundColor Yellow }
    Write-Host "Please copy the entire 'ue4ss' folder from this release into PortalWars2\Binaries\Win64\ first." -ForegroundColor Yellow
    exit 1
}

# Disable GUObjectHashTables.lua if present (breaks Splitgate 2)
$hashLua = Join-Path $ue4ssDir "UE4SS_Signatures\GUObjectHashTables.lua"
if (Test-Path $hashLua) {
    Move-Item -Path $hashLua -Destination "$hashLua.bak" -Force
    Write-Host "[INFO] Disabled GUObjectHashTables.lua -> .bak (incompatible with Splitgate 2)" -ForegroundColor Yellow
}

$dstDll = Join-Path $ue4ssDir "UE4SS.dll"
Write-Host "[INFO] Target folder: $win64Dir" -ForegroundColor Cyan
Write-Host ""
Patch-UE4SS $dstDll
