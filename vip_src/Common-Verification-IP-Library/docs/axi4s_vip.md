# AXI4-Stream VIP (`VIP/axi4s`)

UVM VIP for AMBA AXI4-Stream (Arm IHI0051). It carries TDATA, TSTRB, TKEEP, TLAST, TID, TDEST and TUSER with the
TVALID / TREADY handshake. Roles:

- **transmitter** (`VIP_MASTER`) sends packets;
- **receiver** (`VIP_SLAVE`) drives TREADY with configurable patterns;
- **monitor** (`VIP_MONITOR`).

A packet scoreboard compares the streams at two observation points, for example in front of and behind a DUT.

## Files and defines

| File | Content |
|---|---|
| `src/vip_axis_if.sv` | signals, clocking blocks, checker |
| `src/axis_pkg.sv` | widths, `axis_keep_e`, `axis_ready_e`, `axis_inject_e` |
| `src/axis_cfg.svh`, `axis_item.svh`, `axis_sequencer.svh`, `axis_master_driver.svh`, `axis_slave_driver.svh` | |
| `src/axis_monitor.svh`, `axis_coverage.svh`, `axis_scoreboard.svh`, `axis_agent.svh`, `axis_env.svh`, `axis_seq_lib.svh` | |
| `tb/axis_fifo_dut.sv`, `tb/axis_tb_top.sv`, `tb/axis_raw_tb_top.sv`, `tb/axis_test_pkg.sv` | example DUT (FIFO with switchable bugs), tops, tests |

Defines: `AXIS_DATA_W` (32), `AXIS_ID_W` (4), `AXIS_DEST_W` (4), `AXIS_USER_W` (4); TUSER is per beat. Typedef
`axis_vif_t`.

## Interface `vip_axis_if #(DATA_W, ID_W, DEST_W, USER_W)(aclk, aresetn)`

| Check ID | Rule |
|---|---|
| `AXIS_A_HS_STABLE` | TVALID stays high and the payload stable until TREADY |
| `AXIS_A_RESET` | TVALID low during reset |
| `AXIS_A_NO_X` | no X on TVALID / TREADY, nor on the payload with TVALID |
| `AXIS_A_STRB` | TSTRB only on bytes with TKEEP high |
| `AXIS_A_ID_DEST` | TID / TDEST constant inside a packet |
| `AXIS_A_KEEP_MID` | (optional, `check_keep_mid`) no null byte before the last beat |
| `AXIS_A_MAXLEN` | (optional, `max_packet_beats`) packet length limit |

## Configuration `axis_agent_cfg`

| Field | Default | Meaning |
|---|---|---|
| `vif`, `role`, `coverage_en`, `checks_en` | – , `VIP_MASTER`, 1, 1 | |
| `check_keep_mid`, `max_packet_beats` | 0, 0 | optional interface checks (written to the interface) |
| `timeout_cycles` | 4096 | transmitter: TREADY must come within this time |
| `inject`, `inject_pct` | `AXIS_INJ_NONE`, 100 | `DROP_VALID`, `CHANGE_DATA`, `STRB_NO_KEEP`, `ID_CHANGE` |
| `drive_junk` | 1 | payload carries junk while TVALID is low (catches receivers that sample without TVALID) |
| `ready_mode` | `AXIS_RDY_ALWAYS` | receiver: `ALWAYS`, `RANDOM` (`ready_pct`), `TOGGLE`, `BURSTY` (`burst_on_max` / `burst_off_max`), `AFTER_VALID`, `NEVER`; may change at run time |

`axis_env_cfg {src_cfg, snk_cfg, has_scoreboard, bytes_only, compare_user}`. The source is the interface in front of
the DUT and the sink the one behind it.

## Transaction `axis_item` (one packet)

Request fields:

- `id`, `dest`, `beats` (1..64);
- `keep_mode`: `FULL`, `TAIL` (a partial last beat in the low lanes) or `SPARSE`;
- `data[]`, `keep[]`, `strb[]`, `user[]` per beat;
- `delay[]`: TVALID-low cycles before each beat;
- `gap`: idle cycles before the packet.

Observation fields: `start_time`, `end_time`, `stalls`, `aborted`.

## Components

- `axis_master_driver`:
  - fetches packets ahead, so consecutive packets have no gap when the delays are 0;
  - holds the payload stable until TREADY, including injected values;
  - returns packets cut by a reset as aborted.
- `axis_slave_driver`: TREADY patterns.
- `axis_monitor`:
  - `ap`: one packet at TLAST;
  - `ap_abort`: partial packets, plus a marker per reset;
  - counters `n_pkt n_beat n_bytes n_stall_cycles n_resets`.
- `axis_scoreboard`:
  - `in_imp`: expected packets, kept in order;
  - `out_imp`: compared with the oldest expected packet;
  - `abort_imp`: a reset marker flushes the expectations;
  - `bytes_only = 1` compares only the byte stream (for width converters and packers); otherwise beats, TKEEP, TSTRB,
    TUSER (`compare_user`), TID and TDEST must match.
- `axis_coverage`:
  - packet length in beats and bytes, partial last beat, position and null bytes;
  - TID, TDEST, non-zero TUSER, gap, stalls, TID change between packets;
  - crosses: tail × length, position × tail, gap × stall.

## Sequences

| Sequence | Purpose |
|---|---|
| `axis_base_seq` | `send(item)`, blocking until the last beat was accepted |
| `axis_pkt_seq` | n random packets |
| `axis_stream_seq` | n packets with no delay (continuous TVALID across packets) |
| `axis_byte_seq` | every byte length 1..max (partial last beats) |
| `axis_sparse_seq` | position bytes (TKEEP = 1, TSTRB = 0) and sparse TKEEP |
| `axis_multi_seq` | several TID / TDEST values |
| `axis_long_seq` | one long packet |

## Integration example: a stream DUT between two VIP agents

```systemverilog
vip_axis_if #(AXIS_DATA_W, AXIS_ID_W, AXIS_DEST_W, AXIS_USER_W) s_if (.aclk(clk), .aresetn(rst_n));
vip_axis_if #(AXIS_DATA_W, AXIS_ID_W, AXIS_DEST_W, AXIS_USER_W) m_if (.aclk(clk), .aresetn(rst_n));
my_stream_dut dut (.clk, .rst_n,
  .s_tdata(s_if.tdata), .s_tkeep(s_if.tkeep), .s_tstrb(s_if.tstrb), .s_tlast(s_if.tlast), .s_tid(s_if.tid),
  .s_tdest(s_if.tdest), .s_tuser(s_if.tuser), .s_tvalid(s_if.tvalid), .s_tready(s_if.tready),
  .m_tdata(m_if.tdata), /* ... */ .m_tready(m_if.tready));

// test
scfg.vif = s_vif; scfg.role = VIP_MASTER;               // drives the DUT input
rcfg.vif = m_vif; rcfg.role = VIP_SLAVE;                // TREADY pattern on the DUT output
rcfg.ready_mode = AXIS_RDY_BURSTY;
ecfg.src_cfg = scfg; ecfg.snk_cfg = rcfg; ecfg.bytes_only = 0;
```

For a DUT that changes the beat structure (a width converter), set `ecfg.bytes_only = 1`. For a DUT that rewrites
TUSER, set `compare_user = 0`. For a DUT that transforms the data, connect the monitors (`env.src.ap`, `env.snk.ap`) to
your own predictor instead of the VIP scoreboard.

## Verification status

- Tests through the example FIFO: smoke (×2), ready patterns (×2), congestion, continuous stream, byte lengths, reset,
  `axis_checker_test` (driver injection).
- `axis_assert_test` (raw top `axis_raw_tb_top`): 14 pin-level scenarios covering every check ID, the optional checks
  and the legal corner cases.
- `axis_bug1..5`: the FIFO is run with 5 switchable defects (`+AXIS_BUG=n`), and the VIP must detect every one of them.
- Build variants `axi4s:d8` (8-bit data, 1-bit sideband) and `axi4s:d128` (wide sideband). The 8-bit build showed that
  the TSTRB injection needed a beat with a null byte; it now creates one when every byte is kept.
- Covergroup bins: 100 %.

## Limitations

- TWAKEUP (AXI5-Stream) and the parity-check signals are not modelled.
- The packet scoreboard expects in-order delivery. For a DUT that reorders streams by TID / TDEST, use one scoreboard
  per stream or your own predictor.
