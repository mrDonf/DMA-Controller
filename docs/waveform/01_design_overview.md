# 1. Design overview

This chapter gives the vocabulary used by all other chapters: what the DMA is, how it is built, how a command
moves through a channel, and which timing numbers you will meet in the waveforms. Every statement here is
backed by the RTL (`rtl/`) and by the Arm DMA-350 TRM; the evidence is collected in
[Chapter 11](11_consistency_report.md).

## 1.1 What the DMA does

A DMA (direct memory access) controller copies data **without the CPU touching every byte**. The CPU describes
*what* to move in a few registers (a **command**) and starts it; the DMA then reads the source with AXI read
bursts, buffers the data, writes it to the destination with AXI write bursts, and finally raises an interrupt.

This design implements the DMA-350 programmers model:

| Feature | Where it is explained |
|---|---|
| 1D block copy with any start alignment and transfer size (1 to 16 bytes) | [Chapter 3](03_data_transfers.md) |
| 2D copy (rows with a stride), WRAP and FILL | [Chapter 4](04_2d_wrap_fill.md) |
| Command linking (descriptors in memory), automatic restart, autoboot | [Chapter 5](05_command_linking_restart_autoboot.md) |
| Hardware / software / internal triggers, flow control, trigger output | [Chapter 6](06_triggers.md) |
| AXI-Stream in / out to an external data engine | [Chapter 7](07_axi_stream.md) |
| Pause, resume, stop, all-channel and CTI control | [Chapter 8](08_channel_control.md) |
| Error detection and reporting | [Chapter 9](09_error_handling.md) |
| Multi-channel arbitration, GPO, clock / power Q- and P-Channel | [Chapter 10](10_arbitration_gpo_low_power.md) |

## 1.2 Block diagram

```
                       +-----------------------------------------------------------------------+
   APB4  ------------->| dma_apb_if --> dma_unit  (unit frames, security, all-channel control,  |
   (CPU programming)   |                          CTI, unit interrupts)                         |
                       |      register bus (one access per cycle)                               |
                       |          |               |                |                            |
                       |     +----v----+     +----v----+      +----v----+                       |
  trigger in/out <---->|     |channel 0|     |channel 1| ...  |channel N|   dma_trig_mtx        |
  (4-phase req / ack)  |     +----+----+     +----+----+      +----+----+   (trigger ports <->   |
                       |          |  AR / AW requests (2-entry queues), W beats, R / B           |
  AXI-Stream <-------->|          v                                         channels)           |
                       |   dma_biu : per port and direction a priority + LRG arbiter,            |
                       |             W-order queue, ID routing, register slices                  |
                       +--------------------------|----------------------|----------------------+
                                                  v                      v
                                            AXI5 manager M0        AXI5 manager M1 (optional)
   dma_lpi : Q-Channel (clock) and P-Channel (power) handshakes        dma_reset_sync : reset
```

| Block (RTL) | Role |
|---|---|
| `dma_apb_if.sv` | APB4 front end. Captures an access, executes it one cycle later and answers with a registered `PREADY`. |
| `dma_unit.sv` | Unit level: security / privilege frames, all-channel stop / pause, CTI halt, combined interrupts. |
| `ch/dma_channel.sv` | One DMA channel: command state machine, checks, read / write issue rules, stream, GPO. Contains the blocks below. |
| `ch/dma_ch_regs.sv` | The channel register frame (`CH_CMD`, `CH_STATUS`, `CH_CTRL`, ...). |
| `ch/dma_ch_agen.sv` | Address / burst generator, one for the read side and one for the write side. |
| `ch/dma_ch_fifo.sv` | Byte-granular data FIFO (two SRAM banks) between read and write sides. |
| `ch/dma_ch_rdp.sv`, `ch/dma_ch_rdeng.sv` | Read data path (R beats → FIFO) and FIFO consumer (FIFO → W beats or stream beats). |
| `ch/dma_ch_link.sv` | Command-link unit: fetches and decodes descriptors. |
| `ch/dma_ch_trig.sv`, `dma_trig_mtx.sv` | Channel-side trigger state machines and the trigger matrix (port allocation, synchronizers). |
| `dma_biu.sv`, `common/dma_lrg_arb.sv`, `common/dma_reg_slice.sv` | Bus interface unit: arbitration, W ordering, register slices to the AXI pins. |
| `dma_lpi.sv` | Q-Channel (clock) and P-Channel (power) controllers. |

## 1.3 Inside a channel: the data path

Reads and writes are **decoupled by a FIFO**. The read side never waits for the write side except through
free space, and the write side never waits for the read side except through available data.

```
 CPU --APB--> [CH registers] --CFG--> [read agen]  --AR queue(2)--+
                  |  (snapshot)                                    +--> BIU --> AXI AR
                  |                   [write agen] --AW queue(2)--+
                  |                                                      AXI R  --> dma_ch_rdp
                  |                                                                   |  (lane, byte count)
                  |                          free_a (bytes) <---------------+         v
                  |                                                   [ data FIFO  (byte granular) ]
                  |                          avail_a (bytes) ---------------+         |
                  |                                                                   v
                  |                                                         dma_ch_rdeng --> W beats --> BIU --> AXI W
                  +--> [command link unit] <-- R beats of descriptor reads             \--> AXI-Stream beats (stream out)
```

The FIFO issue rules are the heart of the design (TRM 4.3.4 and 5.8.1; RTL `push_rd_data` and `push_wr` in
`dma_channel.sv`):

| Rule | Consequence you can see in the waveforms |
|---|---|
| A **read burst** is issued only when the FIFO has **room for the whole response** (space is reserved at `AR` issue). | `R` data is always accepted (`RREADY` is constant 1 inside the DMA). With a small FIFO the next `AR` waits (figure `burst_fifo2`). |
| A **write burst** is issued only when the FIFO already holds **all data of that burst**. | `AW` appears several cycles after the last `R` beat, and `W` beats are never stalled by the DMA. No circular dependency between read and write. |
| `W` data is sent at the same time as or after its `AW`. | `W` never leads `AW` (checked on every simulation, [Chapter 11](11_consistency_report.md)). |
| Burst boundaries: line end, wrap point, data / fill boundary, trigger block, `MAXBURSTLEN`, **FIFO/2**, **1 KB**. | Every burst split in Chapters 3 and 4. |
| `AxID` = channel number, `AxQOS` = `CH_CTRL.CHPRIO`. | Used by the arbiter and to route `R` / `B` back to the right channel ([Chapter 10](10_arbitration_gpo_low_power.md)). |

## 1.4 Command life cycle

A **command** is the set of channel registers programmed by the CPU (or loaded from memory by command linking).
Its life cycle in the RTL (`st` in `dma_channel.sv`) matches TRM Fig. 5-22:

```
                      ENABLECMD
   IDLE ----------------------------> CFG -> CHK -> (MUL) -> ALLOC -> (ALLOCW) -> GPO -> CTRIG -> XFER -> TOUT -> DONE
    ^                                  ^                                                                  |
    |                                  |       auto-restart (CMDRESTARTCNT / INF)                         |
    |                                  +------------------------------------------------------------------+
    |        command link (LINKADDREN):  DONE -> LINK -> CFG ...
    |
    +--- FIN <--- STOP <--- (any error, STOPCMD, all-channel stop)  [wait for outstanding responses]
```

