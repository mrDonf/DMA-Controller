// -----------------------------------------------------------------------------
// APB sequence library
//   apb_base_seq        helpers write()/read()/xfer(); every derived sequence uses them
//   apb_write_seq       one write (addr/data/strb/prot as fields)
//   apb_read_seq        one read
//   apb_wr_rd_seq       n x { write random data, read it back, compare }          (needs a memory-like completer)
//   apb_burst_seq       n back-to-back transfers (idle = 0, PSEL stays high between them)
//   apb_strobe_seq      walks a single byte lane / patterns of PSTRB over one address and reads back
//   apb_rand_seq        n random transfers inside [lo, hi]
//   apb_error_seq       accesses inside an erroring window and checks that PSLVERR is reported
//   apb_reg_walk_seq    write / read-back of a list of registers with a mask (DUT bring-up)
// The sequences work on any sequencer of type apb_sequencer; the response of every item is collected.
// -----------------------------------------------------------------------------
class apb_base_seq extends uvm_sequence #(apb_item);
  `uvm_object_utils(apb_base_seq)

  int unsigned n_mismatch;                      // read-back mismatches found by the sequence

  function new(string name = "apb_base_seq");
    super.new(name);
    set_response_queue_depth(-1);                // a sequence may queue many items before it collects the responses
  endfunction

  // blocking transfer: queue the item and wait for the response (read data, PSLVERR, wait states)
  task xfer(apb_item it);
    apb_item r;
    start_item(it);
    finish_item(it);
    get_response(r);
    it.data = r.data; it.slverr = r.slverr; it.wait_cycles = r.wait_cycles; it.aborted = r.aborted;
  endtask

  task write(bit [APB_ADDR_W-1:0] addr, bit [APB_DATA_W-1:0] data, output bit err,
             input bit [APB_STRB_W-1:0] strb = {APB_STRB_W{1'b1}}, input bit [2:0] prot = 3'b000, input int unsigned idle = 0);
    apb_item it = apb_item::type_id::create("wr");
    start_item(it);
    if (!it.randomize() with { write == 1; addr == local::addr; data == local::data; strb == local::strb; prot == local::prot; idle == local::idle; })
      `vip_fatal("APB_SEQ", "randomize failed")
    finish_item(it);
    get_response(it);
    err = it.slverr;
  endtask

  task read(bit [APB_ADDR_W-1:0] addr, output bit [APB_DATA_W-1:0] data, output bit err,
            input bit [2:0] prot = 3'b000, input int unsigned idle = 0);
    apb_item it = apb_item::type_id::create("rd");
    apb_item r;
    start_item(it);
    if (!it.randomize() with { write == 0; addr == local::addr; prot == local::prot; idle == local::idle; })
      `vip_fatal("APB_SEQ", "randomize failed")
    finish_item(it);
    get_response(r);
    data = r.data; err = r.slverr;
  endtask
endclass : apb_base_seq

// apb_api_seq - a sequence that stays alive so that a test (or another component) can call write() / read() on it
//   from any thread:   api.set_sequencer(sqr); fork api.start(sqr); join_none;  ...  api.write(a, d, err);
class apb_api_seq extends apb_base_seq;
  `uvm_object_utils(apb_api_seq)
  bit stop;
  function new(string name = "apb_api_seq"); super.new(name); endfunction
  task body(); wait (stop); endtask
endclass : apb_api_seq

class apb_write_seq extends apb_base_seq;
  `uvm_object_utils(apb_write_seq)
  rand bit [APB_ADDR_W-1:0] addr;
  rand bit [APB_DATA_W-1:0] data;
  rand bit [APB_STRB_W-1:0] strb = {APB_STRB_W{1'b1}};
  rand bit [2:0]            prot = 3'b000;
  bit err;
  function new(string name = "apb_write_seq"); super.new(name); endfunction
  task body(); write(addr, data, err, strb, prot); endtask
endclass : apb_write_seq

class apb_read_seq extends apb_base_seq;
  `uvm_object_utils(apb_read_seq)
  rand bit [APB_ADDR_W-1:0] addr;
  rand bit [2:0]            prot = 3'b000;
  bit [APB_DATA_W-1:0] data;
  bit err;
  function new(string name = "apb_read_seq"); super.new(name); endfunction
  task body(); read(addr, data, err, prot); endtask
endclass : apb_read_seq

class apb_wr_rd_seq extends apb_base_seq;
  `uvm_object_utils(apb_wr_rd_seq)
  rand int unsigned n = 16;
  rand bit [APB_ADDR_W-1:0] lo = 0;
  rand bit [APB_ADDR_W-1:0] hi = 'hFFF;
  constraint c_n  { n inside {[1:1000]}; }
  constraint c_rg { lo <= hi; }
  function new(string name = "apb_wr_rd_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      bit [APB_ADDR_W-1:0] a;
      bit [APB_DATA_W-1:0] d, q;
      bit e;
      a = lo + ($urandom % (hi - lo + 1));
      a = a & ~APB_ADDR_W'(APB_STRB_W - 1);
      d = {$urandom, $urandom};
      write(a, d, e, '1, 0, $urandom_range(3));
      read(a, q, e, 0, $urandom_range(3));
      if (!e && q !== d) begin
        n_mismatch++;
        `vip_error("APB_SEQ_MISMATCH", $sformatf("addr 0x%0h wrote 0x%0h read 0x%0h", a, d, q))
      end
    end
  endtask
endclass : apb_wr_rd_seq

class apb_burst_seq extends apb_base_seq;
  `uvm_object_utils(apb_burst_seq)
  rand int unsigned n = 8;
  rand bit [APB_ADDR_W-1:0] base;
  rand bit write_burst;
  constraint c_n { n inside {[2:64]}; }
  function new(string name = "apb_burst_seq"); super.new(name); endfunction
  task body();
    apb_item q[$];
    apb_item r;
    for (int i = 0; i < n; i++) begin                 // queue everything first: the driver sees the next item at once
      apb_item it = apb_item::type_id::create($sformatf("b%0d", i));
      start_item(it);
      if (!it.randomize() with { write == write_burst; addr == base + i * APB_STRB_W; idle == 0; })
        `vip_fatal("APB_SEQ", "randomize failed")
      finish_item(it);
      q.push_back(it);
    end
    foreach (q[i]) begin                              // then collect the responses
      get_response(r);
      q[i].data = r.data; q[i].slverr = r.slverr;
    end
  endtask
endclass : apb_burst_seq

class apb_strobe_seq extends apb_base_seq;
  `uvm_object_utils(apb_strobe_seq)
  rand bit [APB_ADDR_W-1:0] addr;
  function new(string name = "apb_strobe_seq"); super.new(name); endfunction
  task body();
    bit [APB_DATA_W-1:0] q, expd;
    bit e;
    expd = '0;
    write(addr, '0, e, '1);                           // clear
    for (int lane = 0; lane < APB_STRB_W; lane++) begin
      bit [APB_DATA_W-1:0] d = {$urandom, $urandom};
      write(addr, d, e, APB_STRB_W'(1) << lane);      // only this byte lane may change
      expd[8*lane +: 8] = d[8*lane +: 8];
    end
    read(addr, q, e);
    if (e) `vip_error("APB_SEQ_ERR", "unexpected PSLVERR in the strobe walk")
    else if (q !== expd) begin
      n_mismatch++;
      `vip_error("APB_SEQ_MISMATCH", $sformatf("strobe walk at 0x%0h: read 0x%0h expected 0x%0h", addr, q, expd))
    end
  endtask
endclass : apb_strobe_seq

class apb_rand_seq extends apb_base_seq;
  `uvm_object_utils(apb_rand_seq)
  rand int unsigned n = 50;
  rand bit [APB_ADDR_W-1:0] lo = 0;
  rand bit [APB_ADDR_W-1:0] hi = 'hFFFF;
  constraint c_n { n inside {[1:2000]}; lo <= hi; }
  function new(string name = "apb_rand_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      apb_item it = apb_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with { addr >= lo; addr <= hi; prot inside {[0:7]}; })
        `vip_fatal("APB_SEQ", "randomize failed")
      finish_item(it);
      get_response(it);
    end
  endtask
endclass : apb_rand_seq

class apb_error_seq extends apb_base_seq;
  `uvm_object_utils(apb_error_seq)
  bit [APB_ADDR_W-1:0] err_addr;                       // address that must answer PSLVERR
  bit [APB_ADDR_W-1:0] ok_addr;                        // address that must answer OKAY
  int unsigned n_err_seen;
  function new(string name = "apb_error_seq"); super.new(name); endfunction
  task body();
    bit e;
    bit [APB_DATA_W-1:0] d;
    write(err_addr, APB_DATA_W'(32'hDEAD_BEEF), e);  if (!e) `vip_error("APB_SEQ_ERR", "write to the error window did not report PSLVERR") else n_err_seen++;
    read(err_addr, d, e);               if (!e) `vip_error("APB_SEQ_ERR", "read from the error window did not report PSLVERR") else n_err_seen++;
    write(ok_addr, APB_DATA_W'(32'h1234_5678), e);   if (e)  `vip_error("APB_SEQ_ERR", "unexpected PSLVERR on a normal address")
    read(ok_addr, d, e);                if (e || d !== APB_DATA_W'(32'h1234_5678)) `vip_error("APB_SEQ_ERR", "read-back after an error access is wrong")
  endtask
