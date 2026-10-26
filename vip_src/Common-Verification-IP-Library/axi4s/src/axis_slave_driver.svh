// -----------------------------------------------------------------------------
// axis_slave_driver - AXI4-Stream receiver: drives TREADY according to cfg.ready_mode
//   ALWAYS | RANDOM (ready_pct) | TOGGLE | BURSTY (on/off runs of random length) | AFTER_VALID (ready only after TVALID was seen) | NEVER
//   cfg.ready_mode may be changed during the simulation (a test can create congestion phases).
// -----------------------------------------------------------------------------
class axis_slave_driver extends uvm_component;
  `uvm_component_utils(axis_slave_driver)

  axis_agent_cfg cfg;
  axis_vif_t     vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    vif.tready <= 1'b0;
    forever begin
      wait (vif.aresetn === 1'b1);
      fork
        engine();
        @(negedge vif.aresetn);
      join_any
      disable fork;
      #2ns;
      vif.tready <= 1'b0;
    end
  endtask

  protected task engine();
    bit rdy = 1'b0;
    int unsigned run_left = 0;
    bit seen_valid = 1'b0;
    @(vif.slv_cb);
    forever begin
      case (cfg.ready_mode)
        AXIS_RDY_ALWAYS: rdy = 1'b1;
        AXIS_RDY_NEVER:  rdy = 1'b0;
        AXIS_RDY_RANDOM: rdy = ($urandom_range(99) < cfg.ready_pct);
        AXIS_RDY_TOGGLE: rdy = ~rdy;
        AXIS_RDY_BURSTY: begin
          if (run_left == 0) begin
            rdy = ~rdy;
            run_left = rdy ? $urandom_range(cfg.burst_on_max, 1) : $urandom_range(cfg.burst_off_max, 1);
          end
          run_left--;
        end
        AXIS_RDY_AFTER_VALID: begin
          if (vif.slv_cb.tvalid === 1'b1) seen_valid = 1'b1;
          if (rdy && vif.slv_cb.tvalid === 1'b1) seen_valid = 1'b0;          // accepted this beat, wait for the next TVALID
          rdy = seen_valid;
        end
      endcase
      vif.slv_cb.tready <= rdy;
      @(vif.slv_cb);
    end
  endtask
endclass : axis_slave_driver
