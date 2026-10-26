// -----------------------------------------------------------------------------
// axis_monitor - passive: rebuilds packets from accepted beats (independent of the drivers)
//   ap         one axis_item per packet (published at the TLAST beat)
//   ap_abort   partial packets cut by a reset; one marker item (aborted, no beats) per reset assertion
//   gap        idle cycles (no accepted beat) between the end of the previous packet and the first beat of this one
// -----------------------------------------------------------------------------
class axis_monitor extends uvm_monitor;
  `uvm_component_utils(axis_monitor)

  axis_agent_cfg cfg;
  axis_vif_t     vif;
  uvm_analysis_port #(axis_item) ap;
  uvm_analysis_port #(axis_item) ap_abort;

  int unsigned n_pkt, n_beat, n_bytes, n_stall_cycles, n_resets;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap       = new("ap", this);
    ap_abort = new("ap_abort", this);
  endfunction

  task run_phase(uvm_phase phase);
    axis_item cur = null;
    int unsigned idle_run = 100;
    int unsigned stall_cnt = 0;
    bit in_reset = 1'b0;
    forever begin
      @(vif.mon_cb);
      if (vif.aresetn !== 1'b1) begin
        if (!in_reset) begin
          axis_item m = axis_item::type_id::create("reset_marker");
          m.aborted = 1'b1;
          if (cur != null) begin cur.aborted = 1'b1; ap_abort.write(cur); end
          ap_abort.write(m);
          n_resets++;
        end
        in_reset = 1'b1; cur = null; idle_run = 100; stall_cnt = 0;
        continue;
      end
      in_reset = 1'b0;
      if (vif.mon_cb.tvalid === 1'b1 && vif.mon_cb.tready !== 1'b1) begin stall_cnt++; n_stall_cycles++; end
      if (vif.mon_cb.tvalid === 1'b1 && vif.mon_cb.tready === 1'b1) begin
        int unsigned k;
        if (cur == null) begin
          cur = axis_item::type_id::create("mon_pkt");
          cur.id = vif.mon_cb.tid; cur.dest = vif.mon_cb.tdest; cur.start_time = $time; cur.gap = idle_run; cur.stalls = 0;
          cur.data = new[0]; cur.keep = new[0]; cur.strb = new[0]; cur.user = new[0]; cur.delay = new[0];
        end
        k = cur.data.size();
        cur.data = new[k + 1](cur.data); cur.keep = new[k + 1](cur.keep); cur.strb = new[k + 1](cur.strb);
        cur.user = new[k + 1](cur.user); cur.delay = new[k + 1](cur.delay);
        cur.data[k] = vif.mon_cb.tdata; cur.keep[k] = vif.mon_cb.tkeep; cur.strb[k] = vif.mon_cb.tstrb; cur.user[k] = vif.mon_cb.tuser;
        cur.delay[k] = stall_cnt;                    // stall cycles this beat suffered
        cur.stalls += stall_cnt;
        stall_cnt = 0;
        n_beat++;
        idle_run = 0;
        if (vif.mon_cb.tlast === 1'b1) begin
          cur.beats = cur.data.size();
          cur.end_time = $time;
          n_pkt++; n_bytes += cur.num_data_bytes();
          `vip_info("AXIS_MON", cur.convert2string(), UVM_HIGH)
          ap.write(cur);
          cur = null;
        end
      end else idle_run++;
    end
  endtask

  function void report_phase(uvm_phase phase);
    `vip_info("AXIS_MON", $sformatf("packets=%0d beats=%0d data bytes=%0d stall cycles=%0d resets=%0d violations=%0d",
              n_pkt, n_beat, n_bytes, n_stall_cycles, n_resets, vif.viol_cnt), UVM_LOW)
  endfunction
endclass : axis_monitor
