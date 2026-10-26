# AXI DMA controller – architecture and micro-architecture

The controller implements the programmers model, the interfaces and the behaviour of the
Arm CoreLink DMA-350 (TRM, see [`references/README.md`](../references/README.md)). All register frames, field encodings,
interface signals and protocols follow the TRM. The internal micro-architecture is our own and is
described here.

Related documents: [cdc.md](cdc.md) (clock domain crossings), [verification.md](verification.md)
(test bench, test plan, coverage), [perf_report.md](perf_report.md) (performance analysis),
[bug_list.md](bug_list.md) (RTL bugs found and fixed).

## 1. Feature summary

| Feature | Implementation |
|---|---|
| Channels | 1–8 (`NUM_CHANNELS`), each with its own byte FIFO (`CH_FIFO_DEPTH[n]` words of `DATA_WIDTH`) |
| Bus | AXI5 manager M0, optional M1 (`AXI5_M1_PRESENT`), 32/64/128-bit data, 32–64-bit address |
| Programming | APB4 subordinate, 13-bit address, Secure / Non-secure / privileged frames, PDEBUG |
| Commands | 1D / 2D, XTYPE / YTYPE continue / wrap / fill, templates, fill value, unaligned addresses |
| Command linking | Header bitmap descriptors (REGCLEAR, any register subset), 1 KB-safe fetch, autoboot |
| Auto-restart | CMDRESTARTCNT / infinite, REGRELOADTYPE, DONETYPE, DONEPAUSEEN |
| Triggers | `NUM_TRIGGER_IN` / `NUM_TRIGGER_OUT` ports, SW / HW / internal, command and flow control (DMA / peripheral driven), trigger matrix with security |
| AXI-Stream | Optional per channel (`CH_STREAM_MASK`), in / out / in-out, flush |
| GPO | `GPO_WIDTH` bits per channel (`CH_GPO_MASK`) |
| Security | `SECEXT_PRESENT`: Secure / Non-secure channels, trigger ports, violation interrupt, RAZ/WI or PSLVERR |
| Control | All-channel stop / pause (SW and 4-phase HW), CTI halt / restart, per-channel status outputs |
| Low power | Q-Channel (clock) and P-Channel (ON / WARM_RST / FULL_RET / OFF) |
| Interrupts | Per channel `irq_channel`, combined Secure / Non-secure, security violation |

## 2. Top level

```
                      +------------------------------------------------------------------+
  APB4  ------------->| dma_apb_if --> dma_unit (frames, security, ctrl, CTI, IRQ) ------+ |
  pclken              |                    |  register access bus (1 per cycle)         | |
                      |                    v                                            | |
                      |   +-----------+ +-----------+        +-----------+              | |
  trig_in/out <------>|   | channel 0 | | channel 1 |  ...   | channel N |  <-- ctrl ---+ |
  (dma_trig_mtx)      |   +-----------+ +-----------+        +-----------+                |
                      |     |  AR/AW req (2-entry queues), W beats, R/B responses          |
  AXI-Stream <------->|     v                                                            |
                      |   dma_biu: per port / direction priority+LRG arbiter,            |
                      |            W order queue, ID routing, register slices (aclken)    |
                      +--------------------|------------------------|--------------------+
                                           v                        v
                                      AXI5 M0                  AXI5 M1 (optional)
  LPI Q/P <--> dma_lpi        reset --> dma_reset_sync
```

Hierarchy (`rtl/dma_rtl.f`):

