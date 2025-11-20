//==============================================================================
// File: 07_retire/superh16_rob.sv
// Description: Reorder Buffer (240 entries)
// Maintains program order for precise exceptions and retirement
//==============================================================================

module superh16_rob
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Allocation from rename (12 per cycle)
    input  logic                                    alloc_valid [ISSUE_WIDTH],
    input  renamed_inst_t                           alloc_inst [ISSUE_WIDTH],
    output logic [ROB_IDX_BITS-1:0]                 alloc_rob_idx [ISSUE_WIDTH],
    output logic                                    alloc_ready,
    
    // Completion from execution units
    input  logic                                    complete_valid [ISSUE_WIDTH],
    input  logic [ROB_IDX_BITS-1:0]                 complete_rob_idx [ISSUE_WIDTH],
    input  logic [XLEN-1:0]                         complete_result [ISSUE_WIDTH],
    input  logic                                    complete_exception [ISSUE_WIDTH],
    input  logic [7:0]                              complete_exc_code [ISSUE_WIDTH],
    input  logic                                    complete_branch_mispredict [ISSUE_WIDTH],
    input  logic [VADDR_WIDTH-1:0]                  complete_branch_target [ISSUE_WIDTH],
    
    // Commit/retirement (12 per cycle)
    output logic                                    commit_valid [RETIRE_WIDTH],
    output logic [PHYS_REG_BITS-1:0]                commit_dst_tag [RETIRE_WIDTH],
    output logic [ARCH_REG_BITS-1:0]                commit_dst_arch [RETIRE_WIDTH],
    output logic [PHYS_REG_BITS-1:0]                commit_old_tag [RETIRE_WIDTH],
    output logic [XLEN-1:0]                         commit_result [RETIRE_WIDTH],
    output logic [VADDR_WIDTH-1:0]                  commit_pc [RETIRE_WIDTH],
    
    // Exception handling
    output logic                                    exception_valid,
    output logic [VADDR_WIDTH-1:0]                  exception_pc,
    output logic [7:0]                              exception_code,
    
    // Branch misprediction
    output logic                                    mispredict_valid,
    output logic [ROB_IDX_BITS-1:0]                 mispredict_rob_idx,
    output logic [VADDR_WIDTH-1:0]                  mispredict_target,
    
    // State
    output logic                                    rob_empty,
    output logic                                    rob_full
);

    //==========================================================================
    // ROB storage (circular buffer)
    //==========================================================================
    
    rob_entry_t rob [ROB_ENTRIES];
    
    logic [ROB_IDX_BITS-1:0] head_ptr;
    logic [ROB_IDX_BITS-1:0] tail_ptr;
    logic [ROB_IDX_BITS:0] count;  // Extra bit to distinguish full/empty
    
    assign rob_empty = (count == 0);
    assign rob_full = (count >= (ROB_ENTRIES - ISSUE_WIDTH));  // Reserve space
    assign alloc_ready = !rob_full;
    
    //==========================================================================
    // Allocation (advance tail, write entries)
    //==========================================================================
    
    always_comb begin
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            alloc_rob_idx[i] = (tail_ptr + i) % ROB_ENTRIES;
        end
    end
    
    //==========================================================================
    // Commit logic (advance head if instructions at head are complete)
    //==========================================================================
    
    logic [RETIRE_WIDTH-1:0] can_commit;
    logic [3:0] commit_count;  // How many to commit this cycle
    
    always_comb begin
        commit_count = 0;
        
        // Check up to RETIRE_WIDTH instructions from head
        for (int i = 0; i < RETIRE_WIDTH; i++) begin
            logic [ROB_IDX_BITS-1:0] idx;
            idx = (head_ptr + i) % ROB_ENTRIES;
            
            can_commit[i] = rob[idx].valid && 
                           rob[idx].complete && 
                           !rob[idx].exception;
            
            if (can_commit[i]) begin
                commit_count = i + 1;
            end else begin
                break;  // Stop at first non-committable instruction
            end
        end
        
        // Generate commit signals
        for (int i = 0; i < RETIRE_WIDTH; i++) begin
            logic [ROB_IDX_BITS-1:0] idx;
            idx = (head_ptr + i) % ROB_ENTRIES;
            
            commit_valid[i] = (i < commit_count);
            commit_dst_tag[i] = rob[idx].dst_tag;
            commit_dst_arch[i] = rob[idx].dst_arch;
            commit_old_tag[i] = rob[idx].old_dst_tag;
            commit_result[i] = rob[idx].result;
            commit_pc[i] = rob[idx].pc;
        end
    end
    
    //==========================================================================
    // Exception detection (oldest instruction with exception)
    //==========================================================================
    
    always_comb begin
        exception_valid = 1'b0;
        exception_pc = '0;
        exception_code = '0;
        
        // Check head instruction for exception
        if (rob[head_ptr].valid && 
            rob[head_ptr].complete && 
            rob[head_ptr].exception) begin
            exception_valid = 1'b1;
            exception_pc = rob[head_ptr].pc;
            exception_code = rob[head_ptr].exception_code;
        end
    end
    
    //==========================================================================
    // Branch misprediction detection (walk ROB to find oldest)
    //==========================================================================
    
    always_comb begin
        mispredict_valid = 1'b0;
        mispredict_rob_idx = '0;
        mispredict_target = '0;
        
        // Walk from head to find first mispredicted branch
        for (int i = 0; i < ROB_ENTRIES; i++) begin
            logic [ROB_IDX_BITS-1:0] idx;
            idx = (head_ptr + i) % ROB_ENTRIES;
            
            if (rob[idx].valid && 
                rob[idx].complete && 
                rob[idx].branch_mispredicted) begin
                mispredict_valid = 1'b1;
                mispredict_rob_idx = idx;
                mispredict_target = rob[idx].branch_target;
                break;
            end
        end
    end
    
    //==========================================================================
    // ROB state update
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_ptr <= '0;
            tail_ptr <= '0;
            count <= '0;
            
            for (int i = 0; i < ROB_ENTRIES; i++) begin
                rob[i] <= '{default: '0};
            end
        end
        else if (exception_valid || mispredict_valid) begin
            // Flush on exception or misprediction
            // Keep head, flush tail back to head+1
            if (exception_valid) begin
                tail_ptr <= (head_ptr + 1) % ROB_ENTRIES;
                count <= 1;
            end else begin
                tail_ptr <= (mispredict_rob_idx + 1) % ROB_ENTRIES;
                count <= (mispredict_rob_idx - head_ptr + 1) % ROB_ENTRIES;
            end
            
            // Invalidate flushed entries
            for (int i = 0; i < ROB_ENTRIES; i++) begin
                if (exception_valid) begin
                    if (i != head_ptr) rob[i].valid <= 1'b0;
                end else begin
                    if ((i > mispredict_rob_idx && i < tail_ptr) ||
                        (i > mispredict_rob_idx && tail_ptr < head_ptr) ||
                        (i < tail_ptr && tail_ptr < head_ptr)) begin
                        rob[i].valid <= 1'b0;
                    end
                end
            end
        end
        else begin
            // Normal operation: allocate and commit
            
            // Allocate new entries
            for (int i = 0; i < ISSUE_WIDTH; i++) begin
                if (alloc_valid[i] && alloc_ready) begin
                    logic [ROB_IDX_BITS-1:0] idx;
                    idx = alloc_rob_idx[i];
                    
                    rob[idx].valid <= 1'b1;
                    rob[idx].complete <= 1'b0;
                    rob[idx].exception <= 1'b0;
                    rob[idx].pc <= alloc_inst[i].pc;
                    rob[idx].dst_tag <= alloc_inst[i].dst_tag;
                    rob[idx].dst_arch <= alloc_inst[i].dst_arch;
                    rob[idx].old_dst_tag <= alloc_inst[i].old_dst_tag;
                    rob[idx].result <= '0;
                    rob[idx].exception_code <= '0;
                    rob[idx].is_branch <= alloc_inst[i].is_branch;
                    rob[idx].branch_taken <= 1'b0;
                    rob[idx].branch_mispredicted <= 1'b0;
                    rob[idx].branch_target <= '0;
                end
            end
            
            // Mark completed entries
            for (int i = 0; i < ISSUE_WIDTH; i++) begin
                if (complete_valid[i]) begin
                    rob[complete_rob_idx[i]].complete <= 1'b1;
                    rob[complete_rob_idx[i]].result <= complete_result[i];
                    rob[complete_rob_idx[i]].exception <= complete_exception[i];
                    rob[complete_rob_idx[i]].exception_code <= complete_exc_code[i];
                    rob[complete_rob_idx[i]].branch_mispredicted <= complete_branch_mispredict[i];
                    rob[complete_rob_idx[i]].branch_target <= complete_branch_target[i];
                end
            end
            
            // Commit (invalidate committed entries)
            for (int i = 0; i < RETIRE_WIDTH; i++) begin
                if (commit_valid[i]) begin
                    logic [ROB_IDX_BITS-1:0] idx;
                    idx = (head_ptr + i) % ROB_ENTRIES;
                    rob[idx].valid <= 1'b0;
                end
            end
            
            // Update pointers
            if (|alloc_valid && alloc_ready) begin
                logic [3:0] alloc_count;
                alloc_count = 0;
                for (int i = 0; i < ISSUE_WIDTH; i++) begin
                    if (alloc_valid[i]) alloc_count++;
                end
                tail_ptr <= (tail_ptr + alloc_count) % ROB_ENTRIES;
            end
            
            if (|commit_valid) begin
                head_ptr <= (head_ptr + commit_count) % ROB_ENTRIES;
            end
            
            // Update count
            count <= count + (|alloc_valid ? alloc_count : 0) - 
                            (|commit_valid ? commit_count : 0);
        end
    end
    
    //==========================================================================
    // Assertions
    //==========================================================================
    
    `ifdef SIMULATION
        // ROB should never overflow
        always_ff @(posedge clk) begin
            if (rst_n) begin
                assert(count <= ROB_ENTRIES)
                    else $error("ROB overflow: count=%d", count);
            end
        end
        
        // Committed instructions should be complete
        always_ff @(posedge clk) begin
            if (rst_n) begin
                for (int i = 0; i < RETIRE_WIDTH; i++) begin
                    if (commit_valid[i]) begin
                        logic [ROB_IDX_BITS-1:0] idx;
                        idx = (head_ptr + i) % ROB_ENTRIES;
                        assert(rob[idx].complete)
                            else $error("Committing incomplete instruction at ROB[%d]", idx);
                    end
                end
            end
        end
    `endif

endmodule : superh16_rob