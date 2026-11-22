# Splitgate-Mods (UE4SS v4.0.0 Setup & Lua Mods)

UE4SS v4.0.0 patcher, and community Lua mods for **Splitgate 2 / Splitgate: Arena Reloaded** (UE 5.5.4 Shipping P2P build, `PortalWars2-Win64-Shipping.exe`) by **Splitgate-Architects**.

> [!CAUTION]
> The underlying code for this project was built by AI.

**Disclaimer**
This project is intended strictly for **peer-to-peer (P2P) custom games, Map Editor ("The Lab") modding, and community host moderation** on the P2P build of Splitgate 2 (where official servers and Merlin Anti-Cheat are disabled).

No game assets or third-party UE4SS binaries are redistributed here, download official UE4SS v4.0.0 directly from [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0).

## Repository / Release Structure

```text
.
├── LICENSE
├── README.md
├── install_patch.bat                      # Double-click local patcher (embedded PowerShell, no Python!)
├── scripts/
│   └── patch_ue4ss_splitgate2.py          # Optional Python reference patcher (for developers)
└── ue4ss/                                 # Drop-in folder for PortalWars2\Binaries\Win64\
    ├── MemberVariableLayout.ini           # Verified Splitgate 2 UE 5.5.4 struct/field offsets
    ├── VTableLayout.ini                   # Verified Splitgate 2 FMalloc vtable layout
    ├── UE4SS-settings.ini                 # Tested UE4SS settings for Splitgate 2
    ├── UE4SS_Signatures/
    │   └── GUObjectArray.lua              # Verified GUObjectArray AOB signature
    └── Mods/                              # Community Lua mods
        ├── mods.txt                       # Enables MapEditorBudgetMod (+ ConsoleCommandsMod & Keybinds)
        └── MapEditorBudgetMod/            # Raises "The Lab" Map Editor budget limit (5000 -> 10000)
            └── scripts/
                ├── config.lua
                └── main.lua
```

## Quick Installation (3 Steps, No Python Required!)

