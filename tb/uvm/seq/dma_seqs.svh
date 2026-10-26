//-----------------------------------------------------------------------------
// dma_seqs.svh - small helper sequences
//-----------------------------------------------------------------------------
// one AXI4-Stream packet from a byte queue (full beats, tail strobes on the
// last beat, random valid gaps)
class dma_axis_send_seq extends uvm_sequence #(axis_item);
  `uvm_object_utils(dma_axis_send_seq)
  byte unsigned payload[$];
  int unsigned  max_gap = 3;
  int unsigned  pct_gap = 30;
  int           bad_beat = -1;     // beat sent with an illegal (partial) TSTRB
  function new(string name = "dma_axis_send_seq"); super.new(name); endfunction
  task body();
    axis_item it = axis_item::type_id::create("pkt");
    int nb = (payload.size() + TB_DWB - 1) / TB_DWB;
    if (nb == 0) return;
    it.beats = nb;
    it.keep_mode = AXIS_KEEP_TAIL;
    it.data = new[nb]; it.keep = new[nb]; it.strb = new[nb]; it.user = new[nb]; it.delay = new[nb];
    it.id = 0; it.dest = 0; it.gap = 0;
    for (int b = 0; b < nb; b++) begin
      it.data[b] = '0; it.keep[b] = '0;
      for (int l = 0; l < TB_DWB; l++) begin
        int k = b * TB_DWB + l;
        if (k < payload.size()) begin
          it.data[b][8*l +: 8] = payload[k];
          it.keep[b][l] = 1'b1;
        end
      end
      if (b == bad_beat && b != nb - 1) it.keep[b] = it.keep[b] & {TB_DWB/2{1'b1}};
      it.strb[b]  = it.keep[b];
      it.user[b]  = '0;
      it.delay[b] = ($urandom_range(99) < pct_gap) ? $urandom_range(1, max_gap) : 0;
    end
    start_item(it);
    finish_item(it);
  endtask
endclass : dma_axis_send_seq
