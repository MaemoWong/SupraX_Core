//==============================================================================
// File: 05_execute/superh16_branch_exec.sv
// Description: Branch execution and resolution
// 1-cycle execution, triggers flush on misprediction
//==============================================================================

module superh16_branch_exec
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Input
    input  logic                                    valid,
    input  uop_opcode_t                             opcode,
    input  logic [XLEN-1:0]                         src1,
    input  logic [XLEN-1:0]                         src2,
    input  logic [VADDR_WIDTH-1:0]                  pc,
    input  logic [VADDR_WIDTH-1:0]                  predicted_target,
    input  logic                                    predicted_taken,
    input  logic [15:0]                             imm,
    input  logic [PHYS_REG_BITS-1:0]                dst_tag,
    input  logic [ROB_IDX_BITS-1:0]                 rob_idx,
    
    // Output
    output logic                                    result_valid,
    output logic [XLEN-1:0]                         result,
    output logic [PHYS_REG_BITS-1:0]                result_dst_tag,
    output logic [ROB_IDX_BITS-1:0]                 result_rob_idx,
    output logic                                    branch_resolved,
    output logic                                    branch_taken,
    output logic                                    branch_mispredicted,
    output logic [VADDR_WIDTH-1:0]                  branch_target
);

    //==========================================================================
    // Branch condition evaluation
    //==========================================================================
    
    logic condition_met;
    
    always_comb begin
        case (opcode)
            UOP_BEQ:  condition_met = (src1 == src2);
            UOP_BNE:  condition_met = (src1 != src2);
            UOP_BLT:  condition_met = ($signed(src1) < $signed(src2));
            UOP_BGE:  condition_met = ($signed(src1) >= $signed(src2));
            UOP_BLTU: condition_met = (src1 < src2);
            UOP_BGEU: condition_met = (src1 >= src2);
            UOP_JAL:  condition_met = 1'b1;  // Unconditional
            UOP_JALR: condition_met = 1'b1;  // Unconditional
            default:  condition_met = 1'b0;
        endcase
    end
    
    //==========================================================================
    // Target address computation
    //==========================================================================
    
    logic [VADDR_WIDTH-1:0] computed_target;
    logic [XLEN-1:0] link_address;
    
    always_comb begin
        case (opcode)
            UOP_JAL: begin
                // JAL: PC + immediate
                computed_target = pc + {{44{imm[15]}}, imm, 4'b0};
                link_address = pc + 4;
            end
            
            UOP_JALR: begin
                // JALR: (src1 + immediate) & ~1
                computed_target = (src1 + {{48{imm[15]}}, imm}) & ~64'h1;
                link_address = pc + 4;
            end
            
            default: begin  // Conditional branches
                computed_target = pc + {{48{imm[15]}}, imm};
                link_address = '0;  // No link for conditional branches
            end
        endcase
    end
    
    //==========================================================================
    // Branch resolution
    //==========================================================================
    
    logic actual_taken;
    assign actual_taken = condition_met;
    
    logic [VADDR_WIDTH-1:0] actual_target;
    assign actual_target = actual_taken ? computed_target : (pc + 4);
    
    // Check for misprediction
    logic mispredict;
    assign mispredict = (actual_taken != predicted_taken) ||
                       (actual_taken && (actual_target != predicted_target));
    
    //==========================================================================
    // Output (1 cycle latency)
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_valid <= 1'b0;
            branch_resolved <= 1'b0;
        end else begin
            result_valid <= valid;
            result <= link_address;  // For JAL/JALR, return address
            result_dst_tag <= dst_tag;
            result_rob_idx <= rob_idx;
            branch_resolved <= valid;
            branch_taken <= actual_taken;
            branch_mispredicted <= mispredict;
            branch_target <= actual_target;
        end
    end

endmodule : superh16_branch_exec