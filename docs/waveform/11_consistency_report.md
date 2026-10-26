# 11. Consistency report: waveforms, TRM, RTL and simulation

This chapter documents how the 41 waveforms were checked against the **specification** (Arm CoreLink DMA-350 TRM
102482_0000_04), the **RTL** (`rtl/`) and the **simulation** itself, and what the result is.

**Result: no inconsistency was found between the TRM, the RTL and the simulated behaviour for everything exercised in
these figures. All 19 simulations pass their scoreboards, and 395 automatic protocol check instances report 0 violations.**

## 11.1 Method

| Step | What was done |
|---|---|
| 1. Specification | The relevant TRM chapters were read and compared with the figures: interfaces (4.2 – 4.9), commands (5.2 – 5.3), triggers (5.4), stream (5.5), channel life cycle and errors (5.6), linking and autoboot (5.7), arbitration (5.8), power and control (5.9 – 5.11), and the register descriptions (6.5). |
| 2. RTL | The RTL that produces each behaviour was read (`dma_channel`, `dma_ch_agen`, `dma_ch_trig`, `dma_ch_link`, `dma_biu`, `dma_lrg_arb`, `dma_lpi`, `dma_apb_if`, `dma_unit`, `dma_top`) and its rules were compared with the TRM and with what the waveform shows. |
| 3. Simulation | Existing UVM test cases were run (seed 1, build `default`, QuestaSim 10.7c). Each test checks every written byte with a reference model and a scoreboard; the results are in 11.2. |
| 4. Automatic protocol checks | [`tools/check_protocols.py`](tools/check_protocols.py) re-checks the DUT pins of every simulation cycle by cycle for the rules in 11.3 (output: [`protocol_check_results.txt`](protocol_check_results.txt)). |
| 5. Figure review | Every figure was rendered and inspected, and its numbers (addresses, lengths, strobes, cycle numbers) were taken from the handshake timeline that `gen_all.py --facts` prints from the same VCD, then compared with the text of this folder. |

## 11.2 Simulations behind the figures

| Test case | Commands checked by the scoreboard | Result |
|---|---|---|
| `dma_dir_1d_test` (full run; the VCD covers the first 400 µs) | 193 | PASS, 0 UVM errors |
| `dma_dir_2d_test` | 167 | PASS |
| `dma_dir_wrap1d_test` | 51 | PASS |
| `dma_dir_burst_test` | 8 | PASS |
| `dma_dir_link_test` | 2 | PASS |
| `dma_dir_done_test` | 5 | PASS |
| `dma_restart_test` | 7 | PASS |
| `dma_autoboot_test` | 2 | PASS |
| `dma_dir_trig_test` | 4 | PASS |
| `dma_dir_trig_sw_test` | 7 | PASS |
| `dma_trig_cmd_test` | 11 | PASS |
| `dma_dir_stream_test` | 8 | PASS |
| `dma_stream_test` | 24 | PASS |
| `dma_ctrl_test` | 9 | PASS |
| `dma_err_test` | 23 | PASS |
| `dma_gpo_irq_test` | 13 | PASS |
| `dma_lpi_test` | 3 | PASS |
| `dma_multi_ch_test` | 32 | PASS |
| `dma_perf_arb_test` | contention measurements, data checked | PASS |

Together: **569 commands**; every byte written was compared with the reference model; 0 UVM errors and fatals. The
functional test cases also pass on all 8 builds in the project's sign-off regression (296 / 296) and the performance
suite passes on 3 bus widths ([`docs/verification.md`](../verification.md) §6).

## 11.3 Automatic protocol checks

The checker runs on every simulation. `checked` is the number of items examined across the 19 VCDs.

