# Performance verification and analysis

All numbers come from simulation of the RTL with the UVM test bench (`tests/perf`); every
measured command is also checked by the reference model and the scoreboard. The full tables
(717 rows, 3 bus widths) are in [perf_results.md](perf_results.md).

## 1. Method

| Item | Value |
|---|---|
| Tests | `dma_perf_size/tsize/align/burst/latency/multich/arb/cmd_test` (`tb/uvm/regress/regress_perf.txt`) |
| Builds | `default` (64-bit), `d32`, `d128` (see [architecture.md](architecture.md) §7) |
| Clock | 1 clock, `aclken` / `pclken` = 1, cycles below are ACLK cycles |
| Memory | AXI5 subordinate VIP; read first-beat latency `lat`, R beat gap, AR/AW/W READY probability, B latency (`dma_perf_base::mem_profile`) |
| Monitor | `dma_perf_mon` (passive, both ports): payload bytes (write strobes), bursts, latencies, outstanding |
| Metrics | `cyc` = ENABLE → channel idle; `bpc` = payload bytes / cycle; **`eff` = bpc / bus bytes** (a copy moves at most one bus word per cycle: 100% = R and W channels both full); `lat0` = ENABLE → first AR; `tail` = last B → idle |

Reproduce:

```
python scripts/run_sim.py regress -l tb/uvm/regress/regress_perf.txt --variants default,d32,d128 -j 12
python scripts/perf_report.py sim/regress/<stamp> -o docs/perf_results.md
```

The read latency sweep uses a small extension of the AXI5 VIP: `r_gap_sep / r_gap_min / r_gap_max`
in `axi5_agent_cfg` separate the gap between R beats from the first-beat latency (default off,
VIP behaviour unchanged).

## 2. Summary (64-bit build unless noted)

| Item | Result |
|---|---|
| Fixed command cost | **9 cycles** ENABLE → first AR (17 with 2D), **6 cycles** last B → idle / interrupt |
| Large copy, ideal memory, default burst (FIFO/2) | 76–80% (6.1–6.4 B/cycle) |
| Large copy, tuned MAXBURSTLEN (4 beats) | **94–97%** (ideal memory), 92% with 16-cycle read latency |
| Port utilisation with several channels active | **98–100%** of R and W channels (BIU and arbiter add no bubbles) |
| Dual port (M0 + M1) | 131% of one port's peak with two channels on separate ports |
| Write response latency 64 cycles | −3.6 points only (posted writes, 8 outstanding) |
| READY backpressure 75 / 50 / 25% | 72 / 47 / 24%: the DMA follows the bus, never the bottleneck |
| Command link vs APB programming (16 × 8 B commands) | **49 vs 162 cycles per command** |
| Priority | Strict CHPRIO order when requests wait at the arbiter (91% vs 9% share) |
| 128-bit build, 1 KB FIFO, 16-cycle latency | 98.6% (15.8 B/cycle) |

## 3. Results and analysis

### 3.1 Transfer size and fixed overhead

Aligned copy, channel 2 (FIFO 32 words), bus-width elements, MAXBURSTLEN = 16:

| Size (B) | 16 | 64 | 256 | 1 K | 4 K | 16 K | 64 K |
|---|---|---|---|---|---|---|---|
| eff, lat 0 (64-bit) | 6.7 | 18.6 | 42.7 | 65.6 | 75.9 | 78.9 | 79.7 |
| eff, lat 16 (64-bit) | 4.4 | 14.0 | 36.0 | 51.0 | 57.0 | 58.7 | 59.1 |
| eff, lat 0 (128-bit) | 3.6 | 11.4 | 27.1 | 59.8 | 85.6 | 96.0 | 99.0 |

A 16-byte command takes 30 cycles: 9 (start) + transfer + 6 (completion). Half of the
asymptotic rate is reached at about 256–512 bytes. The start latency is the cost of the
registered command pipeline (APB execute, CFG / CHK, allocation, generator, AR queue, BIU
register slice); the 2D multiplier adds 8 cycles.

### 3.2 Burst length: FIFO/2 double buffering and loop latency

TRM 4.3.4 / 4.3.6 require: bursts ≤ FIFO/2, a read is issued only with space for the whole
response, a write only when all its data is in the FIFO. With the maximum burst (FIFO/2) only
two read bursts fit, so the next read waits until the write of the previous half has drained.
The round trip *AR issue → R data in FIFO → AW / W → space released → next AR* costs a fixed
**loop latency of 8–9 cycles** plus the memory read latency `L`. The measurements fit

    eff ≈ (F / DWB) / (F / DWB + 9 + L)        F = FIFO bytes, DWB = bus bytes (burst = F/2)

| FIFO (64-bit) | 32 B | 64 B | 128 B | 256 B |
|---|---|---|---|---|
| measured eff, L = 0 | 33.1 | 49.4 | 65.6 | 77.9 |
| model | 30.8 | 47.1 | 64.0 | 78.0 |
| measured eff, L = 32 | 9.5 | 17.3 | 29.4 | 45.0 |
| model | 8.9 | 16.3 | 28.1 | 43.8 |

Shorter bursts keep more transactions in flight in the same FIFO (channel 2, 256 B FIFO, 4 KB):

| MAXBURSTLEN (beats) | 1 | 2 | 4 | 8 | 16 |
|---|---|---|---|---|---|
| ideal memory | 76.9 | 94.6 | 94.3 | 93.6 | 75.9 |
| read latency 16 | 38.9 | 69.1 | **91.9** | 78.6 | 57.0 |
| READY 70% | 60.4 | 67.9 | 69.5 | 66.2 | 65.1 |

Single-beat bursts are limited by the per-burst overhead; 2–8 beat bursts give the best single
channel rate. Rule of thumb for full rate of one channel:

    FIFO bytes ≥ DWB × (L + 10) + burst bytes

### 3.3 Read latency tolerance and FIFO depth

eff (%) of an 8 KB copy, FIFO depth per channel of the default build, default bursts:

| FIFO | L = 0 | 4 | 8 | 16 | 32 | 64 |
|---|---|---|---|---|---|---|
| 32 B (ch3) | 33.1 | 28.4 | 22.1 | 15.3 | 9.5 | 5.4 |
| 64 B (ch1) | 49.4 | 44.0 | 36.1 | 26.5 | 17.3 | 10.2 |
| 128 B (ch0) | 65.6 | 60.6 | 52.6 | 41.6 | 29.4 | 18.5 |
| 256 B (ch2) | 77.9 | 74.3 | 67.9 | 58.1 | 45.0 | 31.0 |
| 1 KB (ch2, 128-bit) | 92.3 | 91.9 | 91.3 | 90.0 | 81.7 | 58.0 |

The rate depends on the FIFO size in bytes, not on the bus width (the 64 B FIFO gives the same
efficiency on the 64-bit and 128-bit builds). `CH_ISSUECAP` above 2 brings nothing when the
burst is FIFO/2 (only two bursts fit); on the 128-bit build (4 bursts fit) it helps up to 4
(L = 32: 30.1 / 57.8 / 81.5 / 81.5% for 1 / 2 / 4 / 8).

### 3.4 Write response latency and backpressure

| B latency (cycles) | 0 | 16 | 64 |
|---|---|---|---|
| eff | 77.9 | 76.9 | 74.3 |

| READY probability (AR, AW, W) | 100% | 75% | 50% | 25% |
|---|---|---|---|---|
| eff | 77.9 | 71.7 | 46.6 | 24.1 |

Writes are posted (up to 8 outstanding per channel), so B latency is hidden. Under READY
backpressure the throughput follows the bus.

### 3.5 Element size, memory type, fixed addresses

| TRANSIZE (bytes) | 1 | 2 | 4 | 8 |
|---|---|---|---|---|
| normal memory, incrementing (B/cycle) | 6.08 | 6.07 | 6.07 | 6.07 |
| device memory (B/cycle) | 0.99 | 1.96 | 3.84 | 6.07 |
| fixed destination address, FIXED bursts (B/cycle) | 0.97 | 1.89 | 3.52 | 5.25 |

On normal memory the bandwidth optimisation (TRM 4.3.6) packs the elements into full-width
beats, so TRANSIZE does not matter. Device memory and fixed addresses transfer one element per
beat at about one beat per cycle (the bus limit for narrow transfers).

### 3.6 Alignment

| src / dst offset (64-bit) | 0/0 | 1/1 | 1/0 | 0/1 | 3/5 | 7/1 |
|---|---|---|---|---|---|---|
| eff, L = 0 | 76.0 | 75.9 | 64.4 | 64.3 | 64.4 | 64.2 |
| eff, L = 16 | 56.9 | 56.8 | 39.7 | 39.7 | 39.7 | 39.4 |
| eff, L = 0, 128-bit (1 KB FIFO) | 85.9 | 85.6 | 85.6 | 85.3 | 85.6 | 83.7 (15/1) |

Unaligned addresses keep full-width beats (the FIFO realigns). When source and destination
have a different alignment, every FIFO/2 write burst needs data from two read bursts, which
removes the overlap of the double buffering; a deeper FIFO (128-bit build) or shorter bursts
remove the loss.

### 3.7 Several channels: utilisation, fairness and priority

Measured in the window where all channels are active (`ch=window` rows), 4-beat bursts:

| Case | Port R / W utilisation | Share of bytes |
|---|---|---|
| 2 channels, equal priority, no address backpressure | 99.6 / 98.6% | 33.5 / 66.5 (ch0 / ch2) |
| 4 channels, equal priority | 99.9 / 99.4% | 27.1 / 13.3 / 53.0 / 6.6 |
| 4 channels, full bursts (FIFO/2) | 100 / 98.7% | 24.7 / 16.8 / 49.5 / 9.0 |
| AR READY 20%, equal priority | 82.4 / 82.1% | **48.2 / 51.8** |
| AR READY 20%, CHPRIO ch0 = 15 | 72.2 / 71.5% | **64.5 / 35.5** |
| AR READY 20%, CHPRIO ch2 = 15 | 77.9 / 77.4% | **8.9 / 91.1** |
| AR READY 20%, 4 channels, CHPRIO 0/1/2/3 | 66.5 / 66.4% | 0.6 / 0.3 / 76.6 / 22.5 |

* Several channels together saturate the port (98–100%): arbitration, W ordering and the
  register slices cost no bus cycles.
* Without address channel contention the subordinate serves the reads in AR order, so each
  channel gets the share its own FIFO allows (deeper FIFO → more data in flight → larger share).
* When requests wait at the arbiter (AR READY 20%), LRG gives equal grants per burst (48 / 52)
  and CHPRIO is strict: the low priority channels only get the cycles the high priority channel
  cannot use (channel 3 at priority 3 is limited by its 32 B FIFO, the rest goes to channel 2).
  LRG is fair per transaction: a channel with shorter bursts gets proportionally fewer bytes.
* CHPRIO is also driven on AxQOS for the interconnect.

### 3.8 Dual port

| Case | L = 0 | L = 16 |
|---|---|---|
| ch0 and ch2 both on M0 | 87.7% | 68.9% |
| ch0 on M0, ch2 on M1 | **131.1%** (65.6 + 65.6 per port) | 83.3% |
| crossed (M0 → M1, M1 → M0) | 131.1% | 83.3% |

With M1 two channels run at their single channel rates in parallel.

### 3.9 Command overhead

16 commands, one after the other (APB: software programs ~24 registers, enables, polls for
idle; link: one ENABLE, descriptors in memory):

| Command size | 8 B | 64 B | 512 B |
|---|---|---|---|
| APB, cycles / command | 162 | 176 | 256 |
| Command link, cycles / command | **49** | 63 | 143 |

The link chain is 2–3× faster for small commands; a full descriptor fetch and decode costs
about 40 cycles. 2D line overhead is negligible (4 KB as 1 × 4096 B: 64.5%, 16 × 256 B: 63.1%,
64 × 64 B: 63.8%); 16-byte lines are faster (93.3%) only because they produce 2-beat bursts
(see 3.2).

### 3.10 Bus width

| Build | FIFO ch2 | eff 64 KB, L = 0 | eff 64 KB, L = 16 | B / cycle (L = 16) |
|---|---|---|---|---|
| 32-bit | 128 B | 79.9 | 59.2 | 2.37 |
| 64-bit | 256 B | 79.7 | 59.1 | 4.73 |
| 128-bit | 1 KB | 99.0 | 98.6 | 15.78 |

## 4. Conclusions and recommendations

1. The BIU, arbiters and register slices are efficient: with enough requesters the AXI port runs
   at 98–100% of its R and W bandwidth, priority and LRG behave as specified, and the DMA is
   never the bottleneck under bus backpressure or write response latency.
2. The single channel rate is set by the data the channel can keep in flight, i.e. by the FIFO
   size (TRM issue rules) against the loop latency (8–9 cycles of internal pipeline + memory read
   latency). This is the price of the registered pipelines chosen for timing.
3. **Software**: for one channel against memory with latency, program MAXBURSTLEN to FIFO/8 …
   FIFO/4 instead of the maximum (default build, channel 2, L = 16: 57% → 92%). Use command
   linking for chains of small commands. Prefer equal source / destination alignment.
4. **Configuration**: size `CH_FIFO_DEPTH` from the memory latency:
   `FIFO bytes ≥ DATA_WIDTH/8 × (L + 10) + burst bytes` for full single channel rate; channels
   that only serve slow peripherals can keep small FIFOs.
5. Possible RTL improvements (not done, they trade timing margin or change the default burst
   choice): limit the automatic burst to FIFO/4 when MAXBURSTLEN is larger; shorten the internal
   loop *R beat → data committed in the FIFO (2 register stages) → AW issue (queue + BIU slice) →
   W read (3-stage FIFO read pipeline, space released at read issue) → next AR*; shorten the
   9-cycle start path.
