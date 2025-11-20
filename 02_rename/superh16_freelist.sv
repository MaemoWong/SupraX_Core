//==============================================================================
// File: 02_rename/superh16_freelist.sv
// Description: Free list manager for physical register allocation
// Tracks which physical registers are available for allocation
//==============================================================================

module superh16_freelist
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Allocation requests (from rename)
    input  logic                                    alloc_valid [ISSUE_WIDTH],
    output logic [PHYS_REG_BITS-1:0]                alloc_phys_reg [ISSUE_WIDTH],
    output logic                                    alloc_success [ISSUE_WIDTH],
    
    // Reclaim (from commit)
    input  logic                                    reclaim_valid [RETIRE_WIDTH],
    input  logic [PHYS_REG_BITS-1:0]                reclaim_phys_reg [RETIRE_WIDTH],
    
    // Status
    output logic [PHYS_REG_BITS:0]                  free_count,
    output logic                                    nearly_full,
    
    // Flush
    input  logic                                    flush
);

    //==========================================================================
    // Free list implementation: Circular FIFO with bitmap
    //==========================================================================
    
    logic [NUM_PHYS_REGS-1:0] free_bitmap;
    
    // Head/tail pointers for FIFO allocation
    logic [PHYS_REG_BITS-1:0] alloc_head;
    logic [PHYS_REG_BITS-1:0] reclaim_tail;
    
    //==========================================================================
    // Count free registers
    //==========================================================================
    
    always_comb begin
        automatic int count = 0;
        for (int i = 0; i < NUM_PHYS_REGS; i++) begin
            if (free_bitmap[i]) count++;
        end
        free_count = count;
    end
    
    assign nearly_full = (free_count < (ISSUE_WIDTH * 2));
    
    //==========================================================================
    // Allocation logic (find free registers)
    //==========================================================================
    
    always_comb begin
        logic [NUM_PHYS_REGS-1:0] temp_bitmap;
        temp_bitmap = free_bitmap;
        
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            alloc_success[i] = 1'b0;
            alloc_phys_reg[i] = '0;
            
            if (alloc_valid[i]) begin
                // Find first free register
                for (int j = 0; j < NUM_PHYS_REGS; j++) begin
                    if (temp_bitmap[j]) begin
                        alloc_phys_reg[i] = j[PHYS_REG_BITS-1:0];
                        alloc_success[i] = 1'b1;
                        temp_bitmap[j] = 1'b0;  // Mark as used for next allocation
                        break;
                    end
                end
            end
        end
    end
    
    //==========================================================================
    // Free list state update
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Initialize: all registers free except 0-31 (architectural)
            for (int i = 0; i < NUM_PHYS_REGS; i++) begin
                if (i < NUM_ARCH_REGS) begin
                    free_bitmap[i] <= 1'b0;  // Reserved for initial mapping
                end else begin
                    free_bitmap[i] <= 1'b1;  // Free
                end
            end
        end
        else if (flush) begin
            // On flush, reclaim all but architectural registers
            for (int i = 0; i < NUM_PHYS_REGS; i++) begin
                if (i < NUM_ARCH_REGS) begin
                    free_bitmap[i] <= 1'b0;
                end else begin
                    free_bitmap[i] <= 1'b1;
                end
            end
        end
        else begin
            // Allocate registers
            for (int i = 0; i < ISSUE_WIDTH; i++) begin
                if (alloc_valid[i] && alloc_success[i]) begin
                    free_bitmap[alloc_phys_reg[i]] <= 1'b0;
                end
            end
            
            // Reclaim registers
            for (int i = 0; i < RETIRE_WIDTH; i++) begin
                if (reclaim_valid[i]) begin
                    // Don't reclaim architectural registers (0-31)
                    if (reclaim_phys_reg[i] >= NUM_ARCH_REGS) begin
                        free_bitmap[reclaim_phys_reg[i]] <= 1'b1;
                    end
                end
            end
        end
    end
    
    //==========================================================================
    // Assertions
    //==========================================================================
    
    `ifdef SIMULATION
        // Check no double allocation
        always_ff @(posedge clk) begin
            if (rst_n) begin
                for (int i = 0; i < ISSUE_WIDTH; i++) begin
                    for (int j = i+1; j < ISSUE_WIDTH; j++) begin
                        if (alloc_success[i] && alloc_success[j]) begin
                            assert(alloc_phys_reg[i] != alloc_phys_reg[j])
                                else $error("Duplicate allocation of phys reg %d", alloc_phys_reg[i]);
                        end
                    end
                end
            end
        end
        
        // Check no double reclaim
        always_ff @(posedge clk) begin
            if (rst_n) begin
                for (int i = 0; i < RETIRE_WIDTH; i++) begin
                    for (int j = i+1; j < RETIRE_WIDTH; j++) begin
                        if (reclaim_valid[i] && reclaim_valid[j]) begin
                            assert(reclaim_phys_reg[i] != reclaim_phys_reg[j])
                                else $error("Duplicate reclaim of phys reg %d", reclaim_phys_reg[i]);
                        end
                    end
                end
            end
        end
    `endif

endmodule : superh16_freelist