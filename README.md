# OLLVM-Rustc

This repository acts as a specialized fork of [Obfuscator-LLVM](https://github.com/obfuscator-llvm/obfuscator) and [Obfuscator-LLVM-16.0](https://github.com/joaovarelas/Obfuscator-LLVM-16.0), engineered to support **LLVM 21.0** and **Rust 1.92.0**.

---

## 🚀 Quick Usage

### 1. Build & Enter Docker Environment

Build the Docker image and start the container by mounting your Cargo project directory to access your code inside the container.

```bash
# Build the image
DOCKER_BUILDKIT=1 docker build -t ollvm-rustc:latest .

# Run the container (replace /path/to/cargo/proj with your actual project path)
docker run -v /path/to/cargo/proj:/projects/ -it ollvm-rustc:latest /bin/bash
```

### 2. Compile with Obfuscation

Once inside the container, you can proceed to build your project. The compiled binaries will be output to the `./target` directory.

**Target: Windows (GNU)**

```bash
cargo rustc --target x86_64-pc-windows-gnu --release --jobs 1 -- \
  -Ccodegen-units=1 \
  -Cdebuginfo=0 \
  -Cstrip=symbols \
  -Cpanic=abort \
  -Copt-level=3 \
  -Cllvm-args=-enable-allobf
```

**Target: Linux**

```bash
cargo rustc --target x86_64-unknown-linux-gnu --release -- \
  -Cdebuginfo=0 \
  -Cstrip=symbols \
  -Cpanic=abort \
  -Copt-level=3 \
  -Cllvm-args=-enable-allobf
```

> [!WARNING]
> **Performance & Stability Warning**
>
> Enabling all obfuscation features simultaneously (`-enable-allobf`) often leads to compilation failures or **Out of Memory (OOM)** errors. It is highly recommended to enable specific features individually.
>
> To mitigate memory usage, you can limit the intensity of certain passes:
> - `-indibran-max-bbs=<number>`
> - `-cffobf-max-bbs=<number>`

---

## 🛡️ Available Features

The current Rust OLLVM implementation is based on [Hikari](https://github.com/61bcdefg/Hikari-LLVM15-Core/blob/main/Obfuscation.cpp).

| Feature | Flag | Status |
| :--- | :--- | :--- |
| **Bogus Control Flow** | `-enable-bcfobf` | ✅ Working |
| **Basic Block Splitting** | `-enable-splitobf` | ✅ Working |
| **Instruction Substitution** | `-enable-subobf` | ✅ Working |
| **Function CallSite Obf** | `-enable-fco` | ✅ Working |
| **String Encryption** | `-enable-strcry` | ✅ Working |
| **Constant Encryption** | `-enable-constenc` | ✅ Working |
| **Constant FP Encryption** | `-enable-constfpenc` | ✅ Working |
| **Indirect Branching** | `-enable-indibran` | ✅ Working |
| **Indirect Global Variable** | `-enable-indgv` | ✅ Working |
| **Indirect Call** | `-enable-icall` | ✅ Working |
| **Function Wrapper** | `-enable-funcwra` | ✅ Working |
| **Control Flow Flattening** | `-enable-cffobf` | ⚠️ High Memory Cost |
| Anti Class Dump | `-enable-acdobf` | ❌ Not suitable for Rust |
| Anti Hooking | `-enable-antihook` | ❌ Not suitable for Rust |
| **Anti Debug** | `-enable-adb` | ✅ Working (x86-64 Linux/Windows) |

---

## 🛠️ Development & Changelog

Recent enhancements and fixes tailored for the Rust ecosystem:

*   **Added:** Indirect Global Variable pass (`-enable-indgv`) — routes global variable references through a runtime address table with encrypted addresses (XOR/GEP decrypt) and Rust-stdlib skipping (`-indgv-skip-rustlib`). Addresses are **always** encrypted: the plain table is folded straight back to direct references by the optimizer (no obfuscation) and miscompiles when combined with String Encryption, so `-indgv-enc-addr` is now the default and the flag is a retained no-op.
*   **Added:** Constant FP Encryption pass (`-enable-constfpenc`) — encrypts floating-point literals (`f16`/`f32`/`f64`) via bitcast + XOR with a runtime key, mirroring the integer `constenc` pass. Tunable with `constfpenc_prob`, `constfpenc_times`, `constfpenc_subxor`.
*   **Added:** Indirect Call pass (`-enable-icall`) — routes direct calls to module-defined functions through a runtime function-pointer table to obscure the static call graph, with optional address encryption (`-icall-enc-addr`) and Rust-stdlib skipping (`-icall-skip-rustlib`). Skips declarations, intrinsics, inline asm, and `musttail`.
*   **Changed:** `-enable-allobf` now also enables Constant Encryption (`constenc`), Constant FP Encryption (`constfpenc`), and Indirect Call (`icall`), so it turns on every semantic obfuscation pass. (The anti-tamper passes `antihook`/`adb` remain opt-in.)
*   **Fixed:** Anti Debug pass (`-enable-adb`) for Rust on x86-64 (Linux/Windows). Several problems were resolved: (1) the Linux `ptrace` inline asm used unescaped `$` immediates (`movq $101,...`), which LLVM parsed as operand references (`Invalid $ operand number in inline asm string`) — immediates are now escaped as `$$`; (2) the syscall clobbers (`rax`/`rdi`/`rsi`/`rdx`/`r10`/`rcx`/`r11`/`cc`/`memory`) are now declared; and (3) the check was injected at **every** instrumented function's terminator, which self-exited with no debugger present (`PTRACE_TRACEME` is stateful — a second call returns `-1`) and became inert when composed with control-flow-mutating passes. The x86-64 check is now emitted as a **global constructor** (`llvm.global_ctors`) that runs before `main`. Because the pass runs per-module and a real Rust binary spans many crates (many modules), each module emits its own constructor; they are coordinated by a **single shared run-once flag** (`__hikari_adb_done`, `LinkOnceODR` + volatile access so the linker/LTO coalesce it and the optimizer can't fold the load or drop the store), so `PTRACE_TRACEME` runs **exactly once per process**. This gives deterministic **anti-debug** (exits if launched under a debugger) and **anti-attach** (`PTRACE_TRACEME` marks the process traced by its parent, so a later `PTRACE_ATTACH` fails). Validated under LTO + `panic=abort`, single- and multi-crate, alongside `-enable-allobf`/`-enable-antihook`. Note: `-adb_prob` is ignored on this path (anti-debugging is deterministic); the precompiled-IR and AArch64/Darwin paths are unchanged.
*   **Fixed:** `indgv` × `strcry` interaction that corrupted encrypted strings and crashed binaries under `-enable-allobf`. `indgv` no longer indirects StringEncryption's synthesized globals (`EncryptedString*`, `DecryptSpace*`, `StringEncryptionEncStatus*`) and always encrypts addresses; both changes eliminate the miscompile.
*   **Fixed:** String Encryption Pass for Rust compatibility.
*   **Fixed:** Function Wrapper for Rust compatibility.

---

## 👥 Contributors

*   [Original Contributors](https://github.com/joaovarelas/Obfuscator-LLVM-16.0)
*   [@SoulDog Research](https://github.com/SoulDog-Research)