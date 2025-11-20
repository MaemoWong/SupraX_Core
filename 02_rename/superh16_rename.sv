//==============================================================================
// File: 02_rename/superh16_rename.sv
// Description: Register rename stage - top level
// Integrates RAT, free list, and chain depth tracker
//==============================================================================

module superh16_rename
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Input from decode
    input  logic                                    decode_valid [ISSUE_WIDTH],
    input  decoded_inst_t                           decode_inst [ISSUE_WIDTH],
    
    // Output to scheduler
    output logic                                    rename_valid [ISSUE_WIDTH],
    output renamed_inst_t                           rename_inst [ISSUE_WIDTH],
    
    // ROB allocation
    input  logic [ROB_IDX_BITS-1:0]                 rob_alloc_idx [ISSUE_WIDTH],
    
    // Commit interface (for freelist reclaim)
    input  logic                                    commit_valid [RETIRE_WIDTH],
    input  logic [PHYS_REG_BITS-1:0]                commit_old_dst_tag [RETIRE_WIDTH],
    
    // Wakeup for chain depth tracker
    input  logic                                    wb_valid [WAKEUP_PORTS],
    input  logic [PHYS_REG_BITS-1:0]                wb_dst_tag [WAKEUP_PORTS],
    input  logic [CHAIN_DEPTH_BITS-1:0]             wb_chain_depth [WAKEUP_PORTS],
    
    // Stall/flush signals
    output logic                                    rename_stall,
    input  logic                                    flush,
    input  logic [ROB_IDX_BITS-1:0]                 flush_rob_idx
);

    //==========================================================================
    // RAT lookup (3 sources per instruction)
    //==========================================================================
    
    logic [ARCH_REG_BITS-1:0] rat_lookup_arch [ISSUE_WIDTH*3];
    logic [PHYS_REG_BITS-1:0] rat_lookup_phys [ISSUE_WIDTH*3];
    
    // Pack lookups
    always_comb begin
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            rat_lookup_arch[i*3 + 0] = decode_inst[i].src1_arch;
            rat_lookup_arch[i*3 + 1] = decode_inst[i].src2_arch;
            rat_lookup_arch[i*3 + 2] = decode_inst[i].src3_arch;
        end
    end
    
    // RAT instance
    logic rat_update_valid [ISSUE_WIDTH];
    logic [ARCH_REG_BITS-1:0] rat_update_arch [ISSUE_WIDTH];
    logic [PHYS_REG_BITS-1:0] rat_update_phys [ISSUE_WIDTH];
    logic [PHYS_REG_BITS-1:0] rat_update_old [ISSUE_WIDTH];
    
    superh16_rat rat (
        .clk,
        .rst_n,
        .lookup_arch_reg        (rat_lookup_arch),
        .lookup_phys_reg        (rat_lookup_phys),
        .update_valid           (rat_update_valid),
        .update_arch_reg        (rat_update_arch),
        .update_phys_reg        (rat_update_phys),
        .update_old_phys_reg    (rat_update_old),
        .checkpoint_create      (1'b0),  // TODO: Implement checkpointing
        .checkpoint_id          (2'd0),
        .checkpoint_restore     (1'b0),
        .restore_checkpoint_id  (2'd0),
        .flush
    );
    
    //==========================================================================
    // Free list allocation
    //==========================================================================
    
    logic freelist_alloc_valid [ISSUE_WIDTH];
    logic [PHYS_REG_BITS-1:0] freelist_alloc_phys [ISSUE_WIDTH];
    logic freelist_alloc_success [ISSUE_WIDTH];
    logic [PHYS_REG_BITS:0] free_count;
    logic nearly_full;
    
    superh16_freelist freelist (
        .clk,
        .rst_n,
        .alloc_valid        (freelist_alloc_valid),
        .alloc_phys_reg     (freelist_alloc_phys),
        .alloc_success      (freelist_alloc_success),
        .reclaim_valid      (commit_valid),
        .reclaim_phys_reg   (commit_old_dst_tag),
        .free_count,
        .nearly_full,
        .flush
    );
    
    // Request allocation for instructions with destination registers
    always_comb begin
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            freelist_alloc_valid[i] = decode_valid[i] && 
                                     (decode_inst[i].dst_arch != 0);
        end
    end
    
    //==========================================================================
    // Chain depth tracking
    //==========================================================================
    
    logic [CHAIN_DEPTH_BITS-1:0] computed_chain_depth [ISSUE_WIDTH];
    
    superh16_chain_depth chain_depth_tracker (
        .clk,
        .rst_n,
        .rename_valid           (decode_valid),
        .rename_opcode          ('{default: decode_inst[i].opcode}),
        .rename_src1_tag        ('{default: rat_lookup_phys[i*3+0]}),
        .rename_src2_tag        ('{default: rat_lookup_phys[i*3+1]}),
        .rename_src3_tag        ('{default: rat_lookup_phys[i*3+2]}),
        .rename_dst_tag         ('{default: freelist_alloc_phys[i]}),
        .rename_src1_valid      ('{default: (decode_inst[i].src1_arch != 0)}),
        .rename_src2_valid      ('{default: (decode_inst[i].src2_arch != 0)}),
        .rename_src3_valid      ('{default: (decode_inst[i].src3_arch != 0)}),
        .rename_chain_depth     (computed_chain_depth),
        .wb_valid,
        .wb_dst_tag,
        .wb_chain_depth,
        .flush,
        .flush_rob_idx
    );
    
    //==========================================================================
    // Output generation
    //==========================================================================
    
    always_comb begin
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            rename_valid[i] = decode_valid[i] && 
                             (freelist_alloc_success[i] || decode_inst[i].dst_arch == 0);
            
            rename_inst[i].valid = rename_valid[i];
            rename_inst[i].pc = decode_inst[i].pc;
            rename_inst[i].opcode = decode_inst[i].opcode;
            
            // Source physical tags
            rename_inst[i].src1_tag = rat_lookup_phys[i*3 + 0];
            rename_inst[i].src2_tag = rat_lookup_phys[i*3 + 1];
            rename_inst[i].src3_tag = rat_lookup_phys[i*3 + 2];
            
            // Destination physical tag
            if (decode_inst[i].dst_arch == 0) begin
                rename_inst[i].dst_tag = '0;  // Don't allocate for x0
                rename_inst[i].old_dst_tag = '0;
            end else begin
                rename_inst[i].dst_tag = freelist_alloc_phys[i];
                rename_inst[i].old_dst_tag = rat_lookup_phys[i*3 + 0];  // Current mapping
            end
            
            // Ready bits (sources are ready if not waiting for result)
            // For simplicity, assume all sources are ready initially
            // Scheduler's wakeup logic will handle dependency tracking
            rename_inst[i].src1_ready = 1'b0;  // Will be set by scheduler
            rename_inst[i].src2_ready = 1'b0;
            rename_inst[i].src3_ready = 1'b0;
            
            // Chain depth (THE NOVEL PART!)
            rename_inst[i].chain_depth = computed_chain_depth[i];
            
            // Other fields
            rename_inst[i].rob_idx = rob_alloc_idx[i];
            rename_inst[i].exec_unit = decode_inst[i].exec_unit;
            rename_inst[i].imm = decode_inst[i].imm[15:0];
            rename_inst[i].is_load = decode_inst[i].is_load;
            rename_inst[i].is_store = decode_inst[i].is_store;
            rename_inst[i].is_branch = decode_inst[i].is_branch;
            rename_inst[i].branch_pred = decode_inst[i].branch_pred;
            rename_inst[i].branch_target = decode_inst[i].branch_target;
        end
    end
    
    //==========================================================================
    // Update RAT with new mappings
    //==========================================================================
    
    always_comb begin
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            rat_update_valid[i] = rename_valid[i] && (decode_inst[i].dst_arch != 0);
            rat_update_arch[i] = decode_inst[i].dst_arch;
            rat_update_phys[i] = freelist_alloc_phys[i];
        end
    end
    
    //==========================================================================
    // Stall logic
    //==========================================================================
    
    assign rename_stall = nearly_full;  // Stall if running out of physical registers

endmodule : superh16_rename