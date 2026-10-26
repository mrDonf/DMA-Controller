class axis_sequencer extends uvm_sequencer #(axis_item);
  `uvm_component_utils(axis_sequencer)
  axis_agent_cfg cfg;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass : axis_sequencer
