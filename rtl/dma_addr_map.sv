//-----------------------------------------------------------------------------
// dma_addr_map.sv  (IMPLEMENTER EDITABLE)
// Address -> AXI manager port mapping used when the secondary manager port
// (AXI5_M1_PRESENT = 1) exists (TRM 4.3.11). Return 1 to route a transfer to
// M1, 0 for M0. The function must be a pure function of the address.
//
// The default example routes the address window [M1_BASE, M1_BASE+M1_SIZE)
// to M1. Edit M1_BASE / M1_MASK or replace the function body as needed.
//-----------------------------------------------------------------------------
package dma_addr_map_pkg;

  localparam logic [63:0] M1_BASE = 64'h0000_0000_8000_0000;
  localparam logic [63:0] M1_MASK = 64'hFFFF_FFFF_8000_0000;   // 2GB window

  function automatic logic dma_port_sel(input logic [63:0] addr);
    return ((addr & M1_MASK) == M1_BASE);
  endfunction

endpackage : dma_addr_map_pkg
