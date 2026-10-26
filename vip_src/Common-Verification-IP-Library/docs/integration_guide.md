# Integrating a VIP into a testbench

This guide applies to every VIP of the library. The per-VIP documents give the protocol-specific details (signals,
configuration knobs, sequences) and a complete example.

## 1. Compile

Compile the files in this order: the UVM library, the common package, then for each VIP its interface and package.
Each VIP contributes two files:

| Step | Files |
|---|---|
| UVM 1.2 | `uvm_pkg.sv` (`+incdir+$UVM_HOME/src`), with the DPI library at run time |
| common | `VIP/common/vip_common_pkg.sv`, optionally `VIP/common/vip_clk_rst_if.sv` |
| per VIP | `VIP/<vip>/src/vip_<vip>_if.sv`, `VIP/<vip>/src/<vip>_pkg.sv` |

Include directories: `VIP/common` and `VIP/<vip>/src` (the package includes its class files and `vip_macros.svh`).

Bus widths and other structural parameters are compile-time defines of the package. Every interface instance must use
the same values:

```
vlog -sv +incdir+VIP/common +incdir+VIP/axi4/src \
     +define+AXI4_DATA_W=64 +define+AXI4_ID_W=6 \
     VIP/common/vip_common_pkg.sv VIP/axi4/src/vip_axi4_if.sv VIP/axi4/src/axi4_pkg.sv  <your files>
```

| VIP | defines (default) |
|---|---|
| apb | `APB_ADDR_W` (32), `APB_DATA_W` (32) |
| ahb | `AHB_ADDR_W` (32), `AHB_DATA_W` (32) |
| axi4 | `AXI4_ADDR_W` (32), `AXI4_DATA_W` (32), `AXI4_ID_W` (4), `AXI4_USER_W` (1) |
| axi5 | `AXI5_ADDR_W` (32), `AXI5_DATA_W` (32), `AXI5_ID_W` (4), `AXI5_USER_W` (1), `AXI5_LOOP_W` (4) |
| axi4s | `AXIS_DATA_W` (32), `AXIS_ID_W` (4), `AXIS_DEST_W` (4), `AXIS_USER_W` (4) |
| spi | `SPI_NUM_CS` (4) |
| qspi | `QSPI_NUM_CS` (4) |
| uart, i2c | none |

Several instances of one VIP with *different* widths in the same simulation are not possible, because the widths are
package-level constants. Use the widest configuration, or keep a separate compile of the package.

## 2. Instantiate the interface and connect it to the DUT

The VIP interface holds the bus signals. Connect the DUT ports to them in the top module. Then publish a virtual
interface with `uvm_config_db`:

```systemverilog
module tb_top;
  import uvm_pkg::*;
  import axi4_pkg::*;
  logic clk, rst_n;
  vip_axi4_if #(AXI4_ADDR_W, AXI4_DATA_W, AXI4_ID_W, AXI4_USER_W) axi (.aclk(clk), .aresetn(rst_n));

  my_axi_slave dut (.aclk(clk), .aresetn(rst_n),
    .awid(axi.awid), .awaddr(axi.awaddr), .awvalid(axi.awvalid), .awready(axi.awready), /* ... all channels ... */ );

  initial begin
    uvm_config_db #(axi4_vif_t)::set(null, "uvm_test_top", "axi_vif", axi);
    run_test();
  end
endmodule
```

Rules that apply to every VIP:

- **Unidirectional buses** (APB, AHB, AXI, AXI4-Stream): the agent drives the signals of its side through the
  interface's clocking block. Connect DUT outputs to the opposite side's signals. Signals that nobody drives stay X, and
  the `*_A_NO_X` checks report that. Tie off unused optional signals in the top (for example AXI5 `awakeup` for a DUT
  without wakeup, or set `cfg.wakeup_en = 0`).
- **Bidirectional / open-drain buses** (I2C, QSPI IO, SPI MISO): the interface nets are resolved nets with pull-ups
  where the protocol needs them. The DUT adds its own driver with a continuous assignment, for example
  `assign i2c.sda = dut_sda_oe ? 1'b0 : 1'bz;` or `assign qspi.io[i] = dut_oe[i] ? dut_o[i] : 1'bz;`.
- **Reset**: connect the bus reset to the interface's reset port. Every agent aborts its traffic when reset is asserted.
- **One interface per bus**: a VIP interface is one link. Several DUT ports need several interface instances and
  several agents.

## 3. Configure and build the agent(s)

Each agent reads a configuration object from `uvm_config_db` with the key `"cfg"`. The minimal content is the virtual
interface and the role:

```systemverilog
class my_test extends uvm_test;
  `uvm_component_utils(my_test)
  axi4_env       env;
  axi4_env_cfg   ecfg;
  axi4_agent_cfg mcfg;

  function void build_phase(uvm_phase phase);
    axi4_vif_t vif;
    super.build_phase(phase);
    if (!uvm_config_db #(axi4_vif_t)::get(this, "", "axi_vif", vif)) `uvm_fatal("CFG", "no axi_vif")
    mcfg = axi4_agent_cfg::type_id::create("mcfg");
    mcfg.vif  = vif;
    mcfg.role = VIP_MASTER;                 // VIP_MASTER, VIP_SLAVE or VIP_MONITOR
    mcfg.max_wr_outstanding = 4;            // protocol-specific knobs (see the VIP document)
    ecfg = axi4_env_cfg::type_id::create("ecfg");
    ecfg.mst_cfg = mcfg;                    // the DUT is the subordinate: no VIP slave agent
    ecfg.has_scoreboard = 0;                // the memory scoreboard only fits memory-like DUTs
    uvm_config_db #(axi4_env_cfg)::set(this, "env", "cfg", ecfg);
    env = axi4_env::type_id::create("env", this);
  endfunction
endclass
```

The env is optional. A testbench with its own environment can instantiate `<vip>_agent` directly:

```systemverilog
uvm_config_db #(axi4_agent_cfg)::set(this, "m_axi_agent*", "cfg", mcfg);   // key "cfg" for the agent and its children
m_axi_agent = axi4_agent::type_id::create("m_axi_agent", this);
```

Then connect `m_axi_agent.ap` (monitor output) to your scoreboard or predictor in `connect_phase`.

Typical role choices:

| DUT is | VIP role | what the VIP does |
|---|---|---|
| a bus slave / subordinate / receiver | `VIP_MASTER` | generates traffic from sequences |
| a bus master / manager / transmitter | `VIP_SLAVE`  | answers like a memory / device (configurable latency, errors) |
| connected to another DUT block | `VIP_MONITOR` | checks the protocol, collects coverage, publishes transactions |

## 4. Generate traffic

Start the VIP sequences on the agent's sequencer, or write your own sequences derived from `<vip>_base_seq`. The base
sequence has blocking helpers such as `write_word()`, `read_word()` and `xfer()`. For tests that call the helpers from
several threads, start an `*_api_seq` once (its body only waits for `stop`) and call its helpers:

```systemverilog
task run_phase(uvm_phase phase);
  axi4_api_seq bus = axi4_api_seq::type_id::create("bus");
  bit [31:0] d; bit err;
  phase.raise_objection(this);
  fork bus.start(env.mst.sqr); join_none
  #0;
  bus.write_word('h1000, 32'hCAFE_0001, err);
  bus.read_word ('h1000, d, err);
  if (err || d != 32'hCAFE_0001) `uvm_error("TEST", "register read-back")
  phase.drop_objection(this);
endtask
```

The bus VIPs (AHB, AXI4, AXI5) use a pipelined sequencer handshake. `item_done` comes immediately and the response
comes when the transaction completes. A sequence can therefore queue several transactions before it collects the
responses with `get_response(rsp, item.get_transaction_id())`. The base sequences set `set_response_queue_depth(-1)`.

Register layer: the APB VIP has `apb_reg_adapter` (`uvm_reg_adapter`). Use it with `uvm_reg_predictor` connected to the
agent's `ap`.

## 5. Check

- **Protocol**: always on (`cfg.checks_en`). A violation is a `$error` whose message starts with `[<ID>]`. Every
  interface counts them in `viol_cnt` and `viol_by_id`. Check `vif.viol_cnt == 0` in your `check_phase`, or rely on
  the `** Error` that the simulator prints.
- **Data**: connect a monitor to your scoreboard. Use the VIP scoreboard only where it fits:
  - the AXI/AHB/APB memory scoreboards for memory-like subordinates;
  - the AXIS packet scoreboard between two stream interfaces (`in_imp` / `out_imp`);
  - the QSPI flash model for flash controllers;
  - the UART / SPI / I2C scoreboards with expectations pushed by the test.
- **Coverage**: `cfg.coverage_en` builds the subscriber. Collect UCDBs with your usual flow.

## 6. Negative tests and expected errors

To prove that your DUT reports or tolerates a protocol violation, or to test the VIP itself:

```systemverilog
vip_expect_catcher catcher = new("catcher");
cfg.vif.expect_violations = 1;                 // interface checks count instead of $error
catcher.add_expect("AXI4_SEQ_MISMATCH", UVM_ERROR, 0);   // demote these errors (min_count 0: optional)
catcher.install();
mcfg.inject = AXI4_INJ_WLAST_EARLY;            // make the VIP violate the protocol
...
if (cfg.vif.viol_by_id["AXI_A_WLAST"] == 0) `uvm_error("TEST", "WLAST violation not detected")
void'(catcher.check_all());                    // in check_phase: reports expectations that were not met
```

`vip_viol_check(target, prev, cur, allowed)` in `vip_common_pkg` takes two snapshots of `viol_by_id`. It returns an
error text when the target ID did not fire, or when any other ID fired between the snapshots.

## 7. Logging conventions

Every report uses `get_name()` of the reporting component as the UVM ID, so the instance name appears in the report.
Name your agents meaningfully (`"cpu_axi"`, `"dma_axi"`). The message text starts with a fixed tag, `[TAG] text`. Filter
on the tag with `vip_expect_catcher`, or set the verbosity per component with `set_report_verbosity_level_hier()`.
Transaction-level information is printed at `UVM_HIGH`, and summaries at `UVM_LOW` in `report_phase`.

## 8. Checklist

- [ ] same `+define+` widths for every compile unit that imports the package
- [ ] every DUT port connected to an interface signal; unused optional inputs tied off
- [ ] one configuration object per agent: `vif`, `role` and the protocol knobs
- [ ] scoreboard choice fits the DUT (memory model or your own predictor)
- [ ] `check_phase` looks at `vif.viol_cnt` and at your scoreboard counters
- [ ] reset in the middle of traffic is tolerated (items return with `aborted = 1`)