| Rule | Reference | Items checked | Violations |
|---|---|---|---|
| `AR`, `AW`, `W`: `VALID` held and payload stable until `READY` | AMBA AXI | 30,263 / 13,606 / 46,141 cycles | 0 |
| Every `AR` / `AW` burst: size ≤ bus width, `FIXED` or `INCR` only, ≤ 16 beats, **never crosses a 1 KB boundary** | TRM 4.3.1, 4.3.6 | 44,333 bursts | 0 |
| `R` beats = `ARLEN` + 1, `RLAST` on the last beat, ID routing | AMBA AXI | 74,226 beats | 0 |
| **`W` never before its `AW`**, beats = `AWLEN` + 1, `WLAST` on the last beat | TRM 4.3.3 | 74,091 beats | 0 |
| `WSTRB` lies inside the byte window of its beat (FIXED bursts handled) | AMBA AXI | 74,091 beats | 0 |
| Every `B` belongs to a completely written burst | AMBA AXI | 22,099 responses | 0 |
| **Read bytes in flight ≤ channel FIFO size** (a read is issued only with room for the whole response) | TRM 4.3.4, 5.8.1 | 22,217 bursts | 0 |
| Command-link reads: `ARCMDLINK` = 1, `ARPROT[2]` = 1, size = bus width, INCR; data reads have `ARPROT[2]` = 0 | TRM 4.3.9, 5.7.2 | 16 link reads, 22,217 data reads | 0 |
| **`AxID` = channel and `AxQOS` = `CH_CTRL.CHPRIO`** of that channel (tests without links) | TRM 4.3.2, 5.8 | 44,263 transfers | 0 |
| APB: setup phase, address / data stable during the access, completion with `PREADY` | AMBA APB4 | 17,188 accesses | 0 |
| APB: exactly **3 wait states** per access (reads and writes) | `docs/architecture.md` §6.2 | 17,188 accesses | 0 |
| Trigger input: `ack` rises only after `req`, falls only after `req` fell; `ack_type` never reserved | TRM 4.4, Table 5-5 | about 1.0 M port-cycles | 0 |
| Trigger output: `req` stays high until `ack` | TRM 4.4.4 | about 1.0 M port-cycles | 0 |
| Stream out: `TVALID` held with stable payload until `TREADY` | AMBA AXI-Stream | 937 beats | 0 |
| Stream out: **`TSTRB` all ones except on the `TLAST` beat** | TRM 4.5 | 937 beats | 0 |
| `ch_err` rises in the same cycle as `ch_enabled` falls (`STAT_ERR` set on return to disabled) | TRM 5.6.3 | 19 errors | 0 |
| Q-Channel: every request is answered by accept **xor** deny | AMBA LPI | 3 requests | 0 |

Informational timing measured on all plain commands (no link, trigger or stop):

| Quantity | Result |
|---|---|
| `ch_enabled` ↑ → first `AR`, 1D | **9 cycles** in 261 of 265 commands (outliers: 23 and 29 cycles under memory back-pressure) |
| `ch_enabled` ↑ → first `AR`, 2D | **17 cycles** in 65 of 65 commands |
| last `B` → `ch_enabled` ↓ | **6 cycles** in 355 of 358 commands |

These agree with the numbers in [`docs/perf_report.md`](../perf_report.md) (9 / 17 / 6) and with the figures.

*Limits of the checker:* it observes the pins only. The in-flight byte check slightly over-counts the unaligned
first beat, so it is conservative; the `VALID`-held rules only see stalls in tests that use back-pressure (the
control, low-power and arbitration tests).

## 11.4 Cross-reference: specification ↔ RTL ↔ waveform