endclass : apb_error_seq

// write a pattern into every register of the list and read it back; `mask` = bits that are implemented
class apb_reg_walk_seq extends apb_base_seq;
  `uvm_object_utils(apb_reg_walk_seq)
  bit [APB_ADDR_W-1:0] addrs[$];
  bit [APB_DATA_W-1:0] masks[$];
  function new(string name = "apb_reg_walk_seq"); super.new(name); endfunction
  function void add(bit [APB_ADDR_W-1:0] a, bit [APB_DATA_W-1:0] mask = '1);
    addrs.push_back(a); masks.push_back(mask);
  endfunction
  task body();
    bit [APB_DATA_W-1:0] pat[4] = '{'0, '1, {(APB_DATA_W/2){2'b10}}, {(APB_DATA_W/2){2'b01}}};
    foreach (addrs[i]) foreach (pat[k]) begin
      bit [APB_DATA_W-1:0] q;
      bit e;
      write(addrs[i], pat[k], e);
      read(addrs[i], q, e);
      if (e) `vip_error("APB_SEQ_ERR", $sformatf("PSLVERR at 0x%0h", addrs[i]))
      else if ((q & masks[i]) !== (pat[k] & masks[i])) begin
        n_mismatch++;
        `vip_error("APB_SEQ_MISMATCH", $sformatf("reg 0x%0h wrote 0x%0h read 0x%0h (mask 0x%0h)", addrs[i], pat[k], q, masks[i]))
      end
    end
  endtask
endclass : apb_reg_walk_seq
