# Documentation index

The documents answer different questions. Pick the path that matches what you want to do.

## I want to understand how the design works

Read the **waveform guide** first. It follows every operation from the first APB register write to the interrupt, with
a simulation waveform for each step, and is written to be read without prior knowledge of the DMA-350.

| # | Chapter | Topic |
|---|---|---|
| – | [Waveform guide: README](waveform/README.md) | how to read the figures, simulation setup, how to regenerate them |
| 1 | [Design overview](waveform/01_design_overview.md) | what the DMA does, block diagram, channel life cycle, FIFO issue rules, timing constants, register model |
| 2 | [Register access and command start](waveform/02_register_access_and_start.md) | APB write / read, 9-cycle start latency |
| 3 | [Data transfers](waveform/03_data_transfers.md) | 1D copy, byte lanes, unoptimized / optimized accesses, 1 KB split, `MAXBURSTLEN`, FIFO/2 |
| 4 | [2D, WRAP and FILL](waveform/04_2d_wrap_fill.md) | rectangles, repeating the source, padding the destination |
| 5 | [Command linking, restart, autoboot](waveform/05_command_linking_restart_autoboot.md) | descriptors in memory, auto-restart, done-pause, boot after reset |
| 6 | [Triggers](waveform/06_triggers.md) | command trigger, flow control, software, output and internal triggers |
| 7 | [AXI-Stream](waveform/07_axi_stream.md) | stream out, stream in, in & out through an external engine |
| 8 | [Channel control](waveform/08_channel_control.md) | pause, resume, stop, all-channel control, CTI halt |
| 9 | [Error handling](waveform/09_error_handling.md) | bus, configuration, trigger and stream errors |
| 10 | [Arbitration, GPO, low power](waveform/10_arbitration_gpo_low_power.md) | priority + LRG arbiter, GPO, Q-Channel and P-Channel |

Then read the [architecture document](architecture.md) for the micro-architecture of every block (address generator,
FIFO, BIU, timing and SRAM notes).

## I want to know whether the design is correct

| Document | Content |
|---|---|
| [Consistency report](waveform/11_consistency_report.md) | the waveforms, the TRM, the RTL and the simulation cross-checked point by point; 395 automatic protocol checks, 0 violations |
| [Verification plan and report](verification.md) | test bench, test plan (feature → test), regressions, functional and code coverage, exclusions |
| [Bug list](bug_list.md) | the 15 RTL bugs found by verification, each with the test that detects it |

## I want to know how fast it is, or integrate it

| Document | Content |
|---|---|
| [Performance report](perf_report.md) | measured throughput versus burst length, FIFO size, memory latency, back-pressure and priority |
| [Performance tables](perf_results.md) | the generated tables behind the report (3 bus widths) |
| [Architecture](architecture.md) | parameters, builds, SRAM macro hook (`dma_sram_2p`), timing structure |
| [Clock domain crossings](cdc.md) | asynchronous inputs, synchronizers, reset, constraints for CDC tools |

## Reading order in one line

`waveform/01` → `waveform/02 … 10` (by interest) → `architecture` → `waveform/11` → `verification` → `perf_report`.
