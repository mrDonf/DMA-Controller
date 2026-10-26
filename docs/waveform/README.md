# AXI DMA – Operations explained with waveforms

This folder explains **how the DMA controller works** by walking through its main operations
cycle by cycle. Every waveform was produced from a real RTL simulation of this repository, not drawn by
hand. Each operation is shown from the very beginning:

1. **configure** – which registers the CPU writes over APB,
2. **start** – the `ENABLECMD` write and the channel state machine,
3. **transaction** – how the AXI (or trigger, stream, ...) traffic flows,
4. **finish** – status, interrupt and how the CPU reads the result.

The DMA is a multi-channel AXI5 DMA that follows the programmers model and interfaces of the
Arm CoreLink DMA-350 (TRM 102482_0000_04, see [`references/README.md`](../../references/README.md)). It is a good idea to read
[Chapter 1](01_design_overview.md) first; the other chapters can be read in any order.

> **Click a figure to zoom.** The SVG files are wide on purpose (one column per clock cycle) so that every
> label stays readable. Open the SVG in a browser and zoom, or paste the matching
> [`wavejson/*.json`](wavejson) file into <https://wavedrom.com/editor.html>.

<p align="center"><a href="svg/copy_1d.svg"><img src="svg/copy_1d.svg" width="100%" alt="1D copy: APB programming, channel FSM, AXI read and write, interrupt"></a></p>

*A complete 1D copy (TRM Fig. 5-1): APB programming (left), `CH_CMD` enable, FSM states, `AR`→`R`→`AW`→`W`→`B`,
then the interrupt (right). Chapter 3 explains every part of it.*

## Chapters

| # | Chapter | Operations shown (figure names in `svg/`) |
|---|---|---|
| 1 | [Design overview](01_design_overview.md) | what the DMA is, block diagram, channel life cycle, data-path rules, timing constants |
| 2 | [Register access and command start](02_register_access_and_start.md) | APB write / read (`apb_write`, `apb_read`), start latency (`start_latency`) |
| 3 | [Data transfers](03_data_transfers.md) | 1D copy (`copy_1d`, `copy_1d_data`), unoptimized / optimized / unaligned-end accesses (`unopt_unaligned`, `opt_unaligned`, `opt_unaligned_end`), 1 KB split, `MAXBURSTLEN`, FIFO/2 (`burst_1kb`, `burst_maxlen`, `burst_fifo2`) |
| 4 | [2D, WRAP and FILL](04_2d_wrap_fill.md) | `copy_2d`, `wrap_1d`, `wrap_1d_data`, `fill_1d`, `fill_1d_data` |
| 5 | [Command linking, restart, autoboot](05_command_linking_restart_autoboot.md) | `cmd_link`, `cmd_link_chain`, `auto_restart`, `done_pause`, `autoboot` |
| 6 | [Triggers](06_triggers.md) | `trig_cmd_hw`, `trig_flowctrl`, `trig_sw`, `trig_out`, `trig_internal` |
| 7 | [AXI-Stream](07_axi_stream.md) | `stream_out`, `stream_in`, `stream_inout` |
| 8 | [Channel control: pause, stop, all-channel, CTI](08_channel_control.md) | `pause_resume`, `stop`, `allch_pause_hw`, `allch_stop_hw`, `cti_halt` |
| 9 | [Error handling](09_error_handling.md) | `err_read`, `err_write`, `err_cfg` |
| 10 | [Arbitration, GPO and low power](10_arbitration_gpo_low_power.md) | `multi_ch_arb`, `gpo`, `lpi_q`, `lpi_p` |
| 11 | [Consistency report](11_consistency_report.md) | how the waveforms were cross-checked against the TRM, the RTL and 395 automatic protocol checks |

Every figure is a link: `svg/<name>.svg` (picture) and `wavejson/<name>.json` (editable source).

## How to read the figures

