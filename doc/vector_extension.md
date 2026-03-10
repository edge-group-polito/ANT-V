# CVE2 Vector Extension Documentation

This document provides a detailed description of the vector extension features implemented in the CVE2 RISC-V core. The implementation is based on a subset of the RISC-V Vector Extension (RVV) 1.0 specification, with additional custom instructions for lightweight, implementation-focused vector operations.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
   - 2.1 [Vector Register File (VRF)](#21-vector-register-file-vrf)
   - 2.2 [Address Generation Unit (AGU)](#22-address-generation-unit-agu)
   - 2.3 [Fracturable ALU](#23-fracturable-alu)
   - 2.4 [Fracturable Multiplier](#24-fracturable-multiplier)
   - 2.5 [Memory Interface](#25-memory-interface)
3. [Vector Configuration](#3-vector-configuration)
   - 3.1 [Configuration Instructions](#31-configuration-instructions)
   - 3.2 [Vector CSRs](#32-vector-csrs)
   - 3.3 [Supported SEW and LMUL Combinations](#33-supported-sew-and-lmul-combinations)
4. [Supported Instructions](#4-supported-instructions)
   - 4.1 [Vector Load Instructions](#41-vector-load-instructions)
   - 4.2 [Vector Store Instructions](#42-vector-store-instructions)
   - 4.3 [Vector Integer Arithmetic](#43-vector-integer-arithmetic)
   - 4.4 [Vector Logical Instructions](#44-vector-logical-instructions)
   - 4.5 [Vector Min/Max Instructions](#45-vector-minmax-instructions)
   - 4.6 [Vector Multiply-Accumulate](#46-vector-multiply-accumulate)
   - 4.7 [Vector Move/Merge Instructions](#47-vector-movemerge-instructions)
   - 4.8 [Vector Slide Instructions](#48-vector-slide-instructions)
5. [Custom Vector Instructions (VX)](#5-custom-vector-instructions-vx)
   - 5.1 [Motivation](#51-motivation)
   - 5.2 [Operand Encoding Strategy](#52-operand-encoding-strategy)
   - 5.3 [Custom Instruction Opcodes](#53-custom-instruction-opcodes)
   - 5.4 [Supported Custom Instructions](#54-supported-custom-instructions)
6. [Implementation Details](#6-implementation-details)
   - 6.1 [Parameters](#61-parameters)
   - 6.2 [Pipeline Integration](#62-pipeline-integration)
   - 6.3 [FSM States](#63-fsm-states)
7. [Limitations and Unsupported Features](#7-limitations-and-unsupported-features)
8. [Instruction Encoding Reference](#8-instruction-encoding-reference)
9. [Build Procedure](#9-build-procedure)

---

## 1. Overview

The CVE2 vector-extended core, ANT-V, provides SIMD (Single Instruction, Multiple Data) capabilities to the CVE2 core. It implements a subset of the RISC-V Vector Extension 1.0 specification along with custom vector instructions (VX) designed for minimal hardware overhead.
<img src="logo_ant.png" alt="ANT-V logo" width="320">

### Key Features

| Feature | Description |
|---------|-------------|
| **VLEN** | Configurable vector register length (default: 4096 bits) |
| **SEW** | Supported element widths: 8, 16, 32 bits |
| **LMUL** | Supported values: 1/8, 1/4, 1/2, 1, 2, 4, 8 |
| **Registers** | 32 vector registers (v0-v31) |
| **Custom ISA** | Additional VX (custom vector) instructions |

### Design Philosophy

The CVE2 vector extension is **lightweight and implementation-driven**, prioritizing:
- Minimal decoder and pipeline overhead
- Reuse of existing scalar infrastructure
- Fixed 32-bit instruction width
- Memory-mapped vector register file access

---

## 2. Architecture
![CVE2 Vector Extension Block Diagram](Block_diagram.png)

### 2.1 Vector Register File (VRF)

The Vector Register File is implemented as a memory-mapped region in the data address space.

| Parameter | Value |
|-----------|-------|
| **VLENb** | 4096 bits (configurable) |
| **Start Address** | `0x00020000` (configurable via `VRF_START_ADDR`) |
| **Access Width** | 32 bits (PIPE_WIDTH) |
| **Number of Registers** | 32 (v0-v31) |

The VRF interface module (`cve2_vrf_interface.sv`) manages all vector register file operations through a finite state machine (FSM).

### 2.2 Address Generation Unit (AGU)

The AGU (`cve2_agu.sv`) manages address calculation for vector register file accesses:

- Generates addresses for source registers (rs1, rs2) and destination register (rd)
- Supports automatic increment for sequential element access
- Handles slide operation address offsets
- Supports LMUL-based register grouping

### 2.3 Fracturable ALU

The fracturable adder (`cve2_fracturable_adder.sv`) enables SIMD operations on sub-word elements:

| SEW | Operation |
|-----|-----------|
| 8-bit | 4 parallel 8-bit additions/subtractions |
| 16-bit | 2 parallel 16-bit additions/subtractions |
| 32-bit | 1 32-bit addition/subtraction |

The control of carry propagation between sub-word boundaries enables efficient element-wise operations.

### 2.4 Fracturable Multiplier

The fracturable multiplier (`cve2_multdiv_fast_fracturable.sv`) supports:

| SEW | Operation |
|-----|-----------|
| 8-bit | Four 8-bit multiplications in parallel |
| 16-bit | Two 16-bit multiplications |
| 32-bit | Single 32-bit multiplication |

The multiplier reuses the existing three 17-bit multiplier kernels with additional logic for vector operations.

### 2.5 Memory Interface

Two key modules handle vector memory operations:

#### Data Memory Switch (`cve2_dmem_switch.sv`)
- Arbitrates data memory access between the LSU (scalar) and VRF (vector)
- Vector operations take priority when active
- Manages grant and response signals for both interfaces

#### LSU Interface (`cve2_lsu_interface.sv`)
- Handles address generation for vector memory operations
- Supports unit-stride and constant-stride access patterns
- Manages byte-enable signals for partial word access

---

## 3. Vector Configuration

### 3.1 Configuration Instructions

| Instruction | Description |
|-------------|-------------|
| `vsetvli rd, rs1, vtypei` | Set VL and vtype from scalar register and immediate |
| `vsetivli rd, uimm, vtypei` | Set VL and vtype using immediates |
| `vsetvl rd, rs1, rs2` | Set VL and vtype from scalar registers |

#### Special Encoding Cases

| Condition | Behavior |
|-----------|----------|
| `rs1 = x0, rd ≠ x0` | Set `vl = VLMAX` |
| `rs1 = x0, rd = x0` | Keep current `vl` value |

### 3.2 Vector CSRs

The vector CSRs are managed by `cve2_cs_registers_vec.sv`:

| CSR Field | Bits | Description |
|-----------|------|-------------|
| `vsew` | [5:3] | Selected Element Width encoding |
| `vlmul` | [2:0] | Vector Length Multiplier encoding |
| `vma` | [7] | Vector Mask Agnostic |
| `vta` | [6] | Vector Tail Agnostic |
| `vill` | N/A | Illegal configuration flag |
| `vl` | 32 bits | Vector Length register |

### 3.3 Supported SEW and LMUL Combinations

#### SEW Encodings

| vsew[2:0] | SEW (bits) |
|-----------|------------|
| 000 | 8 |
| 001 | 16 |
| 010 | 32 |
| 111 | Invalid |

#### LMUL Encodings

| vlmul[2:0] | LMUL |
|------------|------|
| 000 | 1 |
| 001 | 2 |
| 010 | 4 |
| 011 | 8 |
| 101 | 1/8 |
| 110 | 1/4 |
| 111 | 1/2 |

#### Valid Combinations

| SEW | Valid LMUL Values |
|-----|-------------------|
| 8-bit | 1/4, 1/2, 1, 2, 4, 8 |
| 16-bit | 1/2, 1, 2, 4, 8 |
| 32-bit | 1, 2, 4, 8 |

**Note:** Fractional LMUL is limited to combinations where `SEW/LMUL ≤ ELEN`.

---

## 4. Supported Instructions

### 4.1 Vector Load Instructions

#### Standard Unit-Stride Loads

| Instruction | funct6 | Description |
|-------------|--------|-------------|
| `vle8.v vd, (rs1)` | N/A | Load 8-bit elements |
| `vle16.v vd, (rs1)` | N/A | Load 16-bit elements |
| `vle32.v vd, (rs1)` | N/A | Load 32-bit elements |

#### Constant-Stride Loads

| Instruction | Description |
|-------------|-------------|
| `vlse8.v vd, (rs1), rs2` | Strided load of 8-bit elements |
| `vlse16.v vd, (rs1), rs2` | Strided load of 16-bit elements |
| `vlse32.v vd, (rs1), rs2` | Strided load of 32-bit elements |

**Supported EEW for memory operations:** 8-bit, 16-bit, 32-bit

### 4.2 Vector Store Instructions

#### Standard Unit-Stride Stores

| Instruction | Description |
|-------------|-------------|
| `vse8.v vs3, (rs1)` | Store 8-bit elements |
| `vse16.v vs3, (rs1)` | Store 16-bit elements |
| `vse32.v vs3, (rs1)` | Store 32-bit elements |

#### Constant-Stride Stores

| Instruction | Description |
|-------------|-------------|
| `vsse8.v vs3, (rs1), rs2` | Strided store of 8-bit elements |
| `vsse16.v vs3, (rs1), rs2` | Strided store of 16-bit elements |
| `vsse32.v vs3, (rs1), rs2` | Strided store of 32-bit elements |

### 4.3 Vector Integer Arithmetic

#### Addition

| Instruction | funct6 | funct3 | Description |
|-------------|--------|--------|-------------|
| `vadd.vv vd, vs2, vs1` | 000000 | 000 | Vector + Vector |
| `vadd.vx vd, vs2, rs1` | 000000 | 100 | Vector + Scalar |
| `vadd.vi vd, vs2, imm` | 000000 | 011 | Vector + Immediate |

#### Subtraction

| Instruction | funct6 | funct3 | Description |
|-------------|--------|--------|-------------|
| `vsub.vv vd, vs2, vs1` | 000010 | 000 | Vector − Vector |
| `vsub.vx vd, vs2, rs1` | 000010 | 100 | Vector − Scalar |

#### Multiplication

| Instruction | funct6 | funct3 | Description |
|-------------|--------|--------|-------------|
| `vmul.vv vd, vs2, vs1` | 100101 | 010 | Vector × Vector |
| `vmul.vx vd, vs2, rs1` | 100101 | 110 | Vector × Scalar |

### 4.4 Vector Logical Instructions

| Operation | .vv (funct6/funct3) | .vx (funct6/funct3) | .vi (funct6/funct3) |
|-----------|---------------------|---------------------|---------------------|
| AND | 001001/000 | 001001/100 | 001001/011 |
| OR | 001010/000 | 001010/100 | 001010/011 |
| XOR | 001011/000 | 001011/100 | 001011/011 |

### 4.5 Vector Min/Max Instructions

| Instruction | funct6 | funct3 | Description |
|-------------|--------|--------|-------------|
| `vminu.vv` | 000100 | 000 | Unsigned minimum (vector-vector) |
| `vminu.vx` | 000100 | 100 | Unsigned minimum (vector-scalar) |
| `vmin.vv` | 000101 | 000 | Signed minimum (vector-vector) |
| `vmin.vx` | 000101 | 100 | Signed minimum (vector-scalar) |
| `vmaxu.vv` | 000110 | 000 | Unsigned maximum (vector-vector) |
| `vmaxu.vx` | 000110 | 100 | Unsigned maximum (vector-scalar) |
| `vmax.vv` | 000111 | 000 | Signed maximum (vector-vector) |
| `vmax.vx` | 000111 | 100 | Signed maximum (vector-scalar) |

### 4.6 Vector Multiply-Accumulate

| Instruction | funct6 | funct3 | Description |
|-------------|--------|--------|-------------|
| `vmacc.vv vd, vs1, vs2` | 101101 | 010 | vd = vs1 × vs2 + vd |
| `vmacc.vx vd, rs1, vs2` | 101101 | 110 | vd = rs1 × vs2 + vd |


### 4.7 Vector Move Instructions

| Instruction | funct6 | funct3 | Description |
|-------------|--------|--------|-------------|
| `vmv.v.v vd, vs1` | 010111 | 000 | Copy vector register |
| `vmv.v.x vd, rs1` | 010111 | 100 | Splat scalar to vector |
| `vmv.v.i vd, imm` | 010111 | 011 | Splat immediate to vector |

### 4.8 Vector Slide Instructions

| Instruction | funct6 | funct3 | Description |
|-------------|--------|--------|-------------|
| `vslideup.vx vd, vs2, rs1` | 001110 | 100 | Slide elements up by scalar |
| `vslideup.vi vd, vs2, uimm` | 001110 | 011 | Slide elements up by immediate |
| `vslidedown.vx vd, vs2, rs1` | 001111 | 100 | Slide elements down by scalar |
| `vslidedown.vi vd, vs2, uimm` | 001111 | 011 | Slide elements down by immediate |

---

## 5. Custom Vector Instructions (VX)

### 5.1 Motivation

The custom VX instructions provide an alternative encoding for vector operations designed to:

- Avoid complexity of standard RVV 1.0 instruction encoding
- Reuse existing scalar decode and pipeline infrastructure
- Preserve fixed 32-bit instruction width
- Minimize hardware and decoder overhead

### 5.2 Operand Encoding Strategy

Unlike standard RVV, **vector register indices are not encoded in the instruction** for VX instructions.

Instead:
- The instruction is identified as a vector operation via the `vx_instr` signal
- Vector register indices are stored **inside a scalar register**
- The scalar register `rs2` (`rf_rdata_b`) carries all vector operand indices

#### Vector Register Address Extraction

```systemverilog
assign vrf_raddr_a  = (vx_instr) ? rf_rdata_b[20:16] : rf_raddr_a;
assign vrf_raddr_b  = (vx_instr) ? rf_rdata_b[12:8]  : rf_raddr_b;
assign vrf_waddr_wb = (vx_instr) ? rf_rdata_b[4:0]   : rf_waddr_wb;
```

| Bits | Field |
|------|-------|
| [20:16] | vs1 (source vector 1) |
| [12:8] | vs2 (source vector 2) |
| [4:0] | vd (destination vector) |

### 5.3 Custom Instruction Opcodes

| Opcode | Value | Description |
|--------|-------|-------------|
| `OPCODE_OP_VX` | `7'h5b` | Custom arithmetic vector ops |
| `OPCODE_LOAD_VX` | `7'h0b` | Custom vector load |
| `OPCODE_STORE_VX` | `7'h2b` | Custom vector store |

These use the RISC-V custom-0, custom-1, and custom-2 opcode spaces.

### 5.4 Supported Custom Instructions

#### Custom Load/Store

| Instruction | Description |
|-------------|-------------|
| `vxle.v` | Custom unit-stride vector load |
| `vxse.v` | Custom unit-stride vector store |

**Note:** Only unit-stride operations are supported; no indexed or segmented access.

#### Custom Arithmetic Operations

All standard vector arithmetic operations have custom VX equivalents:

| Category | Custom Instructions |
|----------|---------------------|
| Add/Sub | `xvadd.vv/vx/vi`, `xvsub.vv/vx` |
| Multiply | `xvmul.vv/vx` |
| Logical | `xvand.vv/vx/vi`, `xvor.vv/vx/vi`, `xvxor.vv/vx/vi` |
| Min/Max | `xvmin[u].vv/vx`, `xvmax[u].vv/vx` |
| MAC | `xvmacc.vv/vx` |
| Move | `xvmv.v.v/v.x/v.i` |
| Slide | `xvslideup.vx/vi`, `xvslidedown.vx/vi` |

---

## 6. Implementation Details

### 6.1 Parameters

The vector extension is controlled by the following top-level parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `RV32VX` | `1'b0` | Enable vector extension |
| `VLEN` | `VLENb` (4096) | Vector register length in bits |
| `VRF_START_ADDR` | `0x00020000` | Base address of VRF in memory map |

Additional package constants from `cve2_pkg.sv`:

| Constant | Value | Description |
|----------|-------|-------------|
| `VLENb` | `32'd4096` | Vector register length in bits |
| `VAddrWidth` | `$clog2(VLENb/8)` | Address width for VRF |
| `VRF_START_ADDR_FULL` | `32'h00020000` | Default VRF base address |


## 7. Limitations and Unsupported Features

The following RVV 1.0 features are **NOT supported**:

| Feature | Status |
|---------|--------|
| Indexed memory operations | Not implemented |
| Segmented memory operations | Not implemented |
| Fixed-point operations | Not implemented |
| Floating-point operations | Not implemented |
| Vector reduction operations | Not implemented |
| Vector mask operations (partial) | Limited support |
| Widening/narrowing operations | Not implemented |
| `vstart` CSR | Not fully implemented |
| `vxrm`, `vxsat` CSRs | Not implemented |
| 64-bit SEW | Not supported (RV32 base) |
---


## 8. Instruction Encoding Reference

### Standard Vector Instruction Format (OPCODE_OP_V = 0x57)

```
31    26 25 24  20 19  15 14  12 11   7 6    0
[funct6][vm][vs2  ][vs1  ][funct3][vd  ][opcode]
```

### Vector Load Format (OPCODE_LOAD_V = 0x07)

```
31 29 28 27 26 25 24  20 19  15 14  12 11   7 6    0
[nf ][mew][mop][vm][lumop][rs1  ][width][vd  ][opcode]
```

### Vector Store Format (OPCODE_STORE_V = 0x27)

```
31 29 28 27 26 25 24  20 19  15 14  12 11   7 6    0
[nf ][mew][mop][vm][sumop][rs1  ][width][vs3 ][opcode]
```

### Custom VX Arithmetic Format (OPCODE_OP_VX = 0x5b)

```
31    26 25 24  20 19  15 14  12 11   7 6    0
[funct6][vm][rs2  ][rs1  ][funct3][rd  ][opcode]
```

Where vector register indices are encoded in `rs2` register value at runtime.

---

## 9. Build Procedure

The CVE2 project uses [FuseSoC](https://fusesoc.readthedocs.io/) as its core package manager and build system. All cores are described by `.core` files (CAPI2 format) at the root of the repository.

### Building the Verilator Model

The Verilator simulation model is built through the `sim` target of the `cve2_riscv_compliance` core. FuseSoC invokes Verilator in `cc` mode, which compiles the SystemVerilog design and C++ testbench into a C++ model.

This is also available via the Makefile shorthand:

```bash
make compile_verilator
```

## References

- [RISC-V Vector Extension Specification v1.0](https://github.com/riscv/riscv-v-spec)
- [CVE2 RTL Source Code](https://github.com/openhwgroup/cve2)

---

