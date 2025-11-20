//==============================================================================
// File: 06_memory/superh16_store_queue.sv
// Description: Store Queue (24 entries)
// Buffers stores until commit, forwards to younger loads
//==============================================================================

module superh16_store_queue
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Allocation (from store units)
    input  logic                                    alloc_valid [NUM_STORE_UNITS],
    input  logic [VADDR_WIDTH-1:0]                  alloc_addr [NUM_STORE_UNITS],
    input  logic [XLEN-1:0]                         alloc_data [NUM_STORE_UNITS],
    input  logic [2:0]                              alloc_size [NUM_STORE_UNITS],
    input  logic [ROB_IDX_BITS-1:0]                 alloc_rob_idx [NUM_STORE_UNITS],
    output logic                                    alloc_full,
    
    // Forwarding to load queue
    input  logic                                    fwd_check_valid,
    input  logic [VADDR_WIDTH-1:0]                  fwd_check_addr,
    input  logic [2:0]                              fwd_check_size,
    output logic                                    fwd_valid,
    output logic [XLEN-1:0]                         fwd_data,
    
    // Commit (write to D-cache)
    input  logic                                    commit_valid [RETIRE_WIDTH],
    input  logic [ROB_IDX_BITS-1:0]                 commit_rob_idx [RETIRE_WIDTH],
    output logic                                    dcache_write_valid,
    output logic [VADDR_WIDTH-1:0]                  dcache_write_addr,
    output logic [XLEN-1:0]                         dcache_write_data,
    output logic [2:0]                              dcache_write_size,
    
    // Flush
    input  logic                                    flush,
    input  logic [ROB_IDX_BITS-1:0]                 flush_rob_idx
);

    //==========================================================================
    // Store queue entry
    //==========================================================================
    
    typedef struct packed {
        logic                       valid;
        logic                       committed;
        logic [VADDR_WIDTH-1:0]     addr;
        logic [XLEN-1:0]            data;
        logic [2:0]                 size;
        logic [ROB_IDX_BITS-1:0]    rob_idx;
    } sq_entry_t;
    
    sq_entry_t sq [STORE_QUEUE_ENTRIES];
    
    logic [STORE_QUEUE_ENTRIES-1:0] free_bitmap;
    logic [$clog2(STORE_QUEUE_ENTRIES):0] free_count;
    
    assign alloc_full = (free_count < NUM_STORE_UNITS);
    
    //==========================================================================
    // Forwarding logic (CAM search)
    //==========================================================================
    
    always_comb begin
        fwd_valid = 1'b0;
        fwd_data = '0;
        
        if (fwd_check_valid) begin
            // Search from newest to oldest
            for (int i = STORE_QUEUE_ENTRIES-1; i >= 0; i--) begin
                if (sq[i].valid && sq[i].addr == fwd_check_addr) begin
                    fwd_valid = 1'b1;
                    fwd_data = sq[i].data;
                    break;
                end
            end
        end
    end
    
    //==========================================================================
    // State update
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            free_bitmap <= '1;
            free_count <= STORE_QUEUE_ENTRIES;
            dcache_write_valid <= 1'b0;
            
            for (int i = 0; i < STORE_QUEUE_ENTRIES; i++) begin
                sq[i].valid <= 1'b0;
            end
        end else begin
            // Allocate
            logic [STORE_QUEUE_ENTRIES-1:0] temp_free;
            temp_free = free_bitmap;
            
            for (int i = 0; i < NUM_STORE_UNITS; i++) begin
                if (alloc_valid[i]) begin
                    for (int j = 0; j < STORE_QUEUE_ENTRIES; j++) begin
                        if (temp_free[j]) begin
                            sq[j].valid <= 1'b1;
                            sq[j].committed <= 1'b0;
                            sq[j].addr <= alloc_addr[i];
                            sq[j].data <= alloc_data[i];
                            sq[j].size <= alloc_size[i];
                            sq[j].rob_idx <= alloc_rob_idx[i];
                            temp_free[j] = 1'b0;
                            free_bitmap[j] <= 1'b0;
                            break;
                        end
                    end
                end
            end
            
            // Mark committed
            for (int i = 0; i < RETIRE_WIDTH; i++) begin
                if (commit_valid[i]) begin
                    for (int j = 0; j < STORE_QUEUE_ENTRIES; j++) begin
                        if (sq[j].valid && sq[j].rob_idx == commit_rob_idx[i]) begin
                            sq[j].committed <= 1'b1;
                        end
                    end
                end
            end
            
            // Write to D-cache (oldest committed entry)
            dcache_write_valid <= 1'b0;
            for (int i = 0; i < STORE_QUEUE_ENTRIES; i++) begin
                if (sq[i].valid && sq[i].committed) begin
                    dcache_write_valid <= 1'b1;
                    dcache_write_addr <= sq[i].addr;
                    dcache_write_data <= sq[i].data;
                    dcache_write_size <= sq[i].size;
                    sq[i].valid <= 1'b0;
                    free_bitmap[i] <= 1'b1;
                    break;
                end
            end
            
            // Count free entries
            free_count = 0;
            for (int i = 0; i < STORE_QUEUE_ENTRIES; i++) begin
                if (free_bitmap[i]) free_count++;
            end
        end
    end

endmodule : superh16_store_queue