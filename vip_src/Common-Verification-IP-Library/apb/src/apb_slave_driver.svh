// -----------------------------------------------------------------------------
// apb_slave_driver - APB completer with a sparse memory model
//
//   behaviour (all knobs in apb_agent_cfg):
//     * random wait states in [wait_min, wait_max]
//     * PSLVERR for addresses in [err_lo, err_hi], for unmapped addresses (unmapped_error) and randomly (err_pct %)
//     * writes are committed with byte strobes unless the transfer is answered with an error
//     * PRDATA carries junk while the completer inserts wait states (a requester must sample at the end only)
//   Override `respond()` (factory override) to model a register block instead of a memory.
// -----------------------------------------------------------------------------
class apb_slave_driver extends uvm_component;
  `uvm_component_utils(apb_slave_driver)

  apb_agent_cfg cfg;
  apb_vif_t     vif;
  uvm_analysis_port #(apb_item) ap_served;       // every transfer as seen by the completer (before the monitor)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap_served = new("ap_served", this);
  endfunction

  task run_phase(uvm_phase phase);
    set_defaults();
    forever begin
      wait (vif.presetn === 1'b1);
      fork
        serve_loop();
        @(negedge vif.presetn);
      join_any
      disable fork;
      set_defaults();
    end
  endtask

  protected task set_defaults();
    vif.pready  <= cfg.default_pready;
    vif.pslverr <= 1'b0;
    vif.prdata  <= '0;
  endtask

  protected task serve_loop();
    forever begin
      @(vif.slv_cb);
      if (vif.slv_cb.psel === 1'b1 && vif.slv_cb.penable === 1'b0) serve();
    end
  endtask

  // data / error decision for one transfer (default: memory model); `it.data` is the write data on entry and must hold the read data on exit
  virtual function void respond(apb_item it);
    bit [APB_ADDR_W-1:0] a_al = it.addr & ~APB_ADDR_W'(APB_STRB_W - 1);
    bit mapped = cfg.is_mapped(it.addr);
    it.slverr = cfg.in_err_window(it.addr) || (cfg.unmapped_error && !mapped) || ($urandom_range(99) < cfg.err_pct);
    if (it.write) begin
      if (!it.slverr && mapped) cfg.mem.write_le(longint'(a_al), it.data, APB_STRB_W, it.strb);
    end else begin
      it.data = it.slverr ? APB_DATA_W'(64'hBAD0_BAD0_BAD0_BAD0) : APB_DATA_W'(cfg.mem.read_le(longint'(a_al), APB_STRB_W));
    end
  endfunction

  protected task serve();
    apb_item it = apb_item::type_id::create("served");
    int unsigned n = $urandom_range(cfg.wait_max, cfg.wait_min);
    it.addr  = vif.slv_cb.paddr;
    it.write = vif.slv_cb.pwrite;
    it.data  = vif.slv_cb.pwdata;
    it.strb  = vif.slv_cb.pstrb;
    it.prot  = vif.slv_cb.pprot;
    it.start_time = $time;
    respond(it);
    it.wait_cycles = n;
    repeat (n) begin                                   // wait states
      vif.slv_cb.pready  <= 1'b0;
      vif.slv_cb.pslverr <= $urandom;                  // junk: only valid together with PREADY
      vif.slv_cb.prdata  <= $urandom;
      @(vif.slv_cb);
      if (vif.slv_cb.psel !== 1'b1) begin set_defaults(); return; end   // requester left (protocol violation or reset)
    end
    vif.slv_cb.pready  <= 1'b1;
    vif.slv_cb.pslverr <= it.slverr;
    vif.slv_cb.prdata  <= it.write ? APB_DATA_W'($urandom) : it.data;
    @(vif.slv_cb);                                     // the requester samples PREADY=1 at this edge
    vif.slv_cb.pready  <= cfg.default_pready;
    vif.slv_cb.pslverr <= 1'b0;
    vif.slv_cb.prdata  <= $urandom;
    it.end_time = $time;
    ap_served.write(it);
  endtask
endclass : apb_slave_driver
