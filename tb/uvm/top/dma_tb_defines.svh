//-----------------------------------------------------------------------------
// dma_tb_defines.svh - DUT build configuration of the UVM test bench.
// Override with +define+ at compile time (scripts/run_sim.py build variants).
//-----------------------------------------------------------------------------
`ifndef DMA_TB_DEFINES_SVH
`define DMA_TB_DEFINES_SVH

`ifndef DMA_NUM_CH
  `define DMA_NUM_CH 4
`endif
`ifndef DMA_AW
  `define DMA_AW 32
`endif
`ifndef DMA_DW
  `define DMA_DW 64
`endif
`ifndef DMA_CHID_W
  `define DMA_CHID_W 4
`endif
`ifndef DMA_GPO_W
  `define DMA_GPO_W 8
`endif
`ifndef DMA_GPO_MASK
  `define DMA_GPO_MASK 8'h0F
`endif
`ifndef DMA_STREAM_MASK
  `define DMA_STREAM_MASK 8'h03
`endif
`ifndef DMA_EXT_MASK
  `define DMA_EXT_MASK 8'hFF
`endif
`ifndef DMA_FIFO_D0
  `define DMA_FIFO_D0 16
`endif
`ifndef DMA_FIFO_D1
  `define DMA_FIFO_D1 8
`endif
`ifndef DMA_FIFO_D2
  `define DMA_FIFO_D2 32
`endif
`ifndef DMA_FIFO_D3
  `define DMA_FIFO_D3 4
`endif
`ifndef DMA_NTI
  `define DMA_NTI 4
`endif
`ifndef DMA_NTO
  `define DMA_NTO 4
`endif
`ifndef DMA_M1
  `define DMA_M1 1
`endif
`ifndef DMA_SECEXT
  `define DMA_SECEXT 1
`endif
`ifndef DMA_TI_SYNC
  `define DMA_TI_SYNC 32'hFFFF_FFFF
`endif
`ifndef DMA_TO_SYNC
  `define DMA_TO_SYNC 32'hFFFF_FFFF
`endif

// VIP widths (AXI5_ADDR_W, AXI5_DATA_W, AXI5_ID_W, APB_ADDR_W, AXIS_DATA_W) are
// passed on the vlog command line by scripts/run_sim.py so that the VIP
// packages and the DUT always agree.

`endif
