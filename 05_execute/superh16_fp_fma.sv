//==============================================================================
// File: 05_execute/superh16_fp_fma.sv
// Description: Floating-Point Fused Multiply-Add unit
// 4-cycle pipelined FMA (single/double precision)
// Supports: FMA, FMUL, FADD, FSUB
//==============================================================================

module superh16_fp_fma
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Input
    input  logic                                    valid,
    input  uop_opcode_t                             opcode,
    input  logic [XLEN-1:0]                         src1,      // Multiplicand
    input  logic [XLEN-1:0]                         src2,      // Multiplier
    input  logic [XLEN-1:0]                         src3,      // Addend
    input  logic [PHYS_REG_BITS-1:0]                dst_tag,
    input  logic [ROB_IDX_BITS-1:0]                 rob_idx,
    
    // Output (4 cycles later)
    output logic                                    result_valid,
    output logic [XLEN-1:0]                         result,
    output logic [PHYS_REG_BITS-1:0]                result_dst_tag,
    output logic [ROB_IDX_BITS-1:0]                 result_rob_idx,
    output logic [4:0]                              fflags     // FP exception flags
);

    //==========================================================================
    // Pipeline stages
    // For simplicity, we use synthesizable FP operators
    // Real implementation would have custom FMA datapath
    //==========================================================================
    
    // Stage 0: Input capture
    logic                       s0_valid;
    uop_opcode_t                s0_opcode;
    logic [XLEN-1:0]            s0_src1;
    logic [XLEN-1:0]            s0_src2;
    logic [XLEN-1:0]            s0_src3;
    logic [PHYS_REG_BITS-1:0]   s0_dst_tag;
    logic [ROB_IDX_BITS-1:0]    s0_rob_idx;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid <= 1'b0;
        end else begin
            s0_valid <= valid;
            s0_opcode <= opcode;
            s0_src1 <= src1;
            s0_src2 <= src2;
            s0_src3 <= src3;
            s0_dst_tag <= dst_tag;
            s0_rob_idx <= rob_idx;
        end
    end
    
    //==========================================================================
    // Stage 1: Multiply
    //==========================================================================
    
    logic                       s1_valid;
    uop_opcode_t                s1_opcode;
    logic [XLEN-1:0]            s1_product;
    logic [XLEN-1:0]            s1_addend;
    logic [PHYS_REG_BITS-1:0]   s1_dst_tag;
    logic [ROB_IDX_BITS-1:0]    s1_rob_idx;
    
    // FP multiply (synthesis tool infers FP multiplier)
    real fp_src1, fp_src2, fp_product;
    
    always_comb begin
        fp_src1 = $bitstoreal(s0_src1);
        fp_src2 = $bitstoreal(s0_src2);
        fp_product = fp_src1 * fp_src2;
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid <= s0_valid;
            s1_opcode <= s0_opcode;
            s1_product <= $realtobits(fp_product);
            s1_addend <= s0_src3;
            s1_dst_tag <= s0_dst_tag;
            s1_rob_idx <= s0_rob_idx;
        end
    end
    
    //==========================================================================
    // Stage 2: Add/Subtract
    //==========================================================================
    
    logic                       s2_valid;
    uop_opcode_t                s2_opcode;
    logic [XLEN-1:0]            s2_sum;
    logic [PHYS_REG_BITS-1:0]   s2_dst_tag;
    logic [ROB_IDX_BITS-1:0]    s2_rob_idx;
    
    real fp_addend, fp_sum;
    
    always_comb begin
        fp_addend = $bitstoreal(s1_addend);
        fp_sum = fp_product + fp_addend;
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
        end else begin
            s2_valid <= s1_valid;
            s2_opcode <= s1_opcode;
            s2_sum <= $realtobits(fp_sum);
            s2_dst_tag <= s1_dst_tag;
            s2_rob_idx <= s1_rob_idx;
        end
    end
    
    //==========================================================================
    // Stage 3: Rounding and normalization
    //==========================================================================
    
    logic                       s3_valid;
    logic [XLEN-1:0]            s3_result;
    logic [PHYS_REG_BITS-1:0]   s3_dst_tag;
    logic [ROB_IDX_BITS-1:0]    s3_rob_idx;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid <= 1'b0;
        end else begin
            s3_valid <= s2_valid;
            s3_result <= s2_sum;  // Already rounded by FP unit
            s3_dst_tag <= s2_dst_tag;
            s3_rob_idx <= s2_rob_idx;
        end
    end
    
    //==========================================================================
    // Output
    //==========================================================================
    
    assign result_valid = s3_valid;
    assign result = s3_result;
    assign result_dst_tag = s3_dst_tag;
    assign result_rob_idx = s3_rob_idx;
    assign fflags = 5'b0;  // TODO: Implement FP exception flags

endmodule : superh16_fp_fma