| # | Specification statement | TRM | RTL | Evidence | Status |
|---|---|---|---|---|---|
| 1 | The channel life cycle is Config check → Trigger allocation → Set GPO → Command trigger → Data transfer → Trigger-OUT → Done, with Stop / error on the side | Fig. 5-22, 5.6.1 | `st_e` in `dma_channel.sv` (`S_CFG`, `S_CHK`, `S_ALLOC`, `S_GPO`, `S_CMDTRIG`, `S_XFER`, `S_TRIGOUT`, `S_DONE`, `S_STOP`, `S_FIN`) | `copy_1d`, `start_latency`, `err_*` | consistent |
| 2 | `ch_enabled` is high from `ENABLECMD` until the command / chain ends | 5.6, 4.8.4 | `enabled` flop | every figure | consistent |
| 3 | Unoptimized access uses `TRANSIZE` as `AxSIZE`; for 13 bytes from `0x…3` there are 13 one-byte beats | 4.3.6, 4.3.7, Fig. 4-1 | `i_opt` = `MEMATTR[7:4]` ≠ 0 in `dma_ch_agen.sv` | `unopt_unaligned`: `ARLEN` 12, `ARSIZE` 0, strobes `08 10 20 40 80 01 …` (one byte per beat, utilization 1/8) | consistent with the TRM text |
| 4 | Optimized access uses full-width beats and the unaligned address | 4.3.6, 4.3.7, Fig. 4-2 | `dma_ch_agen.sv` (`mb_w`, `n_size = LB`) | `opt_unaligned`: `AR 0x101003` `ARLEN` 1 `ARSIZE` 3; `WSTRB` `f8`, `ff` (first beat utilization (8 − 3) / 8) | consistent with the TRM text |
| 5 | Unaligned end: reads use a 16-bit then an 8-bit beat; the write is one 3/8-utilization beat | 4.3.8, Figs. 4-4, 4-5 | read-side rule "largest power of two that fits" | `opt_unaligned_end`: `AR` `ARSIZE` 1 then 0; `WSTRB` `07` (utilization 3/8) | consistent with the TRM text |
| 6 | Bursts never cross a 1 KB boundary | 4.3.6 | `to1k` in `dma_ch_agen.sv` | `burst_1kb`; checker: 44,333 bursts | consistent |
| 7 | Burst length ≤ `MAXBURSTLEN` + 1 beats | 6.5.1.11 (field text; 4.3.6 words it loosely) | `i_maxbeats` = field + 1 | `burst_maxlen`: field 3 → 4 beats, field 1 → 2 beats | consistent with the register description |
| 8 | Burst length is limited to FIFO/2 | 4.3.6 | `HALF_BYTES` | `burst_fifo2`: channel 3 bursts of 2 beats | consistent |
| 9 | A read is issued only when the FIFO has room for the complete response | 4.3.4, 5.8.1 | `push_rd_data`: `free_a >= ra_nb` | `burst_fifo2` (second `AR` pair waits); checker: 22,217 bursts | consistent |
| 10 | A write is issued only when the FIFO holds the full burst | 4.3.4, 5.8.1 | `push_wr`: `wsrc_avail >= wa_nb` | `AW` 6 cycles after the last `R` in every copy figure | consistent |
| 11 | `W` data never overtakes `AW` | 4.3.3 | W-order queue pushed at the `AW` handshake (`dma_biu.sv`) | checker: 74,091 beats | consistent |
| 12 | `AxID` identifies the channel; link reads use the channel ID too | 4.3.2, 5.7.2 | `ar_gi` / `aw_gi` as ID in `dma_biu.sv` | checker: 44,263 transfers; `cmd_link` | consistent |
| 13 | Only `FIXED` and `INCR` bursts; increment 0 gives `FIXED` | 4.3.1 | `M_FIXED` mode in `dma_ch_agen.sv` | `cmd_link` (16-beat `FIXED` read and write); checker | consistent |
| 14 | 2D copy of Fig. 5-5 (X size 9, Y size 8, stride 0x18) | 5.3.1 | `S_MUL`, line logic | `copy_2d`: 16 `AR`, 8 `AW` at stride 24, 16 `W` beats | consistent |
| 15 | WRAP re-reads the source (`DESXSIZE` reads and writes); FILL reads `SRCXSIZE` and writes `DESXSIZE` with `FILLVAL` | 5.2.2 | `c_modelb`, `c_xwrap`, `c_xfill`, `c_fillpat` | `wrap_1d`: 17 bytes read as 5+5+5+2; `fill_1d`: 5 bytes read, 12 fill bytes `0x17` written | consistent |
| 16 | Command-link header bits, `REGCLEAR`, `HEADER_0` = `0x0D5D`, descriptor in header order | 5.7.1, Tables 5-12 – 5-15 | `dma_ch_link.sv` (`HDR_RSVD` = bits 1, 23, 25, 27) | `cmd_link`, `cmd_link_chain` | consistent |
| 17 | Link reads: `ARPROT[2]` = 1, `ARCMDLINK` = 1, size = `DATA_WIDTH` | 4.3.9, 5.7.2 | `dma_channel.sv` `arq_din` for the link | checker: 16 link reads | consistent |
| 18 | Address registers hold the next address after a command, so a header without `SRCADDR` continues the source | 5.6.4 | `zero_src`, hardware address update | `cmd_link_chain`: second `AR` at `0x101218` = `0x101200` + 24 | consistent |
| 19 | Auto-restart count; `REGRELOADTYPE` = 7 reloads addresses and sizes; `DONETYPE` = 1 gives one `STAT_DONE` at the end | 5.6.2, `CH_CTRL` | `S_DONE` (`dn_rst`, `dn_sdone`) | `auto_restart`: 4 identical executions, one interrupt | consistent |
| 20 | `DONEPAUSEEN` pauses after `STAT_DONE` until `RESUMECMD` | 5.6.1, `CH_CTRL` | `donepause` | `done_pause` | consistent |
| 21 | Autoboot starts after reset and after both LPI channels are active, as an empty command linking to `boot_addr`, before any APB access | 5.7.3, 5.10 | `boot_start = lpi_active && !boot_done_q && boot_en` (`dma_top.sv`) | `autoboot`: `ch_enabled` 6 cycles after reset release; no APB | consistent |
| 22 | Trigger request / acknowledge encodings | Tables 5-4, 5-5 | `REQ_*`, `ACK_*` in `dma_pkg.sv` | figures `trig_*`; checker (reserved ack never used) | consistent |
| 23 | Command trigger: ack when the request arrives, ack released after `req` falls; the transfer then runs | 5.4.1.1, Fig. 5-16 | `dma_ch_trigin` `T_GOT` → `T_ACKH` | `trig_cmd_hw` | consistent |
| 24 | Flow control: ack only after the block's last response; `LAST OKAY` on the final block | 5.4.1.2, Table 5-5 | `T_XFER`: `side_idle`, `ACK_LAST_OKAY` | `trig_flowctrl`, `trig_sw` | consistent |
| 25 | Trigger output: the command is not complete until the peripheral acknowledges | 4.4.4, 5.4.2 | `dma_ch_trigout` `O_REQ` → `O_LOW` → `O_DONE` | `trig_out` | consistent |
| 26 | Internal trigger connects a channel's trigger output to another channel; sender waits for the ack | 5.4.4 | trigger matrix, `T_GOT` | `trig_internal` | consistent |
| 27 | Software triggers through `CH_CMD`, accepted while `STAT_*TRIGINWAIT` is set | 5.4.5 | `sw_src_req`, `sw_src_type` | `trig_sw` | consistent |
| 28 | `TSTRB` is all ones except on the `TLAST` beat; a stream-in packet ends the command | 4.5, 5.5 | `si_bad`, `seng_tlast` | `stream_out`, `stream_in`; checker: 937 beats | consistent |
| 29 | `STAT_ERR` is set when the channel returns to disabled; outstanding transactions complete; no bus access on a configuration error | 5.6.3 | `S_STOP` → `S_FIN`, `set_err`, `chk_regval` | `err_read`, `err_write`, `err_cfg`; checker | consistent |
| 30 | `CH_ERRINFO` bits for read / write response errors and `REGVALERR` | Tables 5-8, 5-9 | `e_now` in `dma_channel.sv` | `0x10001`, `0x20001`, `0x02000002` read back | consistent |
| 31 | Pause: execution stalls, status reported when quiet, channel stays enabled; resume continues | 5.6 | `stat_paused = enabled && pause_req && quiet` | `pause_resume`, `done_pause` | consistent |
| 32 | Stop waits for outstanding responses, no new requests; ends with `STAT_STOPPED` | 4.8.2, 5.6 | `S_STOP` waits for `quiet` | `stop`, `allch_stop_hw` | consistent |
| 33 | All-channel pause / stop use 4-phase handshakes; the ack means "all paused / stopped or inactive" | 4.8.2 | `dma_unit.sv` | `allch_pause_hw`, `allch_stop_hw` | consistent |
| 34 | CTI: `halted` pulses after all channels paused; `restart_req` resumes; `DBGHALTEN` gates it | 4.8.3, 5.9.3, `SEC_CTRL` | `dma_unit.sv` (`H_RUN`, `H_HALTED`, `dbghalten`) | `cti_halt` | consistent |
| 35 | Q-Channel accepts when idle or waiting, denies when active | 5.9.1.2 | `dma_lpi.sv` Q state machine | `lpi_q`; checker | consistent |
| 36 | P-Channel: OFF denied while active, WARM_RST pauses all channels, ON resumes | 5.9.1.1 | `dma_lpi.sv` P state machine | `lpi_p` | consistent |
| 37 | Arbitration: highest priority wins, LRG among equals, per burst | 5.8.2, Fig. 5-24 | `dma_lrg_arb.sv` | `multi_ch_arb`; equal-priority fairness 48 / 52 % in `perf_report.md` | consistent |
| 38 | GPO value applied when the command starts and held afterwards | 4.8.1 | `S_GPO`, `gpo_q` | `gpo`: `0x00` → `0x62`, still `0x62` after the command | consistent |
| 39 | Interrupts are levels from `STAT_*` and `CH_INTREN`; cleared by writing 1 to the status | 4.7, 5.11, `CH_STATUS` | `dma_ch_regs.sv` | `apb_read` | consistent |
| 40 | APB: 32-bit accesses, registered response | 4.2 | `dma_apb_if.sv` | `apb_write`, `apb_read`; 3 wait states | consistent (wait states are an implementation choice) |

