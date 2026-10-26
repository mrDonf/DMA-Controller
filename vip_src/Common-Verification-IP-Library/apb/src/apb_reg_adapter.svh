// apb_reg_adapter - uvm_reg_adapter for the APB sequencer (register layer: bus2reg / reg2bus)
class apb_reg_adapter extends uvm_reg_adapter;
  `uvm_object_utils(apb_reg_adapter)

  function new(string name = "apb_reg_adapter");
    super.new(name);
    supports_byte_enable = 1;
    provides_responses   = 1;
  endfunction

  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    apb_item t = apb_item::type_id::create("reg_item");
    t.addr  = rw.addr;
    t.write = (rw.kind == UVM_WRITE);
    t.data  = rw.data;
    t.strb  = t.write ? ((rw.byte_en == '0) ? {APB_STRB_W{1'b1}} : APB_STRB_W'(rw.byte_en)) : '0;
    t.prot  = 3'b000;
    t.idle  = 0;
    return t;
  endfunction

  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
    apb_item t;
    if (!$cast(t, bus_item)) `vip_fatal("APB_ADAPT", "bus_item is not an apb_item")
    rw.kind   = t.write ? UVM_WRITE : UVM_READ;
    rw.addr   = t.addr;
    rw.data   = t.data;
    rw.status = t.slverr ? UVM_NOT_OK : UVM_IS_OK;
  endfunction
endclass : apb_reg_adapter