### Prerequisites
- **Splitgate 2 / Splitgate: Arena Reloaded** (P2P build, `PortalWars2-Win64-Shipping.exe`, UE 5.5.4)
- **UE4SS v4.0.0** — download `UE4SS_v4.0.0.zip` (`Git SHA #30afe5ff`, standard release) from [RE-UE4SS Releases](https://github.com/UE4SS-RE/RE-UE4SS/releases)

> **Tip:** It is recommended to test on a separate copy of the game folder so your original Steam install remains untouched. If launching `PortalWars2-Win64-Shipping.exe` directly from a copied folder, create a `steam_appid.txt` containing `2918300` in `PortalWars2\Binaries\Win64\`.

### Steps

1. **Extract UE4SS v4.0.0** into your game's `Win64` folder:
   ```text
   <Splitgate 2>\PortalWars2\Binaries\Win64\
   ```
   You should now have `dwmapi.dll` and a `ue4ss\` subfolder next to `PortalWars2-Win64-Shipping.exe`.

2. **Copy our files into the same `Win64` folder**
   Copy the **`ue4ss`** folder and **`install_patch.bat`** from this release/repo into:
   ```text
   <Splitgate 2>\PortalWars2\Binaries\Win64\
   ```
   When Windows asks, choose **Replace the files in the destination**.

3. **Run `install_patch.bat`**
   Double-click **`install_patch.bat`** inside `PortalWars2\Binaries\Win64\`.
   - It **only** patches `ue4ss\UE4SS.dll` in that exact folder (it will never scan or modify any other Splitgate installation on your PC).
   - It automatically creates a `UE4SS.dll.orig` backup and safely aborts if the DLL version does not match UE4SS v4.0.0.

4. **Launch the game**
   Start Splitgate 2. The UE4SS GUI console will open alongside the game, and you should see:
   ```text
   [Lua] [MapEditorBudgetMod] (startup) BudgetLimit changed: 5000 -> 10000
   ```

## Included Mods

### `MapEditorBudgetMod`
Raises the global budget cap in Splitgate 2's Map Editor ("The Lab") by modifying `UCC1047Config::BudgetLimit` on `/Script/CreativeCore1047.Default__CC1047Config`.

- **Configuration:** Edit `ue4ss\Mods\MapEditorBudgetMod\scripts\config.lua` (`BudgetLimit = 10000` by default).
- **Live Reload:** Press **`F7`** in-game to reload `config.lua` and apply a new limit without restarting.

## Modding Possibilities

With full UE4SS reflection, Live View, CXX Header Dumping, and Lua scripting working in Splitgate 2, the community can build:

- **Map Editor ("The Lab") Enhancements**
  - Increase or customize global `BudgetLimit` (`UCC1047Config`)
  - Adjust per-object `BudgetCost` & `InstanceBudgetLimit` (`UCC1047ActorDescriptor`)
  - Unlock scale constraints (`bAllowScale`, `bAllowNegativeScale`, `bClampMinScale`, `bClampMaxScale`)
- **P2P Host Moderation & Server Admin Tools** *(planned)*
  - Local player banlist / auto-kick for P2P lobby hosts (matching `APlayerState::UniqueId` / `AccountId` / `PlatformAccountId`)
  - Automatic join/leave logging with player names and account IDs
- **Custom Game & Quality-of-Life Tweaks**
  - Custom lobby rules, spectator/camera tools, HUD/UI tweaks, and debug overlays
  - Live object inspection (`Live View`) and full SDK header generation (`Dump CXX Headers`) for reverse engineering and new mod development

## Technical Notes (Why Standard UE4SS Fails on Splitgate 2)

Splitgate 2's UE 5.5.4 Shipping binary includes several engine-level customizations that break stock UE4SS out of the box:

1. **Shuffled `EClassCastFlags`:** All 64 bit positions of `EClassCastFlags` are permuted (e.g. `CASTCLASS_FProperty` is bit 44 instead of bit 15). `install_patch.bat` / `patch_ue4ss_splitgate2.py` injects a 64-byte lookup table and atomic ring-buffer stub (`.sg2c` / `.sg2d`) at UE4SS's 4 central CastFlags getters to translate them back to standard UE 5.5 flags transparently.
2. **Custom Struct & Field Layouts:** `FUObjectArray`, `TUObjectArray`, `UObjectBase`, `UField`, `UEnum`, `UStruct`, `UScriptStruct`, `UClass`, `UFunction`, `FField`, and `FProperty` (plus subclasses) have reordered fields — mapped in `ue4ss/MemberVariableLayout.ini`.
3. **`FOptionalProperty::ValueProperty` Offset:** Stock UE4SS computes `RepNotifyFunc + 8`, which crashes during header dumping because Splitgate 2 moved `RepNotifyFunc` to `0x60` while `ValueProperty` remains at `0x78`. Fixed directly by the patcher.
4. **Shifted `FMalloc` VTable:** `Malloc` (`0x30`), `Free` (`0x50`), `QuantizeSize` (`0x68`), and `GetAllocationSize` (`0x70`) are shifted — mapped in `ue4ss/VTableLayout.ini` (prevents OOM crashes during type system init).
5. **Obfuscated `FUObjectHashTables`:** Bypassed cleanly via `bForceGUObjectArrayForIteration = true` in `UE4SS-settings.ini` and `UE4SS_Signatures/GUObjectArray.lua`.
6. **Encrypted `UFunction::Func` Pointers:** Native C++ `UFunction::Func` pointers at `UFunction + 0xF8` are obfuscated (`rol64 + add`) and decrypted inside `UFunction::Invoke`.
   - **Important for Mod Authors:** Do **not** directly hook native C++ `UFunction` pointers with `RegisterHook` (use property polling / `ExecuteWithDelay` / Blueprint hooks / `ProcessEvent` instead).

## Known Quirks & Troubleshooting

- **Do not set `GraphicsAPI = dx11`:** Stick with `GraphicsAPI = opengl` in `UE4SS-settings.ini` (`dx11` can leak Windows USER handles and crash with `Error 0x486`).
- **Do not enable "Load all assets first"** when dumping headers/objects (not needed and can exhaust system RAM / crash).
- **Brief `explorer.exe` restart on launch:** On some Windows 11 systems, `dwmapi.dll` + the OpenGL GUI console + EOS Overlay can occasionally trigger a brief Windows Explorer shell restart at launch while the game continues normally. Setting `GuiConsoleVisible = 0` (once you no longer need the debug window) or using an alternative UE4SS proxy DLL can help mitigate this.
- **Patcher reports a byte mismatch:** Make sure you downloaded **UE4SS v4.0.0 (`Git SHA #30afe5ff`, standard release)** — dev/experimental builds have different RVA offsets.

## License

This project is licensed under the [MIT License](LICENSE).