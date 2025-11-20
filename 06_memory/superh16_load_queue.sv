//==============================================================================
// File: 06_memory/superh16_load_queue.sv
// Description: Load Queue (32 entries)
// Tracks in-flight loads, checks for store-to-load forwarding
//==============================================================================

module superh16_load_queue
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Allocation (from load units)
    input  logic                                    alloc_valid [NUM_LOAD_UNITS],
    input  logic [VADDR_WIDTH-1:0]                  alloc_addr [NUM_LOAD_UNITS],
    input  logic [2:0]                              alloc_size [NUM_LOAD_UNITS],
    input  logic [ROB_IDX_BITS-1:0]                 alloc_rob_idx [NUM_LOAD_UNITS],
    output logic [LQ_IDX_BITS-1:0]                  alloc_lq_idx [NUM_LOAD_UNITS],
    output logic                                    alloc_success [NUM_LOAD_UNITS],
    
    // Store queue forwarding check
    input  logic                                    sq_check_valid,
    input  logic [VADDR_WIDTH-1:0]                  sq_check_addr,
    input  logic [2:0]                              sq_check_size,
    output logic                                    sq_forward_valid,
    output logic [XLEN-1:0]                         sq_forward_data,
    
    // Completion (from load units)
    input  logic                                    complete_valid [NUM_LOAD_UNITS],
    input  logic [LQ_IDX_BITS-1:0]                  complete_lq_idx [NUM_LOAD_UNITS],
    
    // Commit (from ROB)
    input  logic                                    commit_valid [RETIRE_WIDTH],
    input  logic [ROB_IDX_BITS-1:0]                 commit_rob_idx [RETIRE_WIDTH],
    
    // Flush
    input  logic                                    flush,
    input  logic [ROB_IDX_BITS-1:0]                 flush_rob_idx
);

    //==========================================================================
    // Load queue entry
    //==========================================================================
    
    typedef struct packed {
        logic                       valid;
        logic                       complete;
        logic [VADDR_WIDTH-1:0]     addr;
        logic [2:0]                 size;
        logic [ROB_IDX_BITS-1:0]    rob_idx;
    } lq_entry_t;
    
    lq_entry_t lq [LOAD_QUEUE_ENTRIES];
    
    logic [LOAD_QUEUE_ENTRIES-1:0] free_bitmap;
    
    //==========================================================================
    // Allocation
    //==========================================================================
    
    always_comb begin
        logic [LOAD_QUEUE_ENTRIES-1:0] temp_free;
        temp_free = free_bitmap;
        
        for (int i = 0; i < NUM_LOAD_UNITS; i++) begin
            alloc_success[i] = 1'b0;
            alloc_lq_idx[i] = '0;
            
            if (alloc_valid[i]) begin
                for (int j = 0; j < LOAD_QUEUE_ENTRIES; j++) begin
                    if (temp_free[j]) begin
                        alloc_lq_idx[i] = j[LQ_IDX_BITS-1:0];
                        alloc_success[i] = 1'b1;
                        temp_free[j] = 1'b0;
                        break;
                    end
                end
            end
        end
    end
    
    //==========================================================================
    // Store queue forwarding (stub - full implementation in store queue)
    //==========================================================================
    
    assign sq_forward_valid = 1'b0;  // Implemented in store queue
    assign sq_forward_data = '0;
    
    //==========================================================================
    // State update
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            free_bitmap <= '1;
            for (int i = 0; i < LOAD_QUEUE_ENTRIES; i++) begin
                lq[i].valid <= 1'b0;
            end
        end else if (flush) begin
            // Invalidate younger loads
            for (int i = 0; i < LOAD_QUEUE_ENTRIES; i++) begin
                if (lq[i].valid && lq[i].rob_idx > flush_rob_idx) begin
                    lq[i].valid <= 1'b0;
                    free_bitmap[i] <= 1'b1;
                end
            end
        end else begin
            // Allocate
            for (int i = 0; i < NUM_LOAD_UNITS; i++) begin
                if (alloc_success[i]) begin
                    lq[alloc_lq_idx[i]].valid <= 1'b1;
                    lq[alloc_lq_idx[i]].complete <= 1'b0;
                    lq[alloc_lq_idx[i]].addr <= alloc_addr[i];
                    lq[alloc_lq_idx[i]].size <= alloc_size[i];
                    lq[alloc_lq_idx[i]].rob_idx <= alloc_rob_idx[i];
                    free_bitmap[alloc_lq_idx[i]] <= 1'b0;
                end
            end
            
            // Mark complete
            for (int i = 0; i < NUM_LOAD_UNITS; i++) begin
                if (complete_valid[i]) begin
                    lq[complete_lq_idx[i]].complete <= 1'b1;
                end
            end
            
            // Deallocate on commit
            for (int i = 0; i < RETIRE_WIDTH; i++) begin
                if (commit_valid[i]) begin
                    for (int j = 0; j < LOAD_QUEUE_ENTRIES; j++) begin
                        if (lq[j].valid && lq[j].rob_idx == commit_rob_idx[i]) begin
                            lq[j].valid <= 1'b0;
                            free_bitmap[j] <= 1'b1;
                        end
                    end
                end
            end
        end
    end

endmodule : superh16_load_queue