## 11.5 Remarks

* **Implementation-defined values.** The TRM does not specify wait states or pipeline latency. This implementation has
  3 APB wait states, a 9-cycle start latency (17 for 2D) and a 6-cycle completion; the figures show those values.
* **`MAXBURSTLEN` wording.** TRM 4.3.6 says a burst "must be shorter than" the value, but the register description of
  `SRCMAXBURSTLEN` / `DESMAXBURSTLEN` says the maximum is *value + 1* beats. The design follows the register description
  and the simulation matches it (`burst_maxlen`).
* **Interrupt of an empty command in a link chain.** The empty first command of a chain sets `STAT_DONE` (and the
  interrupt, if enabled) when it finishes, before the descriptor is fetched (`cmd_link`, `autoboot`). That follows from
  `DONETYPE` = 1 ("end of a command, before jumping to the next linked command").
* **Corrections made while reviewing.** Early drafts of this folder contained mistakes of the *documentation and tools*, not
  of the design, all found by this review: the Q-Channel was described as denying while a channel waits for a trigger (RTL and TRM
  accept in that case), the checker modelled FIXED-burst strobes and the byte count of an unaligned first beat wrongly,
  the waveform tool treated a multi-channel stream vector with unknown bits in the unused channels as completely
  unknown (so `tlast` and `tstrb` of channel 0 were first drawn as unknown), and a few cycle numbers were shifted. None of these was a design bug.
* **Not drawn.** Templated transfers (5.3.3), 2D wrap and the mirror / rotate examples (5.3.2, Fig. 5-7), peripheral-driven
  flow control, software all-channel pause / stop, security violations, the second AXI port `M1`, `FULL_RET` power
  state, stream flush and stream errors. They are exercised by other test cases of the sign-off regression
  ([`docs/verification.md`](../verification.md) §4) but have no waveform here.

## 11.6 Re-running the checks

```
python docs/waveform/tools/wave_build.py      --work <scratch>
python docs/waveform/tools/gen_all.py         --work <scratch>              # also simulates the 17 tests behind the figures
python docs/waveform/tools/check_protocols.py --work <scratch>              # protocol and spec rules, exit code 0 = clean
```

`dma_stream_test` and `dma_perf_arb_test` are two extra simulations used only for the checks (they have no figure of
their own); start them with `tools/wave_sim.py -o <scratch>/vcd/<test>.vcd` before running the checker. The pass table
also contains a full-length run of `dma_dir_1d_test` (the figure VCD stops after 400 µs).
