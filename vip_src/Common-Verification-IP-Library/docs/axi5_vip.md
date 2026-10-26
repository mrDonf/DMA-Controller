# AXI5 VIP (`VIP/axi5`)

UVM VIP for the AMBA AXI5 interface (Arm IHI0022 Issue H and later). It contains everything of the
[AXI4 VIP](axi4_vip.md):

- bursts, outstanding transactions, out-of-order responses and interleaving;
- exclusive access, and narrow / unaligned transfers;
- the same checker IDs, configuration knobs and sequences, with the prefix `axi5_` / `AXI5_`.

It adds the AXI5 interface properties below.

| Property (IHI0022) | Signals | VIP support |
|---|---|---|
| Atomic_Transactions | `AWATOP` (R data with `RID = AWID`) | manager builds legal atomics; subordinate executes them on its memory; checker; scoreboard model |
| Poison | `WPOISON`, `RPOISON` (one bit per 64 data bits) | stored per chunk by the subordinate, returned on reads, modelled by the scoreboard |
| Check_Type (data) | `WDATACHK`, `RDATACHK` (odd parity per byte) | driven by both sides; `AXI_A_DATACHK` |
| Unique_ID_Support | `AWIDUNQ`, `BIDUNQ`, `ARIDUNQ`, `RIDUNQ` | from the item; subordinate echoes; `AXI_A_IDUNQ` |
| Trace_Signals | `AWTRACE`, `WTRACE`, `BTRACE`, `ARTRACE`, `RTRACE` | from the item; subordinate echoes; `AXI_A_TRACE` |
| Loopback_Signals | `AWLOOP`, `BLOOP`, `ARLOOP`, `RLOOP` (`AXI5_LOOP_W`) | from the item; subordinate echoes; `AXI_A_LOOP` |
| Wakeup_Signals | `AWAKEUP` | manager drives it while busy plus `wakeup_idle_cycles`; `AXI_A_WAKEUP` |

**Not modelled** (the signals do not exist on the interface):

- read data chunking (RCHUNK*);
- memory tagging (AxTAGOP, WTAG*, RTAG);
- cache maintenance / stash / prefetch (AxSNOOP, AWSTASH*);
- untranslated transactions (AxMMU*);
- NSE / RME;
- MPAM;
- QoS accept;
- the consistent-decode / regular-transaction properties;
- check signals for the control signals (only the data parity is implemented).

## Files and defines

The same layout as AXI4 (`src/vip_axi5_if.sv`, `src/axi5_pkg.sv`, `axi5_*.svh`, `tb/axi5_tb_top.sv`,
`tb/axi5_test_pkg.sv`). Defines: `AXI5_ADDR_W` (32), `AXI5_DATA_W` (32), `AXI5_ID_W` (4), `AXI5_USER_W` (1),
`AXI5_LOOP_W` (4). Derived: `AXI5_POISON_W = ceil(DATA_W / 64)`, and `AXI5_CHUNK_B` = bytes per poison bit
(`min(8, DATA_W/8)`).

Package functions:

- `axi5_burst_addr`, `axi5_valid_lanes`;
- `axi5_atop_kind`, `axi5_atop_has_rdata`, `axi5_atop_base`, `axi5_atop_lanes`;
- `axi5_atop_rbytes`, `axi5_atop_rsize`, `axi5_atop_rbeats`;
- `axi5_atomic_result` (the arithmetic of all operations), `axi5_datachk`.

## Atomic transactions

`AWATOP` encodings:

| AWATOP | Type | Operations (`AWATOP[2:0]`) |
|---|---|---|
| `000000` | non-atomic | |
| `01e ooo` | AtomicStore (no read data) | ADD, CLR, EOR, SET, SMAX, SMIN, UMAX, UMIN; `e` = big-endian |
| `10e ooo` | AtomicLoad (returns the original value) | as above |
| `110000` | AtomicSwap | |
| `110001` | AtomicCompare (compare + swap values; returns the original) | |

Rules the manager follows and the checker enforces (`AXI_A_ATOP`):

