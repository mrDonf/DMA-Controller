// -----------------------------------------------------------------------------
// apb_monitor - passive observer: rebuilds transfers from the pins (independent of the driver)
//   ap          completed transfers (apb_item with response and wait states)
//   ap_setup    request seen at the end of SETUP (before the response is known)
//   counters    transfers, writes, reads, errors, wait states; checks the PREADY timeout
// -----------------------------------------------------------------------------
class apb_monitor extends uvm_monitor;
  `uvm_component_utils(apb_monitor)

  apb_agent_cfg cfg;
  apb_vif_t     vif;
  uvm_analysis_port #(apb_item) ap;
  uvm_analysis_port #(apb_item) ap_setup;
  uvm_analysis_port #(apb_item) ap_abort;      // transfers cut by a reset (their effect on the completer is undefined)

  int unsigned n_xfer, n_wr, n_rd, n_err, n_wait_cycles, n_b2b;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap       = new("ap", this);
    ap_setup = new("ap_setup", this);
    ap_abort = new("ap_abort", this);
  endfunction

  task run_phase(uvm_phase phase);
    apb_item cur = null;
    int unsigned waits = 0;
    time t_last_edge = 0, period = 0, t_prev_end = 0;
    bit  have_prev = 0;
    forever begin
      @(vif.mon_cb);
      if (t_last_edge != 0) period = $time - t_last_edge;
      t_last_edge = $time;
      if (vif.presetn !== 1'b1) begin
        if (cur != null) begin cur.aborted = 1'b1; ap_abort.write(cur); end
        cur = null; have_prev = 0; continue;
      end
      if (vif.mon_cb.psel === 1'b1 && vif.mon_cb.penable === 1'b0) begin          // SETUP phase just ended
        cur = apb_item::type_id::create("mon_item");
        cur.addr = vif.mon_cb.paddr;  cur.write = vif.mon_cb.pwrite; cur.prot = vif.mon_cb.pprot;
        cur.strb = vif.mon_cb.pstrb;  cur.start_time = $time;
        cur.data = vif.mon_cb.pwrite ? vif.mon_cb.pwdata : '0;
        waits = 0;
        // idle cycles since the previous completion (0 = back-to-back, PSEL stayed high)
        cur.idle = (have_prev && period != 0) ? int'((cur.start_time - t_prev_end) / period) - 1 : 1000;
        ap_setup.write(cur);
      end else if (cur != null && vif.mon_cb.psel === 1'b1 && vif.mon_cb.penable === 1'b1) begin
        if (vif.mon_cb.pready === 1'b1) begin                                     // ACCESS phase completes
          cur.slverr      = (vif.mon_cb.pslverr === 1'b1);
          cur.wait_cycles = waits;
          cur.end_time    = $time;
          if (!cur.write) cur.data = vif.mon_cb.prdata;
          n_xfer++; n_wait_cycles += waits;
          if (cur.write) n_wr++; else n_rd++;
          if (cur.slverr) n_err++;
          if (cur.idle == 0) n_b2b++;
          t_prev_end = cur.end_time; have_prev = 1;
          `vip_info("APB_MON", cur.convert2string(), UVM_HIGH)
          ap.write(cur);
          cur = null;
        end else begin
          waits++;
          if (cfg.checks_en && waits > cfg.timeout_cycles) begin
            `vip_error("APB_TIMEOUT", $sformatf("PREADY low for more than %0d cycles", cfg.timeout_cycles))
            cur = null;
          end
        end
      end else begin
        cur = null;                                                               // protocol break (the interface assertions report it)
      end
    end
  endtask

  function void report_phase(uvm_phase phase);
    `vip_info("APB_MON", $sformatf("transfers=%0d (wr=%0d rd=%0d) slverr=%0d wait_cycles=%0d protocol_violations=%0d",
              n_xfer, n_wr, n_rd, n_err, n_wait_cycles, vif.viol_cnt), UVM_LOW)
  endfunction
endclass : apb_monitor
