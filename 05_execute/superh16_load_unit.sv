//==============================================================================
// File: 05_execute/superh16_load_unit.sv
// Description: Load unit with 4-cycle latency (L1 hit)
// Pipeline: Address Gen → TLB → Cache Tag → Cache Data → Alignment
//==============================================================================

module superh16_load_unit
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Input
    input  logic                                    valid,
    input  logic [XLEN-1:0]                         base_addr,
    input  logic [15:0]                             offset,
    input  logic [2:0]                              size,      // 0=byte, 1=half, 2=word, 3=double
    input  logic                                    sign_extend,
    input  logic [PHYS_REG_BITS-1:0]                dst_tag,
    input  logic [ROB_IDX_BITS-1:0]                 rob_idx,
    input  logic [LQ_IDX_BITS-1:0]                  lq_idx,
    
    // D-cache interface
    output logic                                    dcache_req,
    output logic [VADDR_WIDTH-1:0]                  dcache_addr,
    output logic [2:0]                              dcache_size,
    input  logic                                    dcache_ack,
    input  logic [XLEN-1:0]                         dcache_data,
    input  logic                                    dcache_miss,
    
    // D-TLB interface
    output logic                                    dtlb_req,
    output logic [VADDR_WIDTH-1:0]                  dtlb_vaddr,
    input  logic                                    dtlb_hit,
    input  logic [PADDR_WIDTH-1:0]                  dtlb_paddr,
    input  logic                                    dtlb_exception,
    input  logic [7:0]                              dtlb_exc_code,
    
    // Output
    output logic                                    result_valid,
    output logic [XLEN-1:0]                         result_data,
    output logic [PHYS_REG_BITS-1:0]                result_dst_tag,
    output logic [ROB_IDX_BITS-1:0]                 result_rob_idx,
    output logic [LQ_IDX_BITS-1:0]                  result_lq_idx,
    output logic                                    exception,
    output logic [7:0]                              exception_code,
    
    // Load queue interface (for forwarding from store queue)
    output logic                                    lq_probe_valid,
    output logic [VADDR_WIDTH-1:0]                  lq_probe_addr,
    output logic [2:0]                              lq_probe_size,
    input  logic                                    sq_forward_valid,
    input  logic [XLEN-1:0]                         sq_forward_data
);

    //==========================================================================
    // Pipeline Stage 0: Address Generation
    //==========================================================================
    
    logic                       s0_valid;
    logic [VADDR_WIDTH-1:0]     s0_vaddr;
    logic [2:0]                 s0_size;
    logic                       s0_sign_extend;
    logic [PHYS_REG_BITS-1:0]   s0_dst_tag;
    logic [ROB_IDX_BITS-1:0]    s0_rob_idx;
    logic [LQ_IDX_BITS-1:0]     s0_lq_idx;
    
    // Compute virtual address
    logic [VADDR_WIDTH-1:0] computed_vaddr;
    assign computed_vaddr = base_addr + {{48{offset[15]}}, offset};
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid <= 1'b0;
        end else begin
            s0_valid <= valid;
            s0_vaddr <= computed_vaddr;
            s0_size <= size;
            s0_sign_extend <= sign_extend;
            s0_dst_tag <= dst_tag;
            s0_rob_idx <= rob_idx;
            s0_lq_idx <= lq_idx;
        end
    end
    
    // Probe store queue for forwarding
    assign lq_probe_valid = s0_valid;
    assign lq_probe_addr = s0_vaddr;
    assign lq_probe_size = s0_size;
    
    //==========================================================================
    // Pipeline Stage 1: TLB Lookup
    //==========================================================================
    
    logic                       s1_valid;
    logic [VADDR_WIDTH-1:0]     s1_vaddr;
    logic [PADDR_WIDTH-1:0]     s1_paddr;
    logic [2:0]                 s1_size;
    logic                       s1_sign_extend;
    logic [PHYS_REG_BITS-1:0]   s1_dst_tag;
    logic [ROB_IDX_BITS-1:0]    s1_rob_idx;
    logic [LQ_IDX_BITS-1:0]     s1_lq_idx;
    logic                       s1_tlb_exception;
    logic [7:0]                 s1_tlb_exc_code;
    logic                       s1_sq_forwarded;
    logic [XLEN-1:0]            s1_sq_data;
    
    // TLB request
    assign dtlb_req = s0_valid;
    assign dtlb_vaddr = s0_vaddr;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid <= s0_valid;
            s1_vaddr <= s0_vaddr;
            s1_paddr <= dtlb_hit ? dtlb_paddr : '0;
            s1_size <= s0_size;
            s1_sign_extend <= s0_sign_extend;
            s1_dst_tag <= s0_dst_tag;
            s1_rob_idx <= s0_rob_idx;
            s1_lq_idx <= s0_lq_idx;
            s1_tlb_exception <= dtlb_exception;
            s1_tlb_exc_code <= dtlb_exc_code;
            s1_sq_forwarded <= sq_forward_valid;
            s1_sq_data <= sq_forward_data;
        end
    end
    
    //==========================================================================
    // Pipeline Stage 2: Cache Access
    //==========================================================================
    
    logic                       s2_valid;
    logic [2:0]                 s2_size;
    logic                       s2_sign_extend;
    logic [PHYS_REG_BITS-1:0]   s2_dst_tag;
    logic [ROB_IDX_BITS-1:0]    s2_rob_idx;
    logic [LQ_IDX_BITS-1:0]     s2_lq_idx;
    logic                       s2_exception;
    logic [7:0]                 s2_exc_code;
    logic [XLEN-1:0]            s2_cache_data;
    logic                       s2_cache_miss;
    logic                       s2_sq_forwarded;
    logic [XLEN-1:0]            s2_sq_data;
    
    // D-cache request (only if no TLB exception and not forwarded)
    assign dcache_req = s1_valid && !s1_tlb_exception && !s1_sq_forwarded;
    assign dcache_addr = s1_vaddr;
    assign dcache_size = s1_size;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
        end else begin
            s2_valid <= s1_valid;
            s2_size <= s1_size;
            s2_sign_extend <= s1_sign_extend;
            s2_dst_tag <= s1_dst_tag;
            s2_rob_idx <= s1_rob_idx;
            s2_lq_idx <= s1_lq_idx;
            s2_exception <= s1_tlb_exception;
            s2_exc_code <= s1_tlb_exc_code;
            s2_cache_data <= dcache_ack ? dcache_data : '0;
            s2_cache_miss <= dcache_miss;
            s2_sq_forwarded <= s1_sq_forwarded;
            s2_sq_data <= s1_sq_data;
        end
    end
    
    //==========================================================================
    // Pipeline Stage 3: Data Alignment and Sign Extension
    //==========================================================================
    
    logic                       s3_valid;
    logic [XLEN-1:0]            s3_aligned_data;
    logic [PHYS_REG_BITS-1:0]   s3_dst_tag;
    logic [ROB_IDX_BITS-1:0]    s3_rob_idx;
    logic [LQ_IDX_BITS-1:0]     s3_lq_idx;
    logic                       s3_exception;
    logic [7:0]                 s3_exc_code;
    
    // Select between cache data and forwarded data
    logic [XLEN-1:0] selected_data;
    assign selected_data = s2_sq_forwarded ? s2_sq_data : s2_cache_data;
    
    // Alignment and sign extension
    always_comb begin
        case (s2_size)
            3'b000: begin  // Byte
                if (s2_sign_extend) begin
                    s3_aligned_data = {{56{selected_data[7]}}, selected_data[7:0]};
                end else begin
                    s3_aligned_data = {56'd0, selected_data[7:0]};
                end
            end
            
            3'b001: begin  // Halfword
                if (s2_sign_extend) begin
                    s3_aligned_data = {{48{selected_data[15]}}, selected_data[15:0]};
                end else begin
                    s3_aligned_data = {48'd0, selected_data[15:0]};
                end
            end
            
            3'b010: begin  // Word
                if (s2_sign_extend) begin
                    s3_aligned_data = {{32{selected_data[31]}}, selected_data[31:0]};
                end else begin
                    s3_aligned_data = {32'd0, selected_data[31:0]};
                end
            end
            
            3'b011: begin  // Doubleword
                s3_aligned_data = selected_data;
            end
            
            default: begin
                s3_aligned_data = '0;
            end
        endcase
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid <= 1'b0;
        end else begin
            s3_valid <= s2_valid && !s2_cache_miss;  // Stall on cache miss
            s3_dst_tag <= s2_dst_tag;
            s3_rob_idx <= s2_rob_idx;
            s3_lq_idx <= s2_lq_idx;
            s3_exception <= s2_exception;
            s3_exc_code <= s2_exc_code;
        end
    end
    
    //==========================================================================
    // Output
    //==========================================================================
    
    assign result_valid = s3_valid;
    assign result_data = s3_aligned_data;
    assign result_dst_tag = s3_dst_tag;
    assign result_rob_idx = s3_rob_idx;
    assign result_lq_idx = s3_lq_idx;
    assign exception = s3_exception;
    assign exception_code = s3_exc_code;

endmodule : superh16_load_unit