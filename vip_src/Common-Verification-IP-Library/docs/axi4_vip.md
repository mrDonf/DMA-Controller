# AXI4 VIP (`VIP/axi4`)

UVM VIP for AMBA AXI4 full (Arm IHI0022). It has five independent channels and supports:

- bursts of up to 256 beats (FIXED / INCR / WRAP) and narrow and unaligned transfers;
- outstanding transactions, out-of-order responses between IDs, and read data interleaving;
- exclusive access (EXOKAY) and the SLVERR / DECERR responses.

Roles: **manager** (`VIP_MASTER`), **subordinate** (`VIP_SLAVE`, a memory with configurable latency, ordering and
errors) and **monitor** (`VIP_MONITOR`). See also [axi5_vip.md](axi5_vip.md) for the AXI5 superset.

## Files

| File | Content |
|---|---|
| `src/vip_axi4_if.sv` | 5 channels, clocking blocks `mst_cb` / `slv_cb` / `mon_cb`, protocol checker |
| `src/axi4_pkg.sv` | widths, `axi4_burst_e`, `axi4_resp_e`, `axi4_inject_e`, `axi4_burst_addr()`, `axi4_valid_lanes()` |
| `src/axi4_cfg.svh`, `axi4_item.svh`, `axi4_sequencer.svh` | configuration, burst item, sequencer |
| `src/axi4_master_driver.svh` | manager: fetch / AW / W / AR / B / R engines, outstanding limits |
| `src/axi4_slave_driver.svh` | subordinate: memory, OOO, interleaving, exclusive monitor, errors |
| `src/axi4_monitor.svh`, `axi4_coverage.svh`, `axi4_scoreboard.svh`, `axi4_agent.svh`, `axi4_env.svh`, `axi4_seq_lib.svh` | |
| `tb/axi4_tb_top.sv`, `tb/axi4_test_pkg.sv` | self-tests |

Defines: `AXI4_ADDR_W` (32), `AXI4_DATA_W` (32; 8..1024), `AXI4_ID_W` (4), `AXI4_USER_W` (1). Typedef `axi4_vif_t`.

## Interface `vip_axi4_if #(ADDR_W, DATA_W, ID_W, USER_W)(aclk, aresetn)`

The channels and their signals:

- AW: `awid awaddr awlen awsize awburst awlock awcache awprot awqos awregion awuser awvalid awready`
- W: `wdata wstrb wlast wuser wvalid wready`
- B: `bid bresp buser bvalid bready`
- AR: `ar*` (the same fields as AW)
- R: `rid rdata rresp rlast ruser rvalid rready`

| Check ID | Rule |
|---|---|
| `AXI_A_RESET` | every VALID low while ARESETn is low |
| `AXI_A_HS_STABLE` | VALID stays high and the payload stable until READY (all five channels) |
| `AXI_A_NO_X` | no X on VALID / READY, nor on the payload of a valid channel |
| `AXI_A_BURST` | reserved AxBURST, AxSIZE wider than the bus, WRAP length not 2/4/8/16 or unaligned, FIXED longer than 16 beats |
| `AXI_A_4KB` | an INCR burst crosses a 4 KB boundary |
| `AXI_A_LOCK` | exclusive access longer than 16 beats, or not a power-of-two size up to 128 bytes |
| `AXI_A_WLAST` | WLAST exactly on the last beat (AWLEN); also checked when the data comes before the address |
| `AXI_A_RLAST` | RLAST exactly on the last beat of the read (per ID, interleaving allowed) |
| `AXI_A_WSTRB` | WSTRB only on the byte lanes of the beat (narrow / unaligned transfers) |
| `AXI_A_B_ORDER` | BVALID only after the address and the last data beat of that write were accepted |
| `AXI_A_R_ID` | B / R ID matches an outstanding request |
| `AXI_A_EXOKAY` | EXOKAY only as the response to an exclusive access |

## Configuration `axi4_agent_cfg`

