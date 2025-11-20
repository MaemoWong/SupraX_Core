//==============================================================================
// File: 01_frontend/superh16_fetch.sv
// Description: Instruction fetch unit (12-wide)
// Fetches 64 bytes (16 instructions) per cycle from I-cache
//==============================================================================

module superh16_fetch
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // PC source (from branch predictor or redirect)
    input  logic [VADDR_WIDTH-1:0]                  pc_in,
    input  logic                                    pc_redirect,
    
    // I-cache interface
    output logic                                    icache_req,
    output logic [VADDR_WIDTH-1:0]                  icache_addr,
    input  logic                                    icache_ack,
    input  logic [511:0]                            icache_data,  // 64 bytes
    input  logic                                    icache_miss,
    
    // Branch prediction
    input  branch_pred_t                            pred_outcome [ISSUE_WIDTH],
    input  logic [VADDR_WIDTH-1:0]                  pred_target [ISSUE_WIDTH],
    
    // Output to decode
    output logic                                    fetch_valid [ISSUE_WIDTH],
    output logic [31:0]                             fetch_inst [ISSUE_WIDTH],
    output logic [VADDR_WIDTH-1:0]                  fetch_pc [ISSUE_WIDTH],
    output branch_pred_t                            fetch_pred [ISSUE_WIDTH],
    output logic [VADDR_WIDTH-1:0]                  fetch_pred_target [ISSUE_WIDTH],
    
    // Stall/flush
    input  logic                                    fetch_stall,
    input  logic                                    flush
);

    //==========================================================================
    // PC management
    //==========================================================================
    
    logic [VADDR_WIDTH-1:0] pc_current;
    logic [VADDR_WIDTH-1:0] pc_next;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_current <= 64'h8000_0000;  // Reset vector
        end else if (flush || pc_redirect) begin
            pc_current <= pc_in;
        end else if (!fetch_stall) begin
            pc_current <= pc_next;
        end
    end
    
    // Next PC calculation (account for branches)
    always_comb begin
        // Default: sequential fetch (12 instructions = 48 bytes)
        pc_next = pc_current + 48;
        
        // Check if any fetched instruction is a taken branch
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            if (fetch_valid[i] && pred_outcome[i] == PRED_TAKEN) begin
                pc_next = pred_target[i];
                break;
            end
        end
    end
    
    //==========================================================================
    // I-cache request
    //==========================================================================
    
    assign icache_req = !fetch_stall && !flush;
    assign icache_addr = pc_current;
    
    //==========================================================================
    // Instruction extraction from cache line
    //==========================================================================
    
    always_comb begin
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            int byte_offset;
            byte_offset = i * 4;  // Each instruction is 4 bytes
            
            if (icache_ack && !icache_miss && (byte_offset < 64)) begin
                fetch_valid[i] = 1'b1;
                fetch_inst[i] = icache_data[byte_offset*8 +: 32];
                fetch_pc[i] = pc_current + byte_offset;
                fetch_pred[i] = pred_outcome[i];
                fetch_pred_target[i] = pred_target[i];
            end else begin
                fetch_valid[i] = 1'b0;
                fetch_inst[i] = 32'h0000_0013;  // NOP (ADDI x0, x0, 0)
                fetch_pc[i] = '0;
                fetch_pred[i] = PRED_NOT_TAKEN;
                fetch_pred_target[i] = '0;
            end
        end
    end

endmodule : superh16_fetch