| Item | Meaning |
|---|---|
| `clk` row | one column = one clock cycle. A signal drawn as changing at the left border of a column changed at that rising edge. |
| `cycle` row | cycle number counted from the first column of the figure. **All "cycle N" in the text refer to this row.** |
| `//` (gap) | a stretch of time that was cut out (idle waiting, or registers that do not matter for this operation). The `cycle` numbers jump by exactly the number of cycles that were removed. |
| Handshake | `VALID` and `READY` both high in one column = the transfer happens at the **right** border (next rising edge) of that column. |
| Hatched area | the bus value is meaningless (`VALID` = 0). Buses are drawn only while valid. |
| `PADDR` | shown as a register name: `CH<n>_<REG>`; channel *n* lives at `0x1000 + 0x100 * n`. |
| `FSM chN` | state of the channel state machine (`st` in `dma_channel.sv`, see the table below). |
| Arrows `a → g` | cause and effect of one copy: `CH_CMD` write → `AR` → `R` → `AW` → `W` → `B` → `irq_channel`. |
| `RRESP`, `BRESP` | `OKAY`, `EXOK` = EXOKAY, `SLVE` = SLVERR, `DECE` = DECERR. |

Channel state names used in the figures:

| Figure label | RTL state | Meaning |
|---|---|---|
| `IDLE` | `S_IDLE` | no command |
| `LINK` | `S_LINK` | fetching the next command descriptor |
| `CFG`, `CHK` | `S_CFG`, `S_CHK` | register snapshot, check of the register values |
| `MUL` | `S_MUL` | 2D only: sequential multiplier computes the number of elements (8 cycles) |
| `ALLOC`, `ALLOCW` | `S_ALLOC`, `S_ALLOCW` | trigger port allocation (`ALLOCW` = wait for the trigger matrix) |
| `GPO` | `S_GPO` | update general purpose outputs |
| `CTRIG` | `S_CMDTRIG` | wait for command-mode triggers |
| `XFER` | `S_XFER` | data transfer: read and write sides run independently through the FIFO |
| `TOUT` | `S_TRIGOUT` | wait for the trigger-output handshake |
| `DONE` | `S_DONE` | command finished: set `STAT_DONE`, decide restart / link / idle |
| `STOP`, `FIN` | `S_STOP`, `S_FIN` | stop or error: wait for outstanding transactions, then finish |

## Simulation setup used for all figures

* Build `default` of `scripts/run_sim.py`: 4 channels, 64-bit data bus, 32-bit addresses, per-channel FIFO of
  16 / 8 / 32 / 4 words (128 / 64 / 256 / 32 bytes), 4 trigger inputs and outputs, Secure extension, stream
  interface on channels 0 and 1, 8-bit GPO on channels 0–3, second AXI port `M1` present.
* Existing UVM test cases are used unchanged (seed 1). Every figure names its test case. The AXI subordinate
  is the AXI5 VIP with `READY` always 1 and zero read latency, so all latencies shown are DMA latencies
  (a real memory only adds its own latency). The figures that need slow memory (pause, stop, low power) say so.
* The clock is 100 MHz in the test bench (10 ns); the figures are in clock cycles, so the period does not matter.

## Reproduce the figures

You need QuestaSim 10.7c, Python 3 and `pip install wavedrom` (pure Python renderer, no Node.js).
The scripts **read** `rtl/`, `tb/` and `scripts/run_sim.py` and write everything else to a scratch directory:

```
python docs/waveform/tools/wave_build.py     --work <scratch>          # compile once into <scratch>
python docs/waveform/tools/gen_all.py        --work <scratch>          # simulate + write wavejson/ and svg/
python docs/waveform/tools/gen_all.py        --work <scratch> --only copy_1d --facts   # one figure + its handshake timeline
python docs/waveform/tools/check_protocols.py --work <scratch>         # protocol and spec checks on the same VCDs
```

The window of each figure is found from DUT events (for example "the third `CH_CMD` write, until `ch_enabled`
falls"), not from fixed times, so the figures stay correct when the RTL timing changes; the cycle numbers in the
text must then be re-checked with `--facts`.

| File | Role |
|---|---|
| `tools/wave_build.py` | compile the RTL and the UVM test bench into the scratch directory |
| `tools/wave_sim.py` | run one test case and dump a VCD of the DUT ports |
| `tools/vcdwave.py` | VCD reader and WaveJSON builder |
| `tools/gen_all.py` | list of all figures, window selection, SVG rendering |
| `tools/check_protocols.py` | AXI / APB / trigger / stream / Q-Channel / TRM rule checker |
| `protocol_check_results.txt` | output of the checker for the simulations behind these figures |
