// apb_item - one APB transfer (request fields are randomised, response fields are filled by driver / monitor)
class apb_item extends uvm_sequence_item;
  rand bit [APB_ADDR_W-1:0] addr;
  rand bit                  write;
  rand bit [APB_DATA_W-1:0] data;          // write data (requests) / read data (after the transfer)
  rand bit [APB_STRB_W-1:0] strb;
  rand bit [2:0]            prot;
  rand int unsigned         idle;          // idle cycles inserted before the transfer

  // response / observation
  bit          slverr;
  int unsigned wait_cycles;                // wait states seen in the access phase
  time         start_time;                 // time of the SETUP phase
  time         end_time;                   // time of the last ACCESS cycle
  bit          aborted;                    // reset hit the transfer

  `uvm_object_utils(apb_item)

  constraint c_strb_rd   { !write -> strb == '0; }
  constraint c_strb_wr   { write -> strb != '0; }
  constraint c_align     { soft (addr % APB_STRB_W) == 0; }
  constraint c_idle      { idle dist { 0 := 60, [1:3] := 30, [4:10] := 10 }; }
  constraint c_prot      { soft prot == 3'b000; }

  function new(string name = "apb_item");
    super.new(name);
  endfunction

  // write data with the masked lanes cleared (what a memory holds after the write, relative to 0)
  function bit [APB_DATA_W-1:0] strobed_data();
    bit [APB_DATA_W-1:0] r = '0;
    for (int i = 0; i < APB_STRB_W; i++) if (strb[i]) r[8*i +: 8] = data[8*i +: 8];
    return r;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    apb_item r;
    super.do_copy(rhs);
    if (!$cast(r, rhs)) `vip_fatal("APB_ITEM", "do_copy: type mismatch")
    addr = r.addr; write = r.write; data = r.data; strb = r.strb; prot = r.prot; idle = r.idle;
    slverr = r.slverr; wait_cycles = r.wait_cycles; start_time = r.start_time; end_time = r.end_time; aborted = r.aborted;
  endfunction

  virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
    apb_item r;
    if (!$cast(r, rhs)) return 0;
    return super.do_compare(rhs, comparer) && addr == r.addr && write == r.write && data == r.data &&
           strb == r.strb && prot == r.prot && slverr == r.slverr;
  endfunction

  virtual function string convert2string();
    return $sformatf("%s addr=0x%0h data=0x%0h strb=%b prot=%0d idle=%0d wait=%0d%s%s", write ? "WR" : "RD", addr, data,
                     strb, prot, idle, wait_cycles, slverr ? " SLVERR" : "", aborted ? " ABORTED" : "");
  endfunction
endclass : apb_item
