//==============================================================================
// File: 05_execute/superh16_store_unit.sv
// Description: Store unit - computes address and writes to store queue
// Actual D-cache write happens at commit time
//==============================================================================

module superh16_store_unit
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Input
    input  logic                                    valid,
    input  logic [XLEN-1:0]                         base_addr,
    input  logic [15:0]                             offset,
    input  logic [XLEN-1:0]                         store_data,
    input  logic [2:0]                              size,
    input  logic [ROB_IDX_BITS-1:0]                 rob_idx,
    
    // Store queue interface
    output logic                                    sq_alloc,
    output logic [VADDR_WIDTH-1:0]                  sq_addr,
    output logic [XLEN-1:0]                         sq_data,
    output logic [2:0]                              sq_size,
    output logic [ROB_IDX_BITS-1:0]                 sq_rob_idx,
    input  logic                                    sq_full,
    
    // D-TLB interface
    output logic                                    dtlb_req,
    output logic [VADDR_WIDTH-1:0]                  dtlb_vaddr,
    input  logic                                    dtlb_hit,
    input  logic [PADDR_WIDTH-1:0]                  dtlb_paddr,
    input  logic                                    dtlb_exception,
    input  logic [7:0]                              dtlb_exc_code,
    
    // Completion signal
    output logic                                    complete_valid,
    output logic [ROB_IDX_BITS-1:0]                 complete_rob_idx,
    output logic                                    exception,
    output logic [7:0]                              exception_code
);

    //==========================================================================
    // Stage 0: Address Generation
    //==========================================================================
    
    logic [VADDR_WIDTH-1:0] computed_vaddr;
    assign computed_vaddr = base_addr + {{48{offset[15]}}, offset};
    
    logic                       s0_valid;
    logic [VADDR_WIDTH-1:0]     s0_vaddr;
    logic [XLEN-1:0]            s0_data;
    logic [2:0]                 s0_size;
    logic [ROB_IDX_BITS-1:0]    s0_rob_idx;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid <= 1'b0;
        end else begin
            s0_valid <= valid && !sq_full;
            s0_vaddr <= computed_vaddr;
            s0_data <= store_data;
            s0_size <= size;
            s0_rob_idx <= rob_idx;
        end
    end
    
    //==========================================================================
    // Stage 1: TLB Lookup
    //==========================================================================
    
    logic                       s1_valid;
    logic [VADDR_WIDTH-1:0]     s1_vaddr;
    logic [PADDR_WIDTH-1:0]     s1_paddr;
    logic [XLEN-1:0]            s1_data;
    logic [2:0]                 s1_size;
    logic [ROB_IDX_BITS-1:0]    s1_rob_idx;
    logic                       s1_tlb_exception;
    logic [7:0]                 s1_tlb_exc_code;
    
    assign dtlb_req = s0_valid;
    assign dtlb_vaddr = s0_vaddr;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid <= s0_valid;
            s1_vaddr <= s0_vaddr;
            s1_paddr <= dtlb_hit ? dtlb_paddr : '0;
            s1_data <= s0_data;
            s1_size <= s0_size;
            s1_rob_idx <= s0_rob_idx;
            s1_tlb_exception <= dtlb_exception;
            s1_tlb_exc_code <= dtlb_exc_code;
        end
    end
    
    //==========================================================================
    // Stage 2: Write to Store Queue
    //==========================================================================
    
    assign sq_alloc = s1_valid && !s1_tlb_exception;
    assign sq_addr = s1_vaddr;
    assign sq_data = s1_data;
    assign sq_size = s1_size;
    assign sq_rob_idx = s1_rob_idx;
    
    // Store completes immediately (actual cache write at commit)
    assign complete_valid = s1_valid;
    assign complete_rob_idx = s1_rob_idx;
    assign exception = s1_tlb_exception;
    assign exception_code = s1_tlb_exc_code;

endmodule : superh16_store_unit