| File | Module | Role |
|---|---|---|
| `dma_top.sv` | `dma_top` | Top level, parameters, port list of TRM chapter 3 |
| `dma_pkg.sv` | `dma_pkg` | Register offsets, encodings, helper functions |
| `dma_addr_map.sv` | `dma_addr_map_pkg` | **Implementer editable** address → M0/M1 routing function |
| `dma_apb_if.sv` | `dma_apb_if` | APB4 front end (pclken, registered response) |
| `dma_unit.sv` | `dma_unit` | Unit frames (SECCFG / SECCTRL / NSECCTRL / INFO), access protection, channel attributes, all-channel stop / pause, CTI, unit interrupts |
| `dma_trig_mtx.sv` | `dma_trig_mtx` | Trigger port allocation, routing, selection errors, handshake completion, input synchronizers |
| `dma_lpi.sv` | `dma_lpi` | Q-Channel and P-Channel controllers |
| `dma_biu.sv` | `dma_biu` | Bus interface unit (arbitration, routing, W ordering, register slices) |
| `ch/dma_channel.sv` | `dma_channel` | Channel controller (command FSM, checks, issue logic, stream, GPO) |
| `ch/dma_ch_regs.sv` | `dma_ch_regs` | Channel register frame (TRM 6.5.1) |
| `ch/dma_ch_agen.sv` | `dma_ch_agen` | Address / burst generator (one per side) |
| `ch/dma_ch_rdp.sv` | `dma_ch_rdp` | Read data path (R beats → FIFO writes / link words) |
| `ch/dma_ch_rdeng.sv` | `dma_ch_rdeng` | FIFO consumer (W beats, stream beats, skips) |
| `ch/dma_ch_fifo.sv` | `dma_ch_fifo` | Byte-granular circular data FIFO on two SRAM banks |
| `ch/dma_ch_link.sv` | `dma_ch_link` | Command link fetch and header decode |
| `ch/dma_ch_trig.sv` | `dma_ch_trigin`, `dma_ch_trigout` | Channel side trigger FSMs |
| `common/dma_sram_2p.sv` | `dma_sram_2p` | **Only storage primitive of the data FIFOs** (SRAM macro hook) |
| `common/dma_fifo_ff.sv` | `dma_fifo_ff` | Small flop FIFOs for control queues |
| `common/dma_reg_slice.sv` | `dma_rs_out`, `dma_rs_in` | Full-throughput register slices with clock enable |
| `common/dma_lrg_arb.sv` | `dma_lrg_arb` | Priority + least-recently-granted arbiter (TRM 5.8.2) |
| `common/dma_cdc_sync.sv` | `dma_cdc_sync` | Level synchronizer (single CDC cell of the design) |
| `common/dma_reset_sync.sv` | `dma_reset_sync` | Reset synchronizer (async assert, sync de-assert) |

`scripts/gen_flat_top.py` generates a configuration specific wrapper with the TRM per-index
port names (`trig_in_<TI>_req`, `str_out_<N>_tvalid`, `gpo_ch_<N>`, …); `dma_top` itself
uses packed vectors indexed by TI / N so that one RTL source serves every configuration.

## 3. Parameters

| Parameter | Default | Range | Meaning |
|---|---|---|---|
| `NUM_CHANNELS` | 2 | 1–8 | Number of channels |
| `ADDR_WIDTH` | 32 | 32–64 | AXI address width |
| `DATA_WIDTH` | 64 | 32, 64, 128 | AXI / stream data width |
| `CHID_WIDTH` | 0 | 0–16 | AxCHID width (0: no CHID ports) |
| `GPO_WIDTH` | 8 | 0–32 | GPO bits per channel |
| `CH_GPO_MASK`, `CH_STREAM_MASK`, `CH_EXT_FEAT_MASK` | FF / 00 / FF | 8-bit masks | Per channel GPO, stream and extended (2D, template, wrap / fill) support |
| `CH_FIFO_DEPTH[8]` | 16 | power of 2, ≥ 2 | FIFO depth in `DATA_WIDTH` words per channel |
| `NUM_TRIGGER_IN/OUT` | 4 | 0–32 | Trigger ports |
| `TRIG_IN/OUT_SYNC_EN_MASK` | all 1 | 32-bit | Synchronizer per trigger port (0 = synchronous peripheral) |
| `AXI5_M1_PRESENT` | 0 | 0/1 | Secondary manager port |
| `SECEXT_PRESENT` | 1 | 0/1 | Security extension |
| `MEM_IMPL` | 0 | 0/1 | FIFO storage: flops / SRAM macro (see 6.1) |
| `RESET_SYNC_BYPASS` | 0 | 0/1 | Bypass the internal reset synchronizer |
| `BIU_MAX_RD/WR` | 32 | ≥ 1 | Outstanding bursts per port and direction |

## 4. Channel

### 4.1 Command life cycle