| Field | Default | Meaning |
|---|---|---|
| `vif`, `role`, `coverage_en`, `checks_en` | – , `VIP_MASTER`, 1, 1 | |
| `timeout_cycles` | 4096 | handshake timeout |
| `max_wr_outstanding`, `max_rd_outstanding` | 8, 8 | manager outstanding limits |
| `bready_pct`, `rready_pct` | 100, 100 | manager: probability (%) of BREADY / RREADY per cycle |
| `inject`, `inject_pct` | `AXI4_INJ_NONE`, 100 | manager: `WLAST_EARLY`, `WLAST_LATE`, `AW_DROP_VALID`, `AW_CHANGE`, `CROSS_4KB`, `WSTRB_OUTSIDE`; subordinate: `RLAST_EARLY`, `EXOKAY_NORMAL` |
| `mem`, `mem_init` | new, `MEM_INIT_ADDR_HASH` | subordinate memory |
| `awready_pct`, `wready_pct`, `arready_pct` | 100 | subordinate READY probability per cycle |
| `b_delay_min/max`, `r_delay_min/max` | 0 | response latency (cycles) |
| `ooo`, `interleave` | 0, 0 | out-of-order responses between IDs; R interleaving between IDs |
| `exclusive_en` | 1 | exclusive access monitor |
| `err_pct`, `err_lo`, `err_hi` | 0, `'1`, 0 | random SLVERR; SLVERR window |
| `base_addr`, `size`, `unmapped_decerr` | 0, 0, 0 | mapped window; DECERR outside it |

## Transaction `axi4_item` (one burst)

Request fields:

- `write id addr len size burst lock cache prot qos region user`;
- `data[]`, `strb[]` (per beat, bus lanes as on the wire);
- `aw_delay` (cycles before AxVALID) and `w_delay[]` (cycles before each WVALID).

The constraints make every random item legal:

- burst-dependent lengths (FIXED ≤ 16, WRAP 2/4/8/16);
- WRAP alignment and the 4 KB rule;
- exclusive size and alignment;
- strobes inside the beat lanes.

`cache` / `prot` / `qos` / `region` / `user` default to `3 / 0 / 0 / 0 / 0` through soft constraints.

Response fields: `bresp`, `rresp[]`, `error`, `aborted`, `start_time`, `end_time`. The monitor also sets
`latency_cycles`, `w_first_seen` (data before address), `ooo`, `outstanding` and `w_stalls`.

Helpers: `beats()`, `total_bytes()`, `beat_addr(i)`, `valid_lanes(i)` (IHI0022 A3.4.1 address rules).

## Components

- `axi4_master_driver`: separate channel engines, so W may precede AW and read and write traffic overlap. It enforces
  the outstanding limits, uses random B / R ready, and has a pipelined sequencer handshake (`get_response` by
  transaction ID). On reset every item in flight returns with `aborted = 1`.
- `axi4_slave_driver`: sparse memory.
  - Write data may arrive before the address. A write commits when its AW and its last W beat are in.
  - Responses can be out of order between IDs, and R beats can be interleaved; the order stays in-order per ID.
  - It has an exclusive monitor per ID.
  - Responses are SLVERR / DECERR by window, by `err_pct`, or for unmapped addresses.
  - Override `decide(axi4_sreq)` to change the response policy.
- `axi4_monitor`: rebuilds the bursts and pairs the k-th AW with the k-th W burst.
  - Ports: `ap` and `ap_abort`.
  - Counters: `n_wr n_rd n_err n_ooo n_wfirst max_wr_out max_rd_out n_beats_w n_beats_r`.
- `axi4_scoreboard` (ports `imp` / `imp_abort`): reference memory for memory-like subordinates.
  - OKAY / EXOKAY writes update it, and OKAY reads are compared on the beat lanes.
  - A failed exclusive write (OKAY with AxLOCK) changes nothing.
  - Errors are accepted only where they are possible.
  - Words of reset-cut writes become unknown.
- `axi4_coverage`:
  - burst type × direction / size / length, ID range, address quarter, lock, cache (16), prot (8), qos;
  - response × direction, narrow / unaligned / near-4 KB;
  - out-of-order, data-before-address, outstanding depth, latency.
  - Waiver: WRAP bursts longer than 16 beats do not exist.

## Sequences

