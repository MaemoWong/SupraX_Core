//==============================================================================
// File: 05_execute/superh16_int_alu.sv
// Description: Integer ALU (simple operations, 1-cycle latency)
// Supports: ADD, SUB, AND, OR, XOR, shifts, comparisons
//==============================================================================

module superh16_int_alu
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Input operands
    input  logic                                    valid,
    input  uop_opcode_t                             opcode,
    input  logic [XLEN-1:0]                         src1,
    input  logic [XLEN-1:0]                         src2,
    input  logic [15:0]                             imm,
    input  logic [PHYS_REG_BITS-1:0]                dst_tag,
    input  logic [ROB_IDX_BITS-1:0]                 rob_idx,
    
    // Output result
    output logic                                    result_valid,
    output logic [XLEN-1:0]                         result,
    output logic [PHYS_REG_BITS-1:0]                result_dst_tag,
    output logic [ROB_IDX_BITS-1:0]                 result_rob_idx,
    output logic                                    exception,
    output logic [7:0]                              exception_code
);

    //==========================================================================
    // Combinational ALU logic
    //==========================================================================
    
    logic [XLEN-1:0] alu_result;
    logic [XLEN-1:0] operand2;
    
    // Operand 2 can be src2 or immediate
    assign operand2 = src2;  // Immediate already sign-extended in decode
    
    always_comb begin
        alu_result = '0;
        exception = 1'b0;
        exception_code = '0;
        
        case (opcode)
            UOP_ADD: begin
                alu_result = src1 + operand2;
            end
            
            UOP_SUB: begin
                alu_result = src1 - operand2;
            end
            
            UOP_AND: begin
                alu_result = src1 & operand2;
            end
            
            UOP_OR: begin
                alu_result = src1 | operand2;
            end
            
            UOP_XOR: begin
                alu_result = src1 ^ operand2;
            end
            
            UOP_SLL: begin
                alu_result = src1 << operand2[5:0];  // Shift by lower 6 bits
            end
            
            UOP_SRL: begin
                alu_result = src1 >> operand2[5:0];
            end
            
            UOP_SRA: begin
                alu_result = $signed(src1) >>> operand2[5:0];
            end
            
            UOP_SLT: begin
                alu_result = ($signed(src1) < $signed(operand2)) ? 64'd1 : 64'd0;
            end
            
            UOP_SLTU: begin
                alu_result = (src1 < operand2) ? 64'd1 : 64'd0;
            end
            
            default: begin
                alu_result = '0;
            end
        endcase
    end
    
    //==========================================================================
    // Pipeline register (1 cycle latency)
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_valid <= 1'b0;
            result <= '0;
            result_dst_tag <= '0;
            result_rob_idx <= '0;
        end else begin
            result_valid <= valid;
            result <= alu_result;
            result_dst_tag <= dst_tag;
            result_rob_idx <= rob_idx;
        end
    end

endmodule : superh16_int_alu