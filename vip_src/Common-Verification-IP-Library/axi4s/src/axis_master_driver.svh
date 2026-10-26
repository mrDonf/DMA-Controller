// -----------------------------------------------------------------------------
// axis_master_driver - AXI4-Stream transmitter
//   * packets are fetched ahead (early item_done); beats of consecutive packets follow each other without a gap when
//     delay[] / gap are 0 (TVALID stays high, TLAST marks the packet end)
//   * TVALID is held with a stable payload until TREADY; the payload carries junk while TVALID is low (cfg.drive_junk)
//   * reset: channel driven idle, packets in flight return aborted
//   * cfg.inject generates protocol violations to prove the checker (DROP_VALID, CHANGE_DATA, STRB_NO_KEEP, ID_CHANGE)
// -----------------------------------------------------------------------------
class axis_master_driver extends uvm_driver #(axis_item);
  `uvm_component_utils(axis_master_driver)
  protected bit [AXIS_KEEP_W-1:0] beat_st, beat_kp;      // TSTRB / TKEEP / TID of the beat on the bus
  protected bit [AXIS_ID_W-1:0]   beat_id;

  axis_agent_cfg cfg;
  axis_vif_t     vif;

  protected axis_item q[$];
  protected axis_item cur;
  protected axis_item inflight[$];
  protected int unsigned idx, wait_left, cyc_in_beat;
  protected bit driving;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    drive_idle();
    forever begin
      wait (vif.aresetn === 1'b1);
      fork
        engine();
        @(negedge vif.aresetn);
      join_any
      disable fork;
      #2ns;
      drive_idle();
      foreach (inflight[i]) begin
        inflight[i].aborted = 1'b1;
        seq_item_port.put_response(inflight[i]);
      end
      inflight.delete(); q.delete(); cur = null; driving = 0;
      do begin
        @(posedge vif.aclk);
        #2ns;
        drive_idle();
      end while (vif.aresetn !== 1'b1);
    end
  endtask

  protected task drive_idle();
    vif.tvalid <= 1'b0; vif.tlast <= 1'b0; vif.tdata <= '0; vif.tstrb <= '0; vif.tkeep <= '0; vif.tid <= '0; vif.tdest <= '0; vif.tuser <= '0;
  endtask

  protected function bit inject_now(axis_inject_e kind);
    return (cfg.inject == kind) && ($urandom_range(99) < cfg.inject_pct);
  endfunction

  protected task fetch();
    axis_item req;
    if (q.size() >= 2) return;
    seq_item_port.try_next_item(req);
    if (req == null) return;
    begin
      axis_item it;
      $cast(it, req.clone());
      it.set_id_info(req);
      seq_item_port.item_done();
      q.push_back(it);
      inflight.push_back(it);
    end
  endtask

  protected task engine();
    bit drop_done = 0;
    @(vif.mst_cb);
    forever begin
      if (driving) begin
        if (vif.mst_cb.tready === 1'b1) begin                       // beat accepted at this edge
          driving = 0; cyc_in_beat = 0;
          idx++;
          if (idx >= cur.data.size()) begin
            cur.end_time = $time;
            foreach (inflight[i]) if (inflight[i] == cur) begin inflight.delete(i); break; end
            seq_item_port.put_response(cur);
            cur = null;
          end else wait_left = cur.delay[idx];
        end else begin
          cyc_in_beat++;
          cur.stalls++;
          if (cyc_in_beat > cfg.timeout_cycles) begin
            `vip_error("AXIS_TIMEOUT", $sformatf("TREADY not seen within %0d cycles", cfg.timeout_cycles))
            cyc_in_beat = 0;
          end
        end
      end
      fetch();
      if (cur == null && q.size() != 0) begin
        cur = q.pop_front(); idx = 0; wait_left = cur.gap + cur.delay[0]; driving = 0; cyc_in_beat = 0;
      end
      if (cur != null) begin
        if (!driving && wait_left > 0) begin
          wait_left--;
          vif.mst_cb.tvalid <= 1'b0;
          if (cfg.drive_junk) begin
            vif.mst_cb.tdata <= AXIS_DATA_W'({(AXIS_DATA_W / 32 + 1){$urandom}});
            vif.mst_cb.tlast <= $urandom;
          end
        end else begin
          if (!driving) begin                                  // payload of this beat, held until TREADY (injections included)
            if (cur.start_time == 0 || idx == 0) cur.start_time = $time;
            beat_st = cur.strb[idx]; beat_kp = cur.keep[idx]; beat_id = cur.id;
            if (inject_now(AXIS_INJ_STRB_NO_KEEP)) begin
              if (beat_kp != '1) beat_st = beat_st | ~beat_kp;
              else begin beat_kp[0] = 1'b0; beat_st[0] = 1'b1; end   // full beat (e.g. 8-bit data): make byte 0 a null byte
            end
            if (inject_now(AXIS_INJ_ID_CHANGE) && idx > 0) beat_id = ~cur.id;
          end
          vif.mst_cb.tvalid <= 1'b1;
          vif.mst_cb.tdata <= cur.data[idx]; vif.mst_cb.tstrb <= beat_st; vif.mst_cb.tkeep <= beat_kp;
          vif.mst_cb.tlast <= (idx == cur.data.size() - 1);
          vif.mst_cb.tid <= beat_id; vif.mst_cb.tdest <= cur.dest; vif.mst_cb.tuser <= cur.user[idx];
          if (driving && cyc_in_beat == 1) begin
            if (inject_now(AXIS_INJ_DROP_VALID))   vif.mst_cb.tvalid <= 1'b0;                  // violation: VALID withdrawn
            if (inject_now(AXIS_INJ_CHANGE_DATA))  vif.mst_cb.tdata  <= ~cur.data[idx];         // violation: payload changes
          end
          driving = 1;
        end
      end else begin
        vif.mst_cb.tvalid <= 1'b0;
        if (cfg.drive_junk) begin
          vif.mst_cb.tdata <= AXIS_DATA_W'({(AXIS_DATA_W / 32 + 1){$urandom}});
          vif.mst_cb.tlast <= $urandom;
        end
      end
      @(vif.mst_cb);
    end
  endtask
endclass : axis_master_driver