- data size 1/2/4/8 bytes for Store / Load / Swap, and 2..32 bytes for Compare;
- AWADDR aligned to the operand (for Compare: to half the data);
- AWLOCK low;
- INCR bursts, except a Compare to the upper half of its window, which is WRAP. The VIP accepts a single-transfer WRAP
  for that case;
- full-width beats when AWLEN > 0;
- strobes exactly on the operand window (`AXI_A_WSTRB`);
- an atomic must not use the ID of an outstanding write, nor, when it returns data, of an outstanding read
  (`AXI_A_ATOP_ID`);
- the read data has `ceil(operand / bus)` beats with RLAST on the last one (`AXI_A_RLAST`).

`axi5_base_seq` builds atomics:

```systemverilog
byte unsigned op[$] = '{8'h01, 8'h00, 8'h00, 8'h00}, orig[$];
axi5_resp_e rs;
bus.atomic(6'b100000, 'h1000, op, {}, orig, rs);                    // AtomicLoad ADD, 4 bytes, little endian
bus.atomic(6'b110001, 'h2004, cmp, swp, orig, rs, /*id*/ 3);       // AtomicCompare, compare value at 0x2004 (upper half)
axi5_item it = bus.make_atomic(6'b011010, 'h3000, op, {});         // AtomicStore EOR as an item (e.g. to queue it)
```

The subordinate executes an atomic when its AW and its last W beat are in. It returns the original value on R, sends
B, and updates the memory unless the response is an error. With `atomics_en = 0` it answers SLVERR, still with the
correct number of read data beats. The scoreboard repeats the operation on its own reference memory with an
independent window and half computation. It compares the returned original value and updates its model. The
directed `axi5_atomic_test` computes the expected results with a separate 64-bit integer implementation.

## Configuration `axi5_agent_cfg` (in addition to the AXI4 knobs)

| Field | Default | Meaning |
|---|---|---|
| `datachk_en` | 1 | WDATACHK / RDATACHK driven; enables `AXI_A_DATACHK` on the interface |
| `wakeup_en` | 1 | manager drives AWAKEUP; enables `AXI_A_WAKEUP` |
| `wakeup_idle_cycles` | 4 | AWAKEUP stays high this many cycles after the last transaction |
| `atomics_en` | 1 | subordinate executes atomics (0: SLVERR) |
| `poison_en` | 1 | subordinate stores / returns poison; the scoreboard checks RPOISON |
| `inject` | | AXI4 kinds plus `ATOP_LOCK`, `ATOP_ALIGN`, `IDUNQ`, `WDATACHK`, `WAKEUP` (manager) and `RDATACHK`, `TRACE`, `LOOP`, `RIDUNQ`, `ATOP_RBEATS` (subordinate) |

The interface properties are properties of the link. Every agent on one interface must agree on `datachk_en` and
`wakeup_en`: the agents set `vif.datachk_en` / `vif.wakeup_check_en` in `start_of_simulation`.

## Transaction `axi5_item` (additions)

- Request fields: `atop`, `idunq`, `trace` (also WTRACE), `loop`, and `poison[]` per write beat. They default to 0
  through soft constraints. Set them after `randomize()`, or with `randomize() with { trace == 1; }`.
- Response fields: `rpoison[]` per read beat, and for atomics `adata[]` / `aresp[]` / `apoison[]` (the read data
  beats).
- Helpers: `atop_kind()`, `is_atomic()`. `valid_lanes(i)` returns the operand window for atomics.

## Poison model

The subordinate keeps one poison flag per chunk of `AXI5_CHUNK_B` bytes:

- a write beat with WPOISON set for a chunk (and any strobe in it) poisons the chunk;
- a non-poisoned write that writes every byte of the chunk clears it;
- a partial non-poisoned write keeps the poison;
- reads return the flags on RPOISON;
- atomics with poisoned write data poison the operand chunks.

## Other checks

The AXI4 checks apply unchanged, with the rules described in [axi4_vip.md](axi4_vip.md):

