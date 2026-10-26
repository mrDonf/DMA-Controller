// axis_agent_cfg - configuration of one AXI4-Stream agent (uvm_config_db key "cfg")
class axis_agent_cfg extends uvm_object;
  `uvm_object_utils(axis_agent_cfg)

  axis_vif_t   vif;
  vip_role_e   role            = VIP_MASTER;
  bit          coverage_en     = 1'b1;
  bit          checks_en       = 1'b1;
  bit          check_keep_mid  = 1'b0;      // flag null bytes before the last beat of a packet
  int unsigned max_packet_beats = 0;        // 0 = unchecked
  int unsigned timeout_cycles = 4096;       // transmitter: TREADY must come within this many cycles

  // ---- transmitter knobs
  axis_inject_e inject        = AXIS_INJ_NONE;
  int unsigned  inject_pct    = 100;
  bit           drive_junk    = 1'b1;       // payload carries junk while TVALID is low

  // ---- receiver knobs
  axis_ready_e ready_mode     = AXIS_RDY_ALWAYS;
  int unsigned ready_pct      = 70;         // AXIS_RDY_RANDOM: probability (%) of TREADY per cycle
  int unsigned burst_on_max   = 8;          // AXIS_RDY_BURSTY: ready for 1..on_max cycles, then not ready for 1..off_max cycles
  int unsigned burst_off_max  = 8;

  function new(string name = "axis_agent_cfg");
    super.new(name);
  endfunction
endclass : axis_agent_cfg
