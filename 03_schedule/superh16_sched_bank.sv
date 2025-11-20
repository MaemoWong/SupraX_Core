//==============================================================================
// File: 03_schedule/superh16_sched_bank.sv
// Description: Single scheduler bank (64 entries)
// Contains entry storage, wakeup logic, and priority selection
//==============================================================================

module superh16_sched_bank
    import superh16_pkg::*;
#(
    parameter int BANK_ID = 0
)(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Allocation interface (from rename)
    input  logic                                    alloc_valid [4],  // 4 allocs per bank per cycle
    input  renamed_inst_t                           alloc_inst [4],
    output logic                                    alloc_ready,      // Bank has space
    
    // Wakeup interface
    input  logic                                    wakeup_valid [WAKEUP_PORTS],
    input  logic [PHYS_REG_BITS-1:0]                wakeup_tag [WAKEUP_PORTS],
    
    // Issue interface (4 issues per bank)
    output logic                                    issue_valid [4],
    output logic [5:0]                              issue_index [4],  // Which entry
    output micro_op_t                               issue_uop [4],
    
    // Flush interface
    input  logic                                    flush,
    input  logic [ROB_IDX_BITS-1:0]                 flush_rob_idx
);

    //==========================================================================
    // Entry storage
    //==========================================================================
    
    micro_op_t entries [64];
    logic [63:0] entry_valid;
    
    // Free entry tracking
    logic [63:0] free_bitmap;
    logic [5:0] free_count;
    
    assign alloc_ready = (free_count >= 4);  // Can allocate 4 per cycle
    
    // Count free entries
    always_comb begin
        free_count = 0;
        for (int i = 0; i < 64; i++) begin
            if (free_bitmap[i]) free_count++;
        end
    end
    
    //==========================================================================
    // Allocation logic
    // Find 4 free entries and allocate
    //==========================================================================
    
    logic [5:0] alloc_entry_idx [4];
    logic [3:0] alloc_success;
    
    always_comb begin
        logic [63:0] temp_free;
        temp_free = free_bitmap;
        
        for (int i = 0; i < 4; i++) begin
            alloc_success[i] = 1'b0;
            alloc_entry_idx[i] = 6'd0;
            
            if (alloc_valid[i] && alloc_ready) begin
                // Find first free entry
                for (int j = 0; j < 64; j++) begin
                    if (temp_free[j]) begin
                        alloc_entry_idx[i] = j[5:0];
                        alloc_success[i] = 1'b1;
                        temp_free[j] = 1'b0;  // Mark as used for next allocation
                        break;
                    end
                end
            end
        end
    end
    
    //==========================================================================
    // Entry update (allocation + wakeup)
    //==========================================================================
    
    // Wakeup results
    logic entry_src1_ready_next [64];
    logic entry_src2_ready_next [64];
    logic entry_src3_ready_next [64];
    logic entry_ready [64];
    
    // Wakeup CAM
    superh16_wakeup_cam wakeup_cam (
        .clk,
        .rst_n,
        .entry_valid        (entry_valid),
        .entry_src1_tag     ('{default: entries[i].src1_tag}),
        .entry_src2_tag     ('{default: entries[i].src2_tag}),
        .entry_src3_tag     ('{default: entries[i].src3_tag}),
        .entry_src1_valid   ('{default: entries[i].src1_valid}),
        .entry_src2_valid   ('{default: entries[i].src2_valid}),
        .entry_src3_valid   ('{default: entries[i].src3_valid}),
        .entry_src1_ready   ('{default: entries[i].src1_ready}),
        .entry_src2_ready   ('{default: entries[i].src2_ready}),
        .entry_src3_ready   ('{default: entries[i].src3_ready}),
        .wakeup_valid,
        .wakeup_tag,
        .entry_src1_ready_next,
        .entry_src2_ready_next,
        .entry_src3_ready_next,
        .entry_ready
    );
    
    //==========================================================================
    // Priority selection (select top 4 by chain depth)
    //==========================================================================
    
    logic [CHAIN_DEPTH_BITS-1:0] entry_priority [64];
    
    // Extract priorities
    always_comb begin
        for (int i = 0; i < 64; i++) begin
            entry_priority[i] = entries[i].chain_depth;
        end
    end
    
    superh16_priority_select #(
        .ENTRIES(64),
        .SELECT_COUNT(4)
    ) priority_select (
        .clk,
        .rst_n,
        .entry_valid        (entry_valid),
        .entry_ready        (entry_ready),
        .entry_priority     (entry_priority),
        .select_valid       (issue_valid),
        .select_index       (issue_index),
        .select_priority    (/* unused */)
    );
    
    // Output selected micro-ops
    always_comb begin
        for (int i = 0; i < 4; i++) begin
            if (issue_valid[i]) begin
                issue_uop[i] = entries[issue_index[i]];
            end else begin
                issue_uop[i] = '{default: '0};
            end
        end
    end
    
    //==========================================================================
    // Entry state update
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            entry_valid <= '0;
            free_bitmap <= '1;  // All entries free
            for (int i = 0; i < 64; i++) begin
                entries[i] <= '{default: '0};
            end
        end
        else if (flush) begin
            // Invalidate all younger entries
            for (int i = 0; i < 64; i++) begin
                if (entry_valid[i] && 
                    (entries[i].rob_idx > flush_rob_idx)) begin
                    entry_valid[i] <= 1'b0;
                    free_bitmap[i] <= 1'b1;
                end
            end
        end
        else begin
            // Allocate new entries
            for (int i = 0; i < 4; i++) begin
                if (alloc_success[i]) begin
                    entries[alloc_entry_idx[i]].valid <= 1'b1;
                    entries[alloc_entry_idx[i]].opcode <= alloc_inst[i].opcode;
                    entries[alloc_entry_idx[i]].src1_tag <= alloc_inst[i].src1_tag;
                    entries[alloc_entry_idx[i]].src2_tag <= alloc_inst[i].src2_tag;
                    entries[alloc_entry_idx[i]].src3_tag <= alloc_inst[i].src3_tag;
                    entries[alloc_entry_idx[i]].dst_tag <= alloc_inst[i].dst_tag;
                    entries[alloc_entry_idx[i]].src1_valid <= (alloc_inst[i].src1_tag != '0);
                    entries[alloc_entry_idx[i]].src2_valid <= (alloc_inst[i].src2_tag != '0);
                    entries[alloc_entry_idx[i]].src3_valid <= (alloc_inst[i].src3_tag != '0);
                    entries[alloc_entry_idx[i]].src1_ready <= alloc_inst[i].src1_ready;
                    entries[alloc_entry_idx[i]].src2_ready <= alloc_inst[i].src2_ready;
                    entries[alloc_entry_idx[i]].src3_ready <= alloc_inst[i].src3_ready;
                    entries[alloc_entry_idx[i]].chain_depth <= alloc_inst[i].chain_depth;
                    entries[alloc_entry_idx[i]].rob_idx <= alloc_inst[i].rob_idx;
                    entries[alloc_entry_idx[i]].exec_unit <= alloc_inst[i].exec_unit;
                    entries[alloc_entry_idx[i]].imm <= alloc_inst[i].imm;
                    entries[alloc_entry_idx[i]].is_load <= alloc_inst[i].is_load;
                    entries[alloc_entry_idx[i]].is_store <= alloc_inst[i].is_store;
                    entries[alloc_entry_idx[i]].is_branch <= alloc_inst[i].is_branch;
                    
                    entry_valid[alloc_entry_idx[i]] <= 1'b1;
                    free_bitmap[alloc_entry_idx[i]] <= 1'b0;
                end
            end
            
            // Update ready bits from wakeup
            for (int i = 0; i < 64; i++) begin
                if (entry_valid[i]) begin
                    entries[i].src1_ready <= entry_src1_ready_next[i];
                    entries[i].src2_ready <= entry_src2_ready_next[i];
                    entries[i].src3_ready <= entry_src3_ready_next[i];
                end
            end
            
            // Deallocate issued entries
            for (int i = 0; i < 4; i++) begin
                if (issue_valid[i]) begin
                    entry_valid[issue_index[i]] <= 1'b0;
                    free_bitmap[issue_index[i]] <= 1'b1;
                end
            end
        end
    end

endmodule : superh16_sched_bank