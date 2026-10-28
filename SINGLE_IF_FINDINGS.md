# Single-interface (and related double-interface) findings

Debug of the single VRF interface (`DoubleIf = 0`) in X-HEEP (`x-heep-cve2`), done on top of
`cc800aa4` (dotp). Fixes 3–5 are applied in this working tree (not committed); 1–2 are X-HEEP /
build-configuration issues you already knew about and are listed for completeness only.

| # | Problem | Interface | Where | Status |
|---|---------|-----------|-------|--------|
| 1 | `.DoubleIf(1'b1)` hard-wired in X-HEEP's vendored `cve2_top.sv` | single | X-HEEP `hw/vendor/openhwgroup_cv32e20/rtl/cve2_top.sv:195` | X-HEEP side, not in ANT-V |
| 2 | `DOUBLE_W_IF` FuseSoC bool emitted as `-DDOUBLE_W_IF=0`, still "defined" for `` `ifdef `` | single | `cve2_top.core`, X-HEEP `core-v-mini-mcu.core` | build config, not changed |
| 3 | Misaligned store of a single word writes stale data | both | `cve2_vrf_interface.sv`, `cve2_vrf_interface_double.sv` | **fixed** |
| 4 | Misaligned store retires before the LSU's second access: the next instruction's `rd` gets the store address + 4 | double | `cve2_vrf_interface_double.sv` (`VRF_STORE_LAST`) | **fixed** (new state `VRF_STORE_DRAIN`) |
| 5 | Empty slide (OFFSET >= vl) never terminates | single | `cve2_vrf_interface.sv` (`VRF_IDLE`) | **fixed** (port of the double-interface `slide_empty`) |

## 1. `DoubleIf` hard-wired in X-HEEP's `cve2_top.sv`

X-HEEP's vendored copy has `.DoubleIf(1'b1),//(`ifdef DOUBLE_W_IF 1'b1 `else 1'b0 `endif)`
(ANT-V's `cve2_top.sv` is correct). Without `DOUBLE_W_IF`, `cpu_subsystem.sv` / `cve2_xif_wrapper.sv`
tie off the instruction port write path (`we = 0`, `be = 1111`) while the core still runs the double
interface: every slave-owned beat is silently not written (odd elements read back 0) and
master/slave sync hangs for vl >= 4. The real single interface was never elaborated in X-HEEP.

## 2. `DOUBLE_W_IF` macro

FuseSoC emits a `bool` `vlogdefine` set to false as `-DDOUBLE_W_IF=0`, which `` `ifdef `` treats as
defined, so the parameter cannot select the single interface. `cve2_top.core` (default target) also
forces `DOUBLE_W_IF=true`. To build single-IF for these tests the parameter was removed from the
target parameter lists of `core-v-mini-mcu.core` and `cve2_top.core` (X-HEEP scratch copy only).

## 3. Misaligned single-word store writes stale data (both interfaces) — fixed

A store whose base is not word aligned (`lsu_offset_q != 0`, e.g. `vse8.v` to `buf + 1`) is a
misaligned word access for the LSU, done in two bus accesses with the same write data. The VRF
keeps each word stable for both accesses with two registers: the word is sampled into
`rs3_q`/`rs3_q_1` (`curr_demux_sel`), the next read flips the demux, and the LSU reads the
*previous* register through `mux_sel = ~curr_demux_sel`. For the last word the flip is done in
`VRF_STORE_WAITLSU` on `lsu_done_i`. When the whole store is a single word (vl * SEW <= 32 bits)
the last pass is the first one, `lsu_done_i` is 0, the demux never flips and the LSU writes the
never-loaded `rs3_q_1`.

Reproducer: `vsetvli e8 vl=2; vle8.v v0,(src); vse8.v v0,(buf+1)` writes `aa 00 00 aa` instead of
`aa f5 f8 aa`, on both interfaces (multi-word stores are correct).

Fix (both files, `VRF_STORE_WAITLSU`, last-beat branch): flip the demux also on the first pass:

```systemverilog
if (lsu_offset_q != 2'b00 && (lsu_done_i || first_iteration_q)) begin
  next_demux_sel = ~curr_demux_sel;
end
```

## 4. Double interface: misaligned store retires too early, corrupts a scalar register — fixed

`VRF_STORE_LAST` retired the instruction on the LSU grant of the last word
(`vector_done_mst = lsu_gnt_i`). For a misaligned base the LSU splits that word in two accesses,
and the second address (address + 4) is computed with Ibex's misaligned mechanism: `addr_incr_req`
makes the ID stage drive the ALU with (last address, 4), and `cve2_lsu_interface` takes
`lsu_addr_o = scalar_addr_i`. Retiring on the first grant hands that ALU override to the *next*
instruction, which writes the address into its `rd`.

Reproducer: `vle8.v` + `vse8.v` (vl=2) to `raw + 1`, followed by `mv a1, s5; call printf("%d", vl)`:
the printed value was `0xED81` = store address `0xED7D` + 4, not 2 (`s5` itself intact). Only the
last word of a misaligned store is affected (the previous ones wait for `lsu_done_i` in
`VRF_STORE_WAITLSU`); aligned stores and the single interface (which waits for `lsu_done_i` before
`vector_done_o`) are not affected. `vec_memory_test` does not see it because it only checks memory.

Fix: new state `VRF_STORE_DRAIN` (appended to `mst_state_t`, existing encodings unchanged):

- `VRF_STORE_LAST`: `vector_done_mst = lsu_gnt_i && (lsu_offset_q == 2'b00)`; on `lsu_gnt_i` go to
  `VRF_STORE_DRAIN` if `lsu_offset_q != 0`, else `VRF_IDLE_MST` (aligned: unchanged, no extra cycle).
- `VRF_STORE_DRAIN`: no LSU request, `mux_sel = ~curr_demux_sel` held (same write data for the
  second access), `vector_done_mst = lsu_done_i`, `VRF_IDLE_MST` on `lsu_done_i`.
- `mst_tail_write` also true in `VRF_STORE_DRAIN`: the LSU recomputes the second access from its
  inputs, so the partial tail byte enables must stay applied.

## 5. Single interface: empty slide never terminates — fixed

`vslideup`/`vslidedown` with OFFSET >= vl (nothing to write) starts with
`num_iterations = vl_words - offset_words` = 0 or underflowed and never retires (the interface
reads forever in `VRF_READ`). The double interface already handles it (`slide_empty`, retire from
IDLE). Reproducer: `vec_slide_seq_test`, `test_mixed_sequence` kind 5 (`vslideup.vi v0, v2, 2`)
with vl = 2; on the double interface the test finishes, on the single one it hangs (masked in the
regression by the test's xfail, which is about the vsub operand swap).

Fix (`VRF_IDLE`): retire when `slide_op_i && slide_offset_i >= num_bytes_elements`.
`agu_load_o` stays asserted on that path: it is what makes `slide_offset_i` valid in this cycle
(`slide_addr_req_i = agu_load && vrf_slide_op` in the core).

## Other findings

- **`vec_memory_test` "STUCK" on single-IF was the cycle budget, not a hang**: the misaligned
  failures of (3) print 12 lines, and UART output costs millions of cycles in simulation. With (3)
  fixed it passes in 1.2M cycles, like double-IF.
- **X-HEEP's vendored single interface is older than ANT-V's** (`VRF_STORE_READ` before `c953a13b`);
  both behave the same in all the tests above, but X-HEEP should be re-vendored.
- **No trap can be handled with X-HEEP's runtime**: `handler_exception` is compiled with the
  interrupt ABI for zve32x, so it saves the vector state starting with `csrr vlenb`; the core does
  not implement `vlenb` (0xC22, read-only VLEN/8), so the read traps again and recurses until the
  stack overflows. `vec_dotp_seq_test` works around it with its own assembly handler.
- **Test gap**: no regression test checks the scalar registers after a misaligned vector store, or
  single-word misaligned stores with a cleared `rs3_q_1`; a reproducer like the one in (4) would
  be worth adding.

## Verification

`x-heep-cve2` vector regression (`util/vec_regression.py`, 99 tests: the original 41, 57 generated
dotp tests and `vec_dotp_seq_test`), with this tree's `cve2_vrf_interface.sv`,
`cve2_vrf_interface_double.sv` and the dotp RTL of `cc800aa4` vendored into scratch copies of
X-HEEP (fix 1 applied there):

| Configuration | Result |
|---------------|--------|
| Single interface (`DoubleIf = 0`, `DOUBLE_W_IF` undefined) | **96 PASS, 3 XFAIL**: all 58 dotp tests pass, no hang |
| Double interface | **96 PASS, 3 XFAIL**: status and cycles identical to the run before these fixes for 98/99 tests |
| Before the fixes, single interface | 4 PASS, 90 FAIL, 2 STUCK (fix 1 missing); with fix 1 only: 95 PASS, `vec_memory_test` STUCK, `vec_slide_seq_test` hang |

The 3 XFAIL are the known decoder issues (vsub operand swap, vmulhsu signedness), the same on both
interfaces. The only cycle change on double-IF is `vec_memory_test` (+5.5k, 1.2233M -> 1.2288M).
Measured directly with `mcycle`, a misaligned `vse8` now costs 2–4 cycles more than an aligned one
(vl = 1..9: 8–14 vs 6–10 cycles), so the drain itself is cheap. The rest of the difference most
likely comes from the old early retirement corrupting a register in the test's own loop code;
this is not proven.

Probes used (scratch copies, not committed anywhere): misaligned `vse8` byte check and register
integrity for vl = 1..9 at offset 1 (double-IF: correct bytes and correct scalar after the fix),
the `vec_memory_test` sections one by one, `vec_slide_seq_test` with a periodic PC/state print.

Lint: `verilator --lint-only` with and without `DOUBLE_W_IF`, no new warnings.

## Temporary changes left in `x-heep-cve2` (not in git, originals backed up)

- `hw/vendor/openhwgroup_cv32e20/rtl/`: dotp RTL (`cc800aa4`, `cve2_core.sv` patched on the X-HEEP
  variant), `cve2_top.sv` with fix 1, `cve2_vrf_interface.sv` = ANT-V `c953a13b` version (before
  fixes 3 and 5). Re-vendor from ANT-V to get the fixed interfaces.
- `util/vec_test_gen.py`, `sw/applications/basic_vec_test/main.c.tpl`,
  `util/vec_regression_tests.hjson`: dotp support and tests; `sw/applications/vec_dotp_seq_test/`.
- Benchmark files (new names): `util/dotp_matmul_*`, `sw/applications/dotp_matmul/`.