| Sequence | Purpose |
|---|---|
| `axi4_base_seq` | `xfer(item)`, `write_word()`, `read_word()`, `compare(write, read)` (FIXED-aware) |
| `axi4_api_seq` | stays alive for helper calls from any thread |
| `axi4_single_seq`, `axi4_wr_rd_seq` | single beats; random bursts written and read back |
| `axi4_outstanding_seq` | n writes queued before any response, then n reads queued |
| `axi4_ooo_seq` | reads with different IDs back to back |
| `axi4_narrow_seq`, `axi4_long_seq` | byte / halfword / unaligned transfers; the longest INCR burst inside 4 KB |
| `axi4_excl_seq` | exclusive pair (EXOKAY), and an exclusive write after a conflicting write (OKAY, no update) |
| `axi4_error_seq` | SLVERR window, DECERR outside the map, a burst touching the window |
| `axi4_mixed_seq` | concurrent reads and writes on separate regions |

## Integration example: the DUT is an AXI4 subordinate (memory controller)

```systemverilog
vip_axi4_if #(AXI4_ADDR_W, AXI4_DATA_W, AXI4_ID_W, AXI4_USER_W) axi (.aclk(clk), .aresetn(rst_n));
my_axi_mem dut (.aclk(clk), .aresetn(rst_n),
  .s_awid(axi.awid), .s_awaddr(axi.awaddr), .s_awlen(axi.awlen), .s_awsize(axi.awsize), .s_awburst(axi.awburst),
  .s_awlock(axi.awlock), .s_awcache(axi.awcache), .s_awprot(axi.awprot), .s_awvalid(axi.awvalid), .s_awready(axi.awready),
  .s_wdata(axi.wdata), .s_wstrb(axi.wstrb), .s_wlast(axi.wlast), .s_wvalid(axi.wvalid), .s_wready(axi.wready),
  .s_bid(axi.bid), .s_bresp(axi.bresp), .s_bvalid(axi.bvalid), .s_bready(axi.bready),
  .s_arid(axi.arid), /* ... AR and R channels ... */ .s_rready(axi.rready));
// unused AXI4 signals of the DUT: tie the inputs in the top, e.g. assign axi.buser = '0; assign axi.ruser = '0;

// test
mcfg.role = VIP_MASTER; mcfg.max_rd_outstanding = 16;
ecfg.mst_cfg = mcfg;            // no VIP slave
ecfg.has_scoreboard = 1;        // the memory scoreboard fits a memory controller
...
axi4_wr_rd_seq s = axi4_wr_rd_seq::type_id::create("s");
s.randomize() with { n == 200; lo == 'h0; hi == 'hF_FFFF; };
s.start(env.mst.sqr);
```

**DUT is a manager** (DMA, CPU port): use `role = VIP_SLAVE` with `ooo = 1`, `interleave = 1`, latency and READY
knobs, and keep the scoreboard on the slave agent's monitor. **Interconnect**: put `VIP_MONITOR` agents on every port
and compare the monitor streams in your own scoreboard.

## Verification status

Back-to-back tests:

- smoke, burst (×3), attr (16 cache × 8 prot × qos × region × user over the whole address space), outstanding,
  out-of-order + interleaving, narrow / unaligned / 256-beat, exclusive, error, mixed (×2), reset;
- `axi4_checker_test` (8 driver injections);
- `axi4_assert_test` (32 pin-level scenarios covering every check ID and legal baselines). It found and fixed a
  cascaded `AXI_A_B_ORDER` after a B with an unknown ID.

Build variants:

- `axi4:d64i8`;
- `axi4:d128a64`, which found address constraints that overflowed at 64-bit addresses;
- `axi4:d16i1`, which found ID values wider than a 1-bit ID.

Covergroup bins: 100 % with the WRAP waiver.

## Limitations

- AXI4 only. AXI3 write interleaving (WID) is not supported, and ACE / ACE-Lite snoop channels are not modelled.
- The memory scoreboard assumes no two concurrent transactions touch the same bytes. It orders by completion.
- Exclusive monitor: one reservation per ID, cleared by any overlapping successful write.
