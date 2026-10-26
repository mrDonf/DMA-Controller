# APB VIP (`VIP/apb`)

UVM VIP for AMBA APB4 (Arm IHI0024): PSEL / PENABLE / PREADY handshake with wait states, PSLVERR, PSTRB and PPROT.
It has three roles:

- **requester** (`VIP_MASTER`) issues transfers;
- **completer** (`VIP_SLAVE`) is a memory model with wait states and error responses;
- **monitor** (`VIP_MONITOR`) only observes.

It also provides a reference-memory scoreboard, functional coverage and a `uvm_reg_adapter`.

## Files

| File | Content |
|---|---|
| `src/vip_apb_if.sv` | signals, clocking blocks `mst_cb` / `slv_cb` / `mon_cb`, protocol assertions |
| `src/apb_pkg.sv` | package: widths, `apb_inject_e`, includes the classes below |
| `src/apb_cfg.svh` | `apb_agent_cfg` |
| `src/apb_item.svh` | `apb_item` (one transfer) |
| `src/apb_sequencer.svh`, `apb_master_driver.svh`, `apb_slave_driver.svh`, `apb_monitor.svh` | agent components |
| `src/apb_coverage.svh`, `apb_scoreboard.svh`, `apb_agent.svh`, `apb_env.svh` | coverage, reference model, agent, env (`apb_env_cfg`) |
| `src/apb_reg_adapter.svh` | `apb_reg_adapter` for the UVM register layer |
| `src/apb_seq_lib.svh` | sequence library |
| `tb/apb_tb_top.sv`, `tb/apb_dut_tb_top.sv`, `tb/apb_test_pkg.sv` | self-test benches (back-to-back, and with the GPIO IP of this repository) |

Defines: `APB_ADDR_W` (default 32), `APB_DATA_W` (8, 16 or 32; default 32). Typedef `apb_vif_t` is the virtual interface type.

## Interface `vip_apb_if #(ADDR_W, DATA_W)(pclk, presetn)`

Signals: `paddr pprot psel penable pwrite pwdata pstrb` (requester), `pready prdata pslverr` (completer). One `psel` per
interface: the address decoder of a multi-completer system lives outside the interface. Use one interface per completer.

| Check ID | Rule |
|---|---|
| `APB_A_SETUP` | PENABLE is low in the first cycle of a transfer (SETUP) |
| `APB_A_ACCESS` | SETUP is followed by ACCESS in the next cycle |
| `APB_A_PEN_PSEL` | PENABLE only with PSEL |
| `APB_A_STABLE` | PADDR, PWRITE and PPROT are stable from SETUP to the end of ACCESS, and so are PWDATA / PSTRB for writes (also during wait states) |
| `APB_A_PEN_END` | PENABLE drops after the completing cycle |
| `APB_A_RD_STRB` | PSTRB is low in reads |
| `APB_A_NO_X` | no X on PSEL / PENABLE, on PADDR / PWRITE of a transfer, on PREADY in ACCESS, on PRDATA / PSLVERR at the end of a read, or on PWDATA / PSTRB in a write |

The monitor also reports `[APB_TIMEOUT]` when PREADY stays low for more than `timeout_cycles`.

## Configuration `apb_agent_cfg`

| Field | Default | Meaning |
|---|---|---|
| `vif`, `role` | – , `VIP_MASTER` | virtual interface; `VIP_MASTER` / `VIP_SLAVE` / `VIP_MONITOR` |
| `coverage_en`, `checks_en` | 1, 1 | build the coverage subscriber; enable the interface checks |
| `timeout_cycles` | 2048 | PREADY timeout (monitor and requester) |
| `idle_min`, `idle_max` | 0, 3 | idle cycles between transfers (sequences use them for `item.idle`) |
| `inject`, `inject_pct` | `APB_INJ_NONE`, 100 | requester error injection: `NO_ACCESS`, `EARLY_PENABLE`, `ADDR_CHANGE`, `STRB_ON_READ` |
| `mem`, `mem_init` | new, `MEM_INIT_ADDR_HASH` | completer memory (`vip_sparse_mem`); value of never-written bytes |
| `wait_min`, `wait_max` | 0, 0 | completer wait states per transfer |
| `err_pct` | 0 | % of transfers answered with PSLVERR |
| `err_lo`, `err_hi` | `'1`, 0 | address window that always answers PSLVERR (off when `err_lo > err_hi`) |
| `base_addr`, `size`, `unmapped_error` | 0, 0, 0 | mapped window (`size` 0 = everything); PSLVERR outside it |
| `default_pready` | 0 | completer PREADY outside an access phase |

## Transaction `apb_item`

Request fields: `addr write data strb prot idle` (`idle`: cycles before the transfer). Response / observation fields:
`slverr wait_cycles start_time end_time aborted`.

Constraints:

- reads have `strb == 0` and writes `strb != 0`;
- `addr` is aligned to the bus width by a soft constraint (`soft (addr % STRB_W) == 0`);
- `prot` defaults to 0 through a soft constraint;
- `idle` is mostly 0.

## Components and ports

- `apb_master_driver`: SETUP → ACCESS → waits for PREADY. Blocking handshake, the response is the item with read data /
  slverr. On reset the item returns with `aborted = 1`.
- `apb_slave_driver`: completer with memory, wait states and errors. Override the virtual `respond()` (factory) to model
  registers instead of a memory.
- `apb_monitor`:
  - `ap`: completed transfers;
  - `ap_setup`: the request at the end of SETUP;
  - `ap_abort`: transfers cut by reset;
  - counters `n_xfer n_wr n_rd n_err n_wait_cycles n_b2b`.
- `apb_scoreboard`:
  - OKAY writes update a reference memory with the strobes, and OKAY reads are compared with it;
  - PSLVERR is accepted only where the configuration allows it;
  - aborted writes make the touched words unknown.
- `apb_coverage`: direction, address quarter, alignment, strobe patterns, PPROT × direction, PSLVERR, wait states,
  back-to-back.
- `apb_env`: `apb_env_cfg {mst_cfg, slv_cfg, has_scoreboard}`. It builds agent `mst` and/or agent `slv` and the scoreboard.

## Sequences (`apb_seq_lib.svh`)

| Sequence | Purpose |
|---|---|
| `apb_base_seq` | `write(addr, data, err, strb, prot, idle)`, `read(addr, data, err, prot, idle)`, `xfer(item)` |
| `apb_api_seq` | stays alive; call the helpers from any thread |
| `apb_write_seq`, `apb_read_seq` | one transfer from fields |
| `apb_wr_rd_seq` | n × write + read back + compare |
| `apb_burst_seq` | back-to-back transfers (PSEL stays high) |
| `apb_strobe_seq` | PSTRB lane walk |
| `apb_rand_seq` | n random transfers in [lo, hi] |
| `apb_error_seq` | accesses that must answer PSLVERR, then a clean access |
| `apb_reg_walk_seq` | write / read-back of a register list with masks (DUT bring-up) |

## Integration example: the DUT is an APB completer

```systemverilog
// top
vip_apb_if #(APB_ADDR_W, APB_DATA_W) apb (.pclk(pclk), .presetn(presetn));
my_periph dut (.pclk, .presetn, .psel(apb.psel), .penable(apb.penable), .pwrite(apb.pwrite), .paddr(apb.paddr[11:0]),
               .pwdata(apb.pwdata), .pstrb(apb.pstrb), .pprot(apb.pprot),
               .pready(apb.pready), .prdata(apb.prdata), .pslverr(apb.pslverr));
initial begin uvm_config_db #(apb_vif_t)::set(null, "*", "apb_vif", apb); run_test(); end

// test build_phase
apb_agent_cfg c = apb_agent_cfg::type_id::create("c");
apb_env_cfg   e = apb_env_cfg::type_id::create("e");
void'(uvm_config_db #(apb_vif_t)::get(this, "", "apb_vif", c.vif));
c.role = VIP_MASTER;
e.mst_cfg = c; e.has_scoreboard = 0;            // registers are not a memory
uvm_config_db #(apb_env_cfg)::set(this, "env", "cfg", e);
env = apb_env::type_id::create("env", this);

// test run_phase
apb_api_seq regs = apb_api_seq::type_id::create("regs");
fork regs.start(env.mst.sqr); join_none
#0;
regs.write('h004, 32'h1, err);
regs.read ('h000, data, err);
```

Register layer: set `apb_reg_adapter` on the register map with `map.set_sequencer(env.mst.sqr, adapter)`. Connect a
`uvm_reg_predictor #(apb_item)` to `env.mst.ap`.

**DUT is a requester**: use `role = VIP_SLAVE` (memory completer, optional wait states / errors) and keep the
scoreboard. **Monitor only**: `role = VIP_MONITOR`.

## Verification status

Self-tests (`tb/apb_test_pkg.sv`):

- back-to-back tests: smoke, rand (×3), attr (every PPROT, whole address space), waits, back-to-back, strobes, errors,
  reset;
- `apb_checker_test`: driver injection;
- `apb_assert_test`: 17 pin-level scenarios, each fires exactly one check ID, including a legal read with a changing
  PWDATA;
- `apb_dut_test`: against the GPIO IP of this repository.

Build variants `apb:d16a16` and `apb:d8a16` repeat every non-DUT test. Covergroup bins: 100 %. The latest numbers are
in `VIP/README.md`.

## Limitations

- APB3/APB4 only: the APB5 extensions (PWAKEUP, PAUSER / PWUSER / PRUSER / PBUSER, parity check signals, RME) are not
  modelled.
- One completer per interface (no PSELx vector).
