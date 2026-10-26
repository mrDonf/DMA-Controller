# Clock domain crossing (CDC) and reset report

## 1. Clock structure

The controller has **one clock**, `clk`. Slower bus sides use clock enables instead of separate
clocks (TRM 4.1):

| Signal | Effect |
|---|---|
| `aclken_m0`, `aclken_m1` | AXI port outputs change and inputs are sampled only on `clk` edges with the enable high (`dma_rs_out` / `dma_rs_in` in the BIU) |
| `pclken` | APB inputs sampled / outputs changed only on enabled edges (`dma_apb_if`) |

AXI, APB and AXI-Stream interfaces are therefore synchronous to `clk`: there is no data path
CDC inside the controller. An integrator that runs a bus in a really asynchronous clock domain
must add an AXI / APB asynchronous bridge outside the controller.

## 2. Asynchronous inputs

Every asynchronous input goes through `dma_cdc_sync` (2-flop level synchronizer, the only CDC
cell of the design – replace its body with a technology synchronizer cell if needed).

| Input(s) | Synchronizer | Destination | Protocol / rule |
|---|---|---|---|
| `trig_in_req[TI]` | `dma_trig_mtx/g_tisync[*].g_s.u_sync` (when `TRIG_IN_SYNC_EN_MASK[TI]`) | trigger matrix | 4-phase req / ack |
| `trig_in_req_type[TI]` | none (qualifier) | sampled by the channel trigger FSM only in `T_WAIT` when the **synchronized** req is high | held stable by the protocol while req is high (TRM 5.4.1) |
| `trig_out_ack[TO]` | `dma_trig_mtx/g_tosync[*].g_s.u_sync` (when `TRIG_OUT_SYNC_EN_MASK[TO]`) | trigger matrix | 4-phase req / ack |
| `allch_stop_req_*`, `allch_pause_req_*`, `halt_req`, `restart_req` | `dma_unit/u_sync` (6 independent bits) | unit control | 4-phase handshakes / CTI levels, each bit independent |
| `clk_qreqn` | `dma_lpi/u_qsync` | Q-Channel FSM | Q-Channel protocol |
| `preq` | `dma_lpi/u_psync` | P-Channel FSM | P-Channel protocol |
| `pstate[3:0]` | none (qualifier) | sampled only in `P_IDLE` after the synchronized `preq` is high | held stable while `preq` is high (LPI protocol) |
| `pwakeup`, raw `trig_in_req`, raw control requests | none | `clk_qactive` only (OR gate) | intended asynchronous wake-up path to the clock controller, never used by DMAC logic |
| `boot_en`, `boot_addr`, `boot_memattr`, `boot_shareattr` | none | autoboot start | static configuration: must be stable before reset release (TRM 4.5) |
| `resetn` | `dma_reset_sync` | all flops | asynchronous assertion, synchronous de-assertion |

Rules enforced by construction:

1. Each synchronizer input is driven directly by a port (no logic in front of the first stage,
   no re-convergence: every synchronized bit is an independent control).
2. Multi-bit qualifiers never pass through a synchronizer; they are sampled only after the
   synchronized request is seen and the protocol guarantees them stable.
3. All handshake outputs (`trig_in_ack`, `trig_in_ack_type`, `trig_out_req`,
   `allch_*_ack_*`, `halted`, `clk_qacceptn`, `clk_qdeny`, `paccept`, `pdeny`, `pactive`) are
   driven directly by flops (glitch free).
4. 4-phase handshakes are never broken by a STOP or by a release of the trigger port: the
   trigger matrix completes an interrupted handshake itself (`ti_fin` / `to_fin`, BUG-05),
   verified by a protocol monitor in `ctrl/dma_trig_mtx_test`.

`TRIG_*_SYNC_EN_MASK` bits may be cleared only for peripherals that are synchronous to `clk`
(build `nosync` verifies this configuration).

## 3. Reset

* `resetn` is synchronized by `dma_reset_sync` (2 stages, asynchronous assertion, synchronous
  release). `RESET_SYNC_BYPASS = 1` uses `resetn` directly when the integrator guarantees a
  synchronous release.
* All control flops use asynchronous reset. FIFO storage (`dma_sram_2p`) and the command word
  buffer have no reset (contents are never used before being written).
* P-Channel `WARM_RST`: channels are paused before the request is accepted; the integrator
  then applies `resetn`.

## 4. Verification of the CDC behaviour

| Check | Where |
|---|---|
| Asynchronous trigger peripherals (different clock, random phase) | `dma_dir_trig_test +TRIG_ASYNC +PER_CLK_PS=23700`, `dma_trig_fc_test +TRIG_ASYNC +PER_CLK_PS=7100` (sign-off list) |
| Synchronous peripherals without synchronizers | build `nosync`, all sign-off tests |
| 4-phase trigger protocol under STOP / deny / release | `ctrl/dma_trig_mtx_test` (protocol monitor on all trigger pins) |
| Clock enables on AXI and APB | `dma_dir_1d_test +ACLK_DIV=2 +PCLK_DIV=3`, `dma_ctrl_test +ACLK_DIV=3` |
| LPI handshakes, WARM_RST, deny | `ctrl/dma_lpi_test` |
| All-channel stop / pause handshakes, CTI | `ctrl/dma_ctrl_test`, `ctrl/dma_unit_status_test` |

A structural CDC tool run (Questa CDC / SpyGlass CDC) is recommended at integration; expected
waivers: the qualifier crossings `trig_in_req_type` and `pstate` (stable-data pattern), the
`clk_qactive` wake-up OR, and the static `boot_*` inputs.

## 5. Constraints (STA)

* `trig_in_req`, `trig_out_ack`, `allch_*_req_*`, `halt_req`, `restart_req`, `clk_qreqn`,
  `preq`: `set_false_path` to the first synchronizer stage (or `set_max_delay -datapath_only` of
  one `clk` period), synchronizer flops placed together.
* `trig_in_req_type`, `pstate`: `set_max_delay -datapath_only` one `clk` period (sampled two
  cycles after the synchronized request).
* `boot_*`: false path (static).
* `pwakeup` → `clk_qactive`: combinational path to the clock controller, constrain at system
  level.
* Ports with the synchronizer disabled (`TRIG_*_SYNC_EN_MASK = 0`) are normal synchronous I/O.