```
IDLE -> (LINK) -> CFG -> CHK -> (MUL) -> ALLOC -> GPO -> CMDTRIG -> XFER -> TRIGOUT -> DONE
                                                                                  |
          {CFG (auto-restart) | LINK (next descriptor) | IDLE} <------------------+
any error / STOP -> STOP (quiesce: no new bursts, wait for all responses, flush stream-in) -> FIN -> IDLE
```

* **CFG / CHK**: register snapshot, REGVALERR / CFGCONFLERR checks (TRM 5.6.2), error → STOP
  without bus activity.
* **MUL**: 2D only, iterative multiplier for the total sizes (8 cycles, keeps the critical path
  short).
* **ALLOC**: trigger matrix allocation of the selected trigger ports / internal connections.
* **XFER**: the read and write generators run independently through the FIFO.
* Pause (PAUSECMD, all-channel pause, CTI halt, P-Channel WARM_RST) stops issuing new bursts at
  burst granularity; `STAT_PAUSED` is reported once all outstanding transactions completed.

### 4.2 Address / burst generator (`dma_ch_agen`)

One generator per side. A command is decomposed into **lines** that bursts never cross. Each
step produces one burst descriptor limited by: the line end, the source wrap point, the
data / fill boundary, the trigger block, MAXBURSTLEN, **FIFO/2** (TRM 4.3.6), the 1 KB boundary
and the bandwidth optimisation rules (wide beats on normal memory with unit increment).

Timing structure: registered state `S_cur`, registered descriptor `D`, registered next state
`S_nxt`. The step function is one combinational cloud from flops to flops; a popped descriptor
takes the fast path (`S_cur <= S_nxt`, `D <= step(S_nxt)`), so the generator delivers one
descriptor per cycle without a long chain through the state update.

### 4.3 Issue rules (TRM 4.3.4)

* A read burst is issued only when the FIFO has space for the complete response (space is
  reserved at AR issue), so R data is always accepted (RREADY is constant 1 towards the BIU).
* A write burst is issued only when the FIFO holds all of its data, so W beats are never
  stalled by the DMA.
* `CH_ISSUECAP` limits outstanding bursts per direction (default 8).
* AR and AW requests leave the channel through 2-entry registered queues.

### 4.4 Data FIFO (`dma_ch_fifo`)

Byte-granular circular buffer of `DEPTH` words, stored in **two banks** (even / odd words) of
`dma_sram_2p` (1 write port + 1 read port, byte enables, 1-cycle read latency):

* any write of ≤ one bus word touches at most one word per bank;
* any read window of one bus word needs at most one word per bank;

so a simple two-port macro is enough and there are no bank conflicts. The write side packs
bytes from any source lane (rotator), the read side extracts bytes to any destination lane
(funnel shifter). All macro inputs and the output are registered:

```
write : beat -> W0 reg -> rotate / byte enables -> W1 reg -> SRAM write
read  : req  -> R0 reg -> SRAM read             -> funnel  -> R2 reg -> W / stream beat
```

The consumer (`dma_ch_rdeng`) covers the 3-cycle read latency with credit-based output
queueing (1 beat per cycle sustained).

### 4.5 Command link unit (`dma_ch_link`)

Fetches the header (one beat), then the body with INCR bursts limited by 16 beats, the 1 KB
boundary and the free space of the 16-word command buffer; the decoder writes one register per
cycle in header order. Link reads use ARPROT[2] = 1 and ARCMDLINK = 1, the channel AXI ID and
the LINKATTR memory attributes. An aborted fetch (STOP / error) keeps its bus accounting and
drops late read data (BUG-08).

### 4.6 Triggers (`dma_ch_trig`, `dma_trig_mtx`)

* Channel side: one `dma_ch_trigin` per side (command mode, DMA driven flow control,
  peripheral driven flow control, SW requests) and one `dma_ch_trigout`.
* Matrix: allocation of external ports / internal connections with the selection error rules
  (busy, owned, simultaneous selection, security mismatch), routing, software deny of pending
  unselected requests, and **completion of interrupted 4-phase handshakes** after a STOP
  (the matrix keeps ACK / REQ until the peripheral finishes the handshake, TRM 5.4.1).