| State | What happens | Typical duration in the figures |
|---|---|---|
| `CFG` | The register values are copied into the channel's working copy. | 1 cycle |
| `CHK` | `REGVALERR` / `CFGCONFLERR` checks. A bad value goes to `STOP` without any bus access ([Chapter 9](09_error_handling.md)). | 1 cycle |
| `MUL` | 2D only: elements = X size × Y size computed by an iterative multiplier (keeps the critical path short). | 8 cycles |
| `ALLOC`, `ALLOCW` | Only with HW / internal triggers: the trigger matrix connects the selected ports. | 1 cycle (+ about 3 for `ALLOCW`) |
| `GPO` | Apply `GPOEN0` / `GPOVAL0` if `USEGPO`. | 1 cycle |
| `CTRIG` | Wait for **command-mode** triggers; 1 cycle if none are used. | 1 cycle or as long as the peripheral takes |
| `XFER` | The data transfer. Ends when both sides and the FIFO are drained and all flow-control blocks are done. | the whole transfer |
| `TOUT` | Wait for the trigger-output 4-phase handshake. | 2 cycles if no trigger output |
| `DONE` | `STAT_DONE` per `DONETYPE`, then restart / link / idle. | 1 cycle |
| `STOP` → `FIN` | Error, `STOPCMD` or all-channel stop: no new bursts, wait for all outstanding responses. | until the bus is quiet |

`ch_enabled[n]` is high from the `ENABLECMD` write until the command (or whole command chain) ends. Once enabled,
the configuration registers become read-only; only `CH_CMD`, `CH_STATUS` and `CH_WRKREGPTR` can be written
(TRM 5.6).

## 1.5 The programming model in one page

Registers of channel *n* start at **`0x1000 + 0x100 * n`** (TRM 6.3). The ones used in the waveforms:

| Offset | Register | Key fields |
|---|---|---|
| `0x00` | `CH_CMD` | `[0]` ENABLECMD, `[1]` CLEARCMD, `[2]` DISABLECMD, `[3]` STOPCMD, `[4]` PAUSECMD, `[5]` RESUMECMD, `[16]` SRCSWTRIGINREQ, `[18:17]` its type, `[20]` DESSWTRIGINREQ, `[22:21]` its type, `[24]` SWTRIGOUTACK |
| `0x04` | `CH_STATUS` | `[16]` STAT_DONE, `[17]` STAT_ERR, `[18]` STAT_DISABLED, `[19]` STAT_STOPPED, `[20]` STAT_PAUSED, `[21]` STAT_RESUMEWAIT, `[24]` STAT_SRCTRIGINWAIT, `[25]` STAT_DESTRIGINWAIT, `[26]` STAT_TRIGOUTACKWAIT; `[3:0]` INTR_DONE / ERR / DISABLED / STOPPED (write 1 to a STAT bit to clear it) |
| `0x08` | `CH_INTREN` | interrupt enables, same bit positions as the `INTR_` bits |
| `0x0C` | `CH_CTRL` | `[2:0]` TRANSIZE (size in bytes = 2^TRANSIZE), `[7:4]` CHPRIO, `[11:9]` XTYPE, `[14:12]` YTYPE, `[20:18]` REGRELOADTYPE, `[23:21]` DONETYPE, `[24]` DONEPAUSEEN, `[25]` USESRCTRIGIN, `[26]` USEDESTRIGIN, `[27]` USETRIGOUT, `[28]` USEGPO, `[29]` USESTREAM |
| `0x10` / `0x18` | `CH_SRCADDR` / `CH_DESADDR` | start addresses (low bits below TRANSIZE are ignored) |
| `0x20` | `CH_XSIZE` | `[15:0]` SRCXSIZE, `[31:16]` DESXSIZE (number of elements) |
| `0x28` / `0x2C` | `CH_SRCTRANSCFG` / `CH_DESTRANSCFG` | `[7:0]` MEMATTR (device / normal), `[10]` non-secure, `[19:16]` MAXBURSTLEN (beats = value + 1) |
| `0x30` | `CH_XADDRINC` | `[15:0]` source, `[31:16]` destination increment (in elements; 0 = FIXED burst) |
| `0x34`, `0x3C` | `CH_YADDRSTRIDE`, `CH_YSIZE` | 2D line stride and number of lines |
| `0x38` | `CH_FILLVAL` | fill pattern |
| `0x4C`, `0x50`, `0x54` | `CH_SRCTRIGINCFG`, `CH_DESTRIGINCFG`, `CH_TRIGOUTCFG` | trigger select / type / mode / block size |
| `0x58`, `0x60` | `CH_GPOEN0`, `CH_GPOVAL0` | GPO enable mask and value |
| `0x68` | `CH_STREAMINTCFG` | `[10:9]` stream type |
| `0x74`, `0x78` | `CH_AUTOCFG`, `CH_LINKADDR` | auto-restart count / infinite; link address and `[0]` LINKADDREN |
| `0x90` | `CH_ERRINFO` | error cause bits |

The CPU flow is always the same:

```
 write the registers of the command   (CH_CTRL, CH_SRCADDR, CH_DESADDR, CH_XSIZE, ...)
 write CH_CMD = ENABLECMD             -> channel starts, registers become read-only
 wait for the interrupt (irq_channel) or poll CH_STATUS
 read CH_STATUS / CH_ERRINFO; write 1 to the STAT bits to clear them
```

## 1.6 Timing constants you will see in the figures

All numbers are measured on the RTL (zero-latency memory, `pclken` = `aclken` = 1). The "Measured" column
comes from `tools/check_protocols.py` over all simulations of this folder; `docs/perf_report.md` gives the same
numbers.

| Quantity | Value | Measured | Why |
|---|---|---|---|
| APB access | 5 cycles = 1 setup + 4 access (**3 wait states**) | 100 % of all accesses | the access is captured, executed one cycle later and answered by a registered `PREADY` (`dma_apb_if.sv`) |
| `ch_enabled` ↑ → first `AR` (1D) | **9 cycles** | 261 of 265 commands | registered pipeline `CFG, CHK, ALLOC, GPO, CTRIG, XFER`, address generator, AR queue, BIU register slice |
| `ch_enabled` ↑ → first `AR` (2D) | **17 cycles** | 65 of 65 commands | `MUL` adds 8 cycles |
| `AR` → first `R` | 1 cycle | – | zero-latency test memory |
| last `R` → `AW` | about 6 cycles | – | data goes through the FIFO write pipeline (3 stages) before it counts as *available* |
| `AW` → first `W` | about 4 cycles | – | `W` order queue and register slice in the BIU |
| last `B` → `ch_enabled` ↓ | **6 cycles** | 355 of 358 commands | `TOUT`, `DONE`, `IDLE` |
| `ch_enabled` ↓ → `irq_channel` ↑ | 1 cycle | – | interrupt flag register |

The few measured outliers (23 and 29 cycles for `AR`, 7 and 8 for the end) are commands that ran with the slow
memory profile of the test (`ARREADY` / `RVALID` back-pressure).

## 1.7 Where the AXI attributes come from

| AXI signal | Value | Source |
|---|---|---|
| `ARID`, `AWID` | channel number | TRM 4.3.2 (also used for command-link reads) |
| `ARQOS`, `AWQOS` | `CH_CTRL.CHPRIO` | TRM 5.8 |
| `ARBURST`, `AWBURST` | `FIXED` if the increment is 0, otherwise `INCR` (never `WRAP`) | TRM 4.3.1 |
| `ARSIZE`, `AWSIZE` | `TRANSIZE`, or the bus width when the access is *optimized* (see [Chapter 3](03_data_transfers.md)) | TRM 4.3.6 |
| `ARLEN`, `AWLEN` | beats − 1, limited by `MAXBURSTLEN` + 1, FIFO/2 and the 1 KB boundary | TRM 4.3.6, `CH_SRCTRANSCFG` |
| `ARPROT[2]` | 1 only for command-link reads (instruction access), together with `ARCMDLINK` = 1 | TRM 4.3.9, 5.7.2 |
| `ARCACHE`, `ARDOMAIN`, ... | from `MEMATTR` / `SHAREATTR` of the transfer configuration | TRM 4.3.9 |