- `AXI_A_RESET`, `AXI_A_HS_STABLE` (it includes the AXI5 signals of each channel payload), `AXI_A_NO_X`;
- `AXI_A_BURST`, `AXI_A_4KB`, `AXI_A_LOCK`;
- `AXI_A_WLAST`, `AXI_A_RLAST`, `AXI_A_WSTRB`;
- `AXI_A_B_ORDER`, `AXI_A_R_ID`, `AXI_A_EXOKAY`.

The AXI5 checks:

| Check ID | Rule |
|---|---|
| `AXI_A_ATOP` | atomic rules above (reserved encoding, AWLOCK, size, alignment, burst, AWSIZE) |
| `AXI_A_ATOP_ID` | atomic ID unique among outstanding transactions |
| `AXI_A_IDUNQ` | AxIDUNQ with another same-ID transaction outstanding in that direction, or the reverse; BIDUNQ / RIDUNQ equal to the request |
| `AXI_A_TRACE` | BTRACE = AWTRACE, RTRACE = ARTRACE (AWTRACE for atomic read data) |
| `AXI_A_LOOP` | BLOOP = AWLOOP, RLOOP = ARLOOP (AWLOOP for atomic read data) |
| `AXI_A_DATACHK` | odd parity per byte on W and R |
| `AXI_A_WAKEUP` | AWAKEUP high whenever AWVALID, ARVALID or WVALID is high (strict interpretation; switch off with `wakeup_en = 0`) |

## Integration

The same steps as for [AXI4](axi4_vip.md). Additional points:

- Connect the AXI5 signals your DUT has. Tie the rest in the top so the NO_X checks see a defined value, for example
  `assign axi.bidunq = 1'b0; assign axi.btrace = 1'b0; assign axi.bloop = '0;`, and `rpoison` / `rdatachk` for a
  subordinate without these properties.
- Switch off what the DUT does not support: `cfg.datachk_en = 0`, `cfg.wakeup_en = 0`, `cfg.poison_en = 0`,
  `cfg.atomics_en = 0`.
- Pick IDs that respect the atomic and IDUNQ rules. The random `axi5_atomic_seq` takes an ID range (`id_lo`, `id_hi`),
  and `axi5_wr_rd_seq` has one too. Use separate ranges for concurrent traffic.

## Sequences (in addition to the AXI4 set)

| Sequence | Purpose |
|---|---|
| `axi5_api_seq` | stays alive; `xfer`, `atomic`, `make_atomic`, `read_bytes`, `write_bytes`, `write_word`, `read_word` |
| `axi5_atomic_seq` | random atomics of every type / operation / size / endianness with a shadow copy of the region |
| `axi5_poison_seq` | poison round trip, a partial write keeps the poison, a full write clears it |
| `axi5_unique_seq` | outstanding reads / writes with distinct IDs and AxIDUNQ, random TRACE / LOOP |

## Verification status

- All AXI4 tests, run on the AXI5 VIP.
- `axi5_atomic_test` (×3): 128 directed Store / Load cases (8 operations × 4 sizes × 2 endiannesses), 4 Swaps,
  20 Compares (2..32 bytes, lower / upper half, match / no match), random atomics concurrent with normal traffic, and
  the `atomics_en = 0` SLVERR path.
- `axi5_poison_test`, `axi5_signals_test` (IDUNQ / TRACE / LOOP with out-of-order responses), `axi5_wakeup_test`.
- `axi5_checker_test`: 18 driver injections, plus the ATOP_ID case; the read-beat injection adapts to the bus width.
- `axi5_assert_test`: 57 pin-level scenarios, covering every check ID including all AXI5 ones.

Build variants:

- `axi5:d64i8`: 64-bit data, one poison bit per beat;
- `axi5:d256a64`: 256-bit data, four poison bits, 64-bit address.

Covergroup bins (AXI4 model + AXI5 extension group: atomic type × operation × size, endianness, compare half, poison,
IDUNQ, TRACE, LOOP): 100 %.
