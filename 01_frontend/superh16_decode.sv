//==============================================================================
// File: 01_frontend/superh16_decode.sv
// Description: Instruction decode (12-wide)
// Converts RISC-V instructions to internal micro-ops
//==============================================================================

module superh16_decode
    import superh16_pkg::*;
    import superh16_isa_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Input from fetch
    input  logic                                    fetch_valid [ISSUE_WIDTH],
    input  logic [31:0]                             fetch_inst [ISSUE_WIDTH],
    input  logic [VADDR_WIDTH-1:0]                  fetch_pc [ISSUE_WIDTH],
    input  branch_pred_t                            fetch_pred [ISSUE_WIDTH],
    input  logic [VADDR_WIDTH-1:0]                  fetch_pred_target [ISSUE_WIDTH],
    
    // Output to rename
    output logic                                    decode_valid [ISSUE_WIDTH],
    output decoded_inst_t                           decode_inst [ISSUE_WIDTH],
    
    // Stall signal
    input  logic                                    decode_stall
);

    //==========================================================================
    // Decode each instruction in parallel
    //==========================================================================
    
    always_comb begin
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            if (fetch_valid[i] && !decode_stall) begin
                // Use ISA package decode function
                decode_inst[i] = decode_instruction(fetch_inst[i], fetch_pc[i]);
                decode_inst[i].branch_pred = fetch_pred[i];
                decode_inst[i].branch_target = fetch_pred_target[i];
                decode_valid[i] = 1'b1;
            end else begin
                decode_inst[i] = '{default: '0};
                decode_valid[i] = 1'b0;
            end
        end
    end
    
    //==========================================================================
    // Micro-op fusion (optional performance optimization)
    // Combine common instruction pairs into single micro-ops
    //==========================================================================
    
    // TODO: Implement fusion patterns:
    // - LOAD + ALU → single load-op micro-op
    // - ALU + BRANCH → single compare-branch micro-op
    // - Address calculation patterns
    
    //==========================================================================
    // Pipeline register
    //==========================================================================
    
    logic                   decode_valid_q [ISSUE_WIDTH];
    decoded_inst_t          decode_inst_q [ISSUE_WIDTH];
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ISSUE_WIDTH; i++) begin
                decode_valid_q[i] <= 1'b0;
            end
        end else if (!decode_stall) begin
            decode_valid_q <= decode_valid;
            decode_inst_q <= decode_inst;
        end
    end

endmodule : superh16_decode