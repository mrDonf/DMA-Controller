// -----------------------------------------------------------------------------
// apb_master_driver - APB requester
//
//   * pipelined sequencer handshake: the item is acknowledged (item_done) as soon as it is taken and the result
//     (read data, PSLVERR, wait states) comes back as a response item. A sequence that queues the next item before it
//     collects the response therefore produces true back-to-back transfers (PSEL stays high, new SETUP right after the
//     last ACCESS cycle). apb_base_seq::xfer() hides this for ordinary use.
//   * asynchronous reset: the bus is driven idle, the transfer in flight is returned with aborted=1.
//   * optional protocol-violation injection (cfg.inject) to prove that the interface assertions fire.
// -----------------------------------------------------------------------------
class apb_master_driver extends uvm_driver #(apb_item);
  `uvm_component_utils(apb_master_driver)

  apb_agent_cfg cfg;
  apb_vif_t     vif;
  protected apb_item cur;
  protected bit      in_flight;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    drive_idle_bus();
    forever begin
      wait (vif.presetn === 1'b1);
      fork
        main_loop();
        begin
          @(negedge vif.presetn);
          `vip_info("APB_MST", "reset asserted: transfer aborted", UVM_MEDIUM)
        end
      join_any
      disable fork;
      drive_idle_bus();
      // clocking-block drives of the killed process may still be scheduled (they land up to one clock + skew later):
      // wait until the reset is over, let them land, then overwrite them
      do begin
        @(posedge vif.pclk);
        #2ns;
        drive_idle_bus();
      end while (vif.presetn !== 1'b1);
      if (in_flight) begin
        cur.aborted = 1'b1;
        seq_item_port.put_response(cur);
        in_flight = 1'b0;
      end
    end
  endtask

  protected task drive_idle_bus();
    vif.psel    <= 1'b0;
    vif.penable <= 1'b0;
    vif.pwrite  <= 1'b0;
    vif.paddr   <= '0;
    vif.pwdata  <= '0;
    vif.pstrb   <= '0;
    vif.pprot   <= '0;
  endtask

  protected task main_loop();
    apb_item req;
    @(vif.mst_cb);                              // clocking-block drives must start on a clock edge (else SETUP and ACCESS merge)
    forever begin
      seq_item_port.try_next_item(req);
      if (req == null) begin
        vif.mst_cb.psel    <= 1'b0;
        vif.mst_cb.penable <= 1'b0;
        @(vif.mst_cb);
        continue;
      end
      $cast(cur, req.clone());
      cur.set_id_info(req);
      in_flight = 1'b1;
      seq_item_port.item_done();                 // early acknowledge: allows the sequence to queue the next item
      drive_item(cur);
      seq_item_port.put_response(cur);
      in_flight = 1'b0;
    end
  endtask

  protected function bit inject_now(apb_inject_e kind);
    return (cfg.inject == kind) && ($urandom_range(99) < cfg.inject_pct);
  endfunction

  protected task drive_item(apb_item it);
    bit inj_noacc, inj_early, inj_addr, inj_strb;
    int unsigned cycles;
    inj_noacc = inject_now(APB_INJ_NO_ACCESS);
    inj_early = inject_now(APB_INJ_EARLY_PENABLE);
    inj_addr  = inject_now(APB_INJ_ADDR_CHANGE);
    inj_strb  = inject_now(APB_INJ_STRB_ON_READ) && !it.write;

    if (it.idle > 0) begin                       // idle gap: release the bus first
      vif.mst_cb.psel    <= 1'b0;
      vif.mst_cb.penable <= 1'b0;
      repeat (it.idle) @(vif.mst_cb);
    end

    // ---- SETUP phase
    it.start_time = $time;
    vif.mst_cb.paddr   <= it.addr;
    vif.mst_cb.pwrite  <= it.write;
    vif.mst_cb.pprot   <= it.prot;
    vif.mst_cb.pwdata  <= it.write ? it.data : $urandom;      // read: data lines carry junk, the completer must ignore them
    vif.mst_cb.pstrb   <= inj_strb ? '1 : (it.write ? it.strb : '0);
    vif.mst_cb.psel    <= 1'b1;
    vif.mst_cb.penable <= inj_early;
    @(vif.mst_cb);

    if (inj_noacc) begin                         // violation: leave the transfer after SETUP
      vif.mst_cb.psel    <= 1'b0;
      vif.mst_cb.penable <= 1'b0;
      @(vif.mst_cb);
      return;
    end

    // ---- ACCESS phase
    vif.mst_cb.penable <= 1'b1;
    if (inj_addr) vif.mst_cb.paddr <= ~it.addr;  // violation: address changes while waiting
    cycles = 0;
    forever begin
      @(vif.mst_cb);
      if (vif.mst_cb.pready === 1'b1) break;
      cycles++;
      if (cycles > cfg.timeout_cycles) begin
        `vip_error("APB_TIMEOUT", $sformatf("PREADY not seen within %0d cycles: %s", cfg.timeout_cycles, it.convert2string()))
        break;
      end
    end
    it.wait_cycles = cycles;
    it.slverr      = (vif.mst_cb.pslverr === 1'b1);
    if (!it.write) it.data = vif.mst_cb.prdata;
    it.end_time    = $time;
  endtask
endclass : apb_master_driver
