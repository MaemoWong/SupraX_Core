//==============================================================================
// File: 05_execute/superh16_int_mul.sv
// Description: Integer multiplier (3-cycle pipelined)
// Radix-4 Booth encoding with Wallace tree reduction
//==============================================================================

module superh16_int_mul
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Input operands
    input  logic                                    valid,
    input  uop_opcode_t                             opcode,
    input  logic [XLEN-1:0]                         src1,
    input  logic [XLEN-1:0]                         src2,
    input  logic [PHYS_REG_BITS-1:0]                dst_tag,
    input  logic [ROB_IDX_BITS-1:0]                 rob_idx,
    
    // Output result (3 cycles later)
    output logic                                    result_valid,
    output logic [XLEN-1:0]                         result,
    output logic [PHYS_REG_BITS-1:0]                result_dst_tag,
    output logic [ROB_IDX_BITS-1:0]                 result_rob_idx
);

    //==========================================================================
    // Pipeline stages
    // Stage 0: Booth encoding
    // Stage 1: Wallace tree partial product reduction
    // Stage 2: Final carry-propagate addition
    //==========================================================================
    
    // Stage 0 registers
    logic                       s0_valid;
    uop_opcode_t                s0_opcode;
    logic [XLEN-1:0]            s0_src1;
    logic [XLEN-1:0]            s0_src2;
    logic [PHYS_REG_BITS-1:0]   s0_dst_tag;
    logic [ROB_IDX_BITS-1:0]    s0_rob_idx;
    
    // Stage 1 registers
    logic                       s1_valid;
    uop_opcode_t                s1_opcode;
    logic [127:0]               s1_partial_product;
    logic [PHYS_REG_BITS-1:0]   s1_dst_tag;
    logic [ROB_IDX_BITS-1:0]    s1_rob_idx;
    
    // Stage 2 registers
    logic                       s2_valid;
    uop_opcode_t                s2_opcode;
    logic [127:0]               s2_product;
    logic [PHYS_REG_BITS-1:0]   s2_dst_tag;
    logic [ROB_IDX_BITS-1:0]    s2_rob_idx;
    
    //==========================================================================
    // Stage 0: Input capture
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid <= 1'b0;
        end else begin
            s0_valid <= valid;
            s0_opcode <= opcode;
            s0_src1 <= src1;
            s0_src2 <= src2;
            s0_dst_tag <= dst_tag;
            s0_rob_idx <= rob_idx;
        end
    end
    
    //==========================================================================
    // Stage 1: Booth encoding and partial product generation
    // Radix-4 Booth: examine 3 bits at a time, generate partial products
    //==========================================================================
    
    logic [127:0] booth_partial_product;
    
    always_comb begin
        logic signed [63:0] multiplicand;
        logic signed [63:0] multiplier;
        logic signed [127:0] pp_sum;
        
        // Sign extension based on operation
        case (s0_opcode)
            UOP_MUL, UOP_MULH: begin
                // Signed × Signed
                multiplicand = $signed(s0_src1);
                multiplier = $signed(s0_src2);
            end
            UOP_MULHU: begin
                // Unsigned × Unsigned
                multiplicand = $signed({1'b0, s0_src1});
                multiplier = $signed({1'b0, s0_src2});
            end
            UOP_MULHSU: begin
                // Signed × Unsigned
                multiplicand = $signed(s0_src1);
                multiplier = $signed({1'b0, s0_src2});
            end
            default: begin
                multiplicand = '0;
                multiplier = '0;
            end
        endcase
        
        // Simple multiplication (synthesis tool will infer optimal multiplier)
        pp_sum = multiplicand * multiplier;
        booth_partial_product = pp_sum;
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid <= s0_valid;
            s1_opcode <= s0_opcode;
            s1_partial_product <= booth_partial_product;
            s1_dst_tag <= s0_dst_tag;
            s1_rob_idx <= s0_rob_idx;
        end
    end
    
    //==========================================================================
    // Stage 2: Wallace tree reduction (pipelined)
    // In real hardware, this would be a multi-level CSA tree
    // For RTL, we let synthesis optimize
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
        end else begin
            s2_valid <= s1_valid;
            s2_opcode <= s1_opcode;
            s2_product <= s1_partial_product;  // Already reduced in Stage 1
            s2_dst_tag <= s1_dst_tag;
            s2_rob_idx <= s1_rob_idx;
        end
    end
    
    //==========================================================================
    // Stage 3: Final result selection
    //==========================================================================
    
    always_comb begin
        case (s2_opcode)
            UOP_MUL: begin
                // Lower 64 bits
                result = s2_product[63:0];
            end
            UOP_MULH, UOP_MULHU, UOP_MULHSU: begin
                // Upper 64 bits
                result = s2_product[127:64];
            end
            default: begin
                result = '0;
            end
        endcase
    end
    
    assign result_valid = s2_valid;
    assign result_dst_tag = s2_dst_tag;
    assign result_rob_idx = s2_rob_idx;

endmodule : superh16_int_mul