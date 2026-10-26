# Verification plan and report

## 1. Strategy

* **Directed tests first.** Every TRM example and rule (figures, tables, corner cases) has a
  directed test with an explicit expectation (exact bytes, burst shapes, register values,
  status bits), in addition to the reference model check.
* **Feature / control tests** for every programmers model feature (linking, restart, triggers,
  stream, errors, security, LPI, CTI, registers).
* **Constrained random only for coverage closure** (`regress_random.txt`), never as the main
  check of a feature.
* **Bug fix tests**: every RTL bug gets a test that fails on the RTL with only that fix reverted
  and passes on the fixed RTL ([bug_list.md](bug_list.md)).
* **Coverage-driven closure**: functional coverage + code coverage; each remaining hole is either
  closed with a directed test or excluded with a justification (§7).
* **Performance verification** after functional sign-off ([perf_report.md](perf_report.md)).
* **8 configurations** (bus width, address width, channel count, security, M1, synchronizers).

## 2. Test bench

```
                      +-------------------- dma_env ---------------------------------+
  dma_test (tests/) ->| dma_reg_api --APB VIP (master)--> DUT APB                     |
   one class / file   | dma_ref_model (element-level prediction from dma_cmd)        |
                      | dma_scoreboard <-- AXI5 VIP monitors (M0, M1)                 |
                      |     per-address ordered write expectations, read windows,    |
                      |     AxPROT / AxCACHE / AxQOS / ID checks, link reads          |
                      | AXI5 VIP slaves x2 (shared vip_sparse_mem) - timing knobs,    |
                      |     error / poison injection                                 |
                      | AXI4-Stream VIP: stream-out slave, stream-in master +         |
                      |     dma_stream_engine (in & out channels)                    |
                      | dma_trig_agent (trigger peripherals, sync / async clock)      |
                      | dma_lpi_driver (Q / P channel)                               |
                      | dma_coverage (cg_cmd, cg_axi, cg_event) + VIP coverage        |
                      | dma_perf_mon (performance counters)                          |
                      +--------------------------------------------------------------+
```

| Directory | Content |
|---|---|
| `tb/uvm/top` | `dma_tb_top.sv` (DUT, VIP interfaces, clocks with `+ACLK_DIV` / `+PCLK_DIV` / `+PER_CLK_PS`), `dma_ctrl_if.sv`, `dma_tb_defines.svh` |
| `tb/uvm/env` | package, configuration, command object, reference model, scoreboard, coverage, agents, perf monitor, environment + register API |
| `tb/uvm/seq` | sequences (stream packets with error injection) |
| `tb/uvm/tests` | `base/` (test bases), `data/`, `feature/`, `ctrl/`, `directed/`, `bugfix/`, `perf/` – **one test class per file** |
| `tb/uvm/regress` | regression lists |
| `tb/smoke` | stand-alone smoke bench (no UVM) |
| `vip_src/Common-Verification-IP-Library` | AMBA VIPs (APB, AXI5, AXI4-Stream) |

Checks:

* data: every written byte against the reference model (order per address), no unexpected
  write, reads only inside the expected source / descriptor windows;
* AXI attributes per channel: AxPROT (Secure / privileged / instruction for link reads),
  AxCACHE from MEMATTR, AxQOS = CHPRIO, ID = channel, 1 KB / burst rules (VIP protocol
  checkers: handshakes, W after AW, WLAST, strobes, outstanding);
* registers: values after reset / write / command end (directed), status / ERRINFO per case;
* protocols: APB VIP checks, 4-phase trigger monitor, LPI handshakes, stream TLAST / flush;
* RTL assertions: link reservation underflow / command buffer overflow (`dma_ch_link`).

## 3. Running

```
python scripts/run_sim.py build   [-v default|d32|d128|a40|min|nosec|ch8|nosync]
python scripts/run_sim.py run     -t dma_dir_1d_test [-s SEED] [-v VARIANT] [--plus "+NCMD=50"] [--wave] [--cov]
python scripts/run_sim.py regress -l tb/uvm/regress/regress_list.txt --variants default,d32,d128,a40,min,nosec,ch8,nosync
python scripts/run_sim.py regress -l tb/uvm/regress/regress_cov_all.txt --cov     # + merged UCDB / reports
python scripts/cov_report.py sim/regress/<stamp>                                 # RTL code coverage per unit
python scripts/run_sim.py regress -l tb/uvm/regress/regress_perf.txt --variants default,d32,d128
python scripts/perf_report.py sim/regress/<stamp> -o docs/perf_results.md
```

At most 12 compile / simulation jobs run at the same time (`MAX_JOBS`). Tool: QuestaSim 10.7c,
UVM 1.2 (`UVM_NO_DPI`), `-timescale 1ns/1ps`.

| List | Use |
|---|---|
| `regress_list.txt` | sign-off: 33 directed / feature / control / bug fix tests + 4 clock-enable / asynchronous trigger variants, one seed each, run on all 8 builds |
| `regress_random.txt` | constrained random (coverage closure only) |
| `regress_cov_all.txt` | sign-off + random, with coverage |
| `regress_bugfix.txt`, `regress_directed.txt`, `regress_feat.txt`, `regress_quick.txt`, `regress_stress.txt` | subsets |
| `regress_perf.txt` | performance suite |

## 4. Test plan (feature → tests)

| Feature (TRM) | Directed | Feature / control | Random (coverage) |
|---|---|---|---|
| 1D copy, TRANSIZE, alignment, XSIZE 32-bit (5.2.1) | `dma_dir_1d_test` | `dma_smoke_test` | `dma_1d_test`, `dma_rand_test` |
| 1D wrap / fill (5.2.2) | `dma_dir_wrap1d_test` | | `dma_wrapfill_test` |
| 2D, strides, mirror / rotation, reshaping (5.3) | `dma_dir_2d_test` | | `dma_2d_test` |
| Templates (5.3.3) | `dma_dir_tmplt_test` | | `dma_tmplt_test` |
| Burst generation, 1 KB, MAXBURSTLEN, FIFO/2, FIXED (4.3.6–4.3.8) | `dma_dir_burst_test` | | all |
| End-of-command register values (5.6.4) | `dma_dir_regend_test` | | |
| Command linking (5.7) | `dma_dir_link_test` | `dma_link_test`, `dma_link_err_test` | `dma_link_test +NCMD` |
| Autoboot (4.5) | | `dma_autoboot_test` | |
| Auto-restart, REGRELOADTYPE, DONETYPE / DONEPAUSEEN (5.6.3) | `dma_dir_done_test` | `dma_restart_test` | |
| Triggers: command mode, HW / SW / internal, trigger out (5.4) | `dma_dir_trig_test`, `dma_dir_trig_sw_test` | `dma_trig_cmd_test` | |
| Flow control triggers (DMA / peripheral driven) | `dma_dir_trig_sw_test` | `dma_trig_fc_test` (+ async clock) | `dma_trig_fc_test` |
| Trigger matrix, deny, handshake completion, port security | | `dma_trig_mtx_test` | |
| AXI-Stream (5.5) | `dma_dir_stream_test` | `dma_stream_test`, `dma_stream_err_test` | `dma_stream_test` |
| Errors: bus, poison, REGVALERR, CFGCONFLERR, selection (5.6.2) | | `dma_err_test`, `dma_link_err_test` | |
| Pause / resume / stop / disable / clear, all-channel, CTI (5.10, 5.11) | | `dma_ctrl_test`, `dma_unit_status_test` | |
| Security / privilege (5.9) | | `dma_sec_test`, `dma_trig_mtx_test` | |
| Register map, IDs, BUILDCFG, PSTRB (6) | | `dma_reg_test` | |
| GPO, interrupts, status pointer | | `dma_gpo_irq_test`, `dma_unit_status_test` | |
| LPI Q / P channel (4.6) | | `dma_lpi_test` | |
| Multi-channel arbitration, dual port | | `dma_multi_ch_test`, perf `arb` / `multich` | `dma_multi_ch_test` |
| Clock enables, asynchronous peripherals | sign-off variants `+ACLK_DIV` / `+PCLK_DIV` / `+TRIG_ASYNC` | | |
| RTL bug regressions | `bugfix/dma_bug01..04`, `dma_bug08_link_abort_test` | | |

## 5. Builds

See [architecture.md](architecture.md) §7: `default`, `d32`, `d128`, `a40`, `min`, `nosec`,
`ch8`, `nosync`. Tests skip the parts a build does not have (for example trigger tests on `min`).

## 6. Results

### 6.1 Sign-off

| Regression | Result |
|---|---|
| Sign-off list × 8 builds | 296 / 296 passed (`sim/regress/20261025_175520`) |
| Coverage regression (sign-off + random, default build) | 65 / 65 passed (`sim/regress/20261025_175940`) |
| Performance suite × 3 bus widths | 24 / 24 passed (`sim/regress/20261025_174705`) |

### 6.2 Functional coverage (merged)

| Covergroup | Coverage |
|---|---|
| `dma_coverage::cg_cmd` (command space: types, sizes, increments, alignment, memory types, burst limits, templates, strides, stream, triggers, ports, link, restart / reload, DONETYPE, channels, priority) | 100% |
| `dma_coverage::cg_axi` (direction × burst × size × length, unaligned, partial strobes) | 100% |
| `dma_coverage::cg_event` (27 events: errors, controls, LPI, CTI, autoboot, clear) | 100% |

Unreachable bins are excluded in the covergroup with a comment: link reads are always INCR and
full width and at most 8 beats on a 64-bit bus (16-word command buffer); narrow transfers are
always element aligned.

### 6.3 RTL code coverage (merged, default build)

| unit | stmt | branch | cond | expr | fsm_st | fsm_tr | toggle |
|---|---|---|---|---|---|---|---|
| dma_apb_if | 96.8 | 93.3 | 100.0 | 100.0 | 100.0 | 66.7 | 96.5 |
| dma_biu | 100.0 | 100.0 | - | 72.9 | - | - | 84.8 |
| dma_cdc_sync | 100.0 | 100.0 | - | - | - | - | 67.8 |
| dma_ch_agen | 99.2 | 95.6 | 81.0 | 87.9 | - | - | 61.3 |
| dma_ch_fifo | 100.0 | 100.0 | - | 87.5 | - | - | 99.0 |
| dma_ch_link | 94.9 | 92.9 | 61.8 | 86.4 | 100.0 | 78.9 | 80.0 |
| dma_ch_rdeng | 94.3 | 85.2 | 80.0 | 95.0 | - | - | 96.2 |
| dma_ch_rdp | 96.0 | 90.0 | 100.0 | 83.3 | - | - | 95.2 |
| dma_ch_regs | 99.7 | 97.4 | 92.8 | 50.0 | - | - | 72.4 |
| dma_ch_trigin | 98.1 | 97.9 | 85.0 | 75.0 | 100.0 | 100.0 | 94.6 |
| dma_ch_trigout | 100.0 | 95.0 | 80.0 | 100.0 | 100.0 | 100.0 | 96.7 |
| dma_channel | 98.0 | 97.1 | 76.0 | 91.4 | - | - | 73.1 |
| dma_fifo_ff | 84.2 | 90.9 | 100.0 | 100.0 | - | - | 98.0 |
| dma_lpi | 96.5 | 95.5 | 100.0 | 84.8 | 100.0 | 83.3 | 73.9 |
| dma_lrg_arb | 100.0 | 100.0 | 100.0 | 100.0 | - | - | 97.0 |
| dma_reset_sync | 100.0 | 75.0 | - | 33.3 | - | - | 41.7 |
| dma_rs_in | 100.0 | 100.0 | - | 57.1 | - | - | 97.1 |
| dma_rs_out | 93.3 | 93.3 | - | 100.0 | - | - | 99.8 |
| dma_sram_2p | 100.0 | 100.0 | - | - | - | - | 100.0 |
| dma_top | 100.0 | 100.0 | - | 83.3 | - | - | 62.1 |
| dma_trig_mtx | 98.9 | 94.8 | 69.7 | 73.3 | - | - | 38.8 |
| dma_unit | 99.5 | 91.1 | 67.4 | 81.8 | 100.0 | 100.0 | 44.0 |
| **total** | **98.5** | **95.5** | **76.1** | **83.8** | **100.0** | **87.7** | **72.2** |

FSM states 100%; all remaining FSM transitions are the exclusions of 6.4.

### 6.4 Remaining holes and exclusions

| Item | Reason |
|---|---|
| FSM `dma_ch_link.fst`: `F_IDLE / F_HDR / F_DONE -> F_WAIT` | The header error override needs decoded header data, which only exists in `F_HDRW / F_BODY / F_WAIT`: structurally unreachable |
| FSM `dma_ch_link.fst`: `F_HDR -> F_IDLE` | `F_HDR` lasts one cycle unless the channel AR queue is full; a STOP in exactly that cycle is a timing-only case (abort of the other states is covered) |
| FSM `dma_apb_if`: `A_EXEC / A_RESP -> A_IDLE`; `dma_lpi`: `Q_DENIED -> Q_STOPPED`, `P_WRST -> P_IDLE` | Only through `resetn` during an access / handshake (reset branch) |
| Toggle of `dma_trig_mtx`, `dma_unit`, `dma_top` | Unused upper bits of 32-bit wide trigger / channel vectors in a 4-channel / 4-trigger build, constant configuration inputs and tied-off M1 / CHID fields |
| Toggle of `dma_reset_sync` | Test mode / bypass inputs are constant |
| Condition / expression terms of `dma_ch_regs`, `dma_channel`, `dma_ch_link` | Mostly masked combinations of configuration bits (feature masks, AW = 32 high words) that cannot change independently |

### 6.5 Bugs

15 RTL bugs were found and fixed (6 during bring-up, BUG-01 … BUG-09 afterwards), see
[bug_list.md](bug_list.md). BUG-08 (link fetch abort) and BUG-09 (software flow-control request
consumed twice) were found by the coverage closure of this round.

## 7. Not covered here (recommended for sign-off at integration)

* Structural CDC / RDC analysis with a CDC tool (expected waivers in [cdc.md](cdc.md)).
* Lint with a dedicated tool (the RTL elaborates without vopt warnings in QuestaSim), synthesis and STA.
* Gate-level simulation and an SRAM macro build (`MEM_IMPL = 1`).
* Asynchronous AXI / APB bridges (outside the controller by design).