## 5. Bus interface unit (`dma_biu`)

* Per port and direction a **priority + LRG arbiter** (`dma_lrg_arb`): only requesters with the
  highest CHPRIO compete, LRG between equal priorities (TRM 5.8.2). Arbitration per burst.
* **AXI ID = channel number** for data and link reads, so responses of one channel return in
  order and no reorder buffer is needed. R / B are routed back by ID; channels always accept.
* **W ordering**: a per-port W order queue is pushed at the AW handshake with the channel number;
  W beats are taken from the channel at the head of the queue. A channel gets an AW grant only
  when the queue can take it, and W never precedes AW (TRM 4.3.3).
* **Register slices** on every AXI channel of every port (`dma_rs_out` / `dma_rs_in`), full
  throughput, all AXI outputs driven by flops; with `aclken_m*` the external side changes and
  samples only on enabled edges.
* Outstanding limits `BIU_MAX_RD/WR` per port.
* M0 / M1 selection per burst through `dma_addr_map_pkg::dma_port_sel()` (implementer
  editable, default: window `0x8000_0000–0xFFFF_FFFF` → M1). A channel keeps one port per
  direction while transactions are outstanding.

## 6. Implementation notes

### 6.1 SRAM macros

`dma_sram_2p` is the only storage of the data FIFOs. To use foundry macros:

1. set `MEM_IMPL = 1` and define `DMA_SRAM_MACRO`;
2. instantiate the macro in the `g_macro` branch of `common/dma_sram_2p.sv` (1W1R, byte write
   enable, registered read data, depth = `CH_FIFO_DEPTH/2` words per bank, width `DATA_WIDTH`);
3. read-during-write of the same address is never issued and the controllers do not rely on
   the read data being held, so any standard two-port register file / SRAM fits.

The command buffer (16 words) and the control queues stay in flops.

### 6.2 Timing

* All AXI, APB, trigger, stream, LPI and status outputs are driven from flops.
* APB accesses are captured, executed one cycle later from registered address / data, and
  answered with a registered PREADY / PRDATA / PSLVERR (3 wait states with `pclken` = 1).
* Register slices between the channels and the AXI pins; arbitration is a precedence matrix
  (log-depth, no ripple chain).
* The generators use the registered state / descriptor structure of 4.2; 2D totals use an
  iterative multiplier; the FIFO data path is registered around the SRAM.
* Measured costs of this pipelining are in [perf_report.md](perf_report.md) (start latency 9
  cycles, completion 6 cycles, FIFO loop latency about 12 cycles).

### 6.3 Clocks and resets

One clock `clk`; `aclken_m0/m1` and `pclken` are clock enables for slower AXI / APB sides
(TRM 4.1). Asynchronous inputs and their synchronizers are listed in [cdc.md](cdc.md).
`resetn` is asserted asynchronously and released through `dma_reset_sync` (bypass option for an
integrator who already provides a synchronous release).

## 7. Configuration of the verified builds

| Build (`run_sim.py -v`) | Channels | Data | Addr | FIFO depths (words) | Triggers in/out | M1 | Security | Notes |
|---|---|---|---|---|---|---|---|---|
| `default` | 4 | 64 | 32 | 16, 8, 32, 4 | 4 / 4 | yes | yes | stream on ch0/1, GPO ch0–3 |
| `d32` | 4 | 32 | 32 | 16, 8, 32, 2 | 4 / 4 | yes | yes | |
| `d128` | 4 | 128 | 32 | 16, 4, 64, 4 | 4 / 4 | yes | yes | |
| `a40` | 4 | 64 | 40 | 16, 8, 32, 4 | 4 / 4 | yes | yes | |
| `min` | 1 | 64 | 32 | 16 | 0 / 0 | no | no | no stream / GPO / CHID |
| `nosec` | 4 | 64 | 32 | 16, 8, 32, 4 | 4 / 4 | no | no | |
| `ch8` | 8 | 64 | 32 | 16, 8, 32, 4 ×2 | 8 / 6 | yes | yes | mixed feature masks |
| `nosync` | 4 | 64 | 32 | 16, 8, 32, 4 | 4 / 4 | yes | yes | trigger synchronizers off |
