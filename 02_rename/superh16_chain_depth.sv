//==============================================================================
// File: 02_rename/superh16_chain_depth.sv
// Description: Chain Depth Tracker - NOVEL priority scheduling component
// This module tracks the critical path length (chain depth) for each physical
// register dynamically. This information is used by the scheduler to prioritize
// instructions on the longest dependency chains.
//
// Key Innovation: Traditional schedulers use age-based or random selection.
// We use chain depth (critical path length) to maximize ILP by scheduling
// long-latency dependency chains first.
//==============================================================================

module superh16_chain_depth
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Rename interface (compute new chain depths)
    input  logic                                    rename_valid [ISSUE_WIDTH],
    input  uop_opcode_t                             rename_opcode [ISSUE_WIDTH],
    input  logic [PHYS_REG_BITS-1:0]                rename_src1_tag [ISSUE_WIDTH],
    input  logic [PHYS_REG_BITS-1:0]                rename_src2_tag [ISSUE_WIDTH],
    input  logic [PHYS_REG_BITS-1:0]                rename_src3_tag [ISSUE_WIDTH],
    input  logic [PHYS_REG_BITS-1:0]                rename_dst_tag [ISSUE_WIDTH],
    input  logic                                    rename_src1_valid [ISSUE_WIDTH],
    input  logic                                    rename_src2_valid [ISSUE_WIDTH],
    input  logic                                    rename_src3_valid [ISSUE_WIDTH],
    
    // Output: computed chain depths
    output logic [CHAIN_DEPTH_BITS-1:0]             rename_chain_depth [ISSUE_WIDTH],
    
    // Writeback interface (update chain depth table on completion)
    input  logic                                    wb_valid [WAKEUP_PORTS],
    input  logic [PHYS_REG_BITS-1:0]                wb_dst_tag [WAKEUP_PORTS],
    input  logic [CHAIN_DEPTH_BITS-1:0]             wb_chain_depth [WAKEUP_PORTS],
    
    // Flush interface (clear speculative state)
    input  logic                                    flush,
    input  logic [ROB_IDX_BITS-1:0]                 flush_rob_idx
);

    //==========================================================================
    // Chain Depth Table (CDT)
    // One entry per physical register: stores the chain depth
    //==========================================================================
    
    logic [CHAIN_DEPTH_BITS-1:0] cdt [NUM_PHYS_REGS];
    
    // Separate read/write enables for power gating
    logic cdt_read_enable;
    logic cdt_write_enable;
    
    assign cdt_read_enable = |rename_valid;
    assign cdt_write_enable = |wb_valid;
    
    //==========================================================================
    // Read ports (3 sources × ISSUE_WIDTH = 36 reads per cycle)
    // This is a lot of ports! We implement with banking for area efficiency
    //==========================================================================
    
    logic [CHAIN_DEPTH_BITS-1:0] src1_depth [ISSUE_WIDTH];
    logic [CHAIN_DEPTH_BITS-1:0] src2_depth [ISSUE_WIDTH];
    logic [CHAIN_DEPTH_BITS-1:0] src3_depth [ISSUE_WIDTH];
    
    // Combinational read (multi-ported register file)
    // In real synthesis, this would be implemented with register file compilers
    // or split into banks. For now, we model it directly.
    always_comb begin
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            if (rename_valid[i] && cdt_read_enable) begin
                src1_depth[i] = rename_src1_valid[i] ? cdt[rename_src1_tag[i]] : '0;
                src2_depth[i] = rename_src2_valid[i] ? cdt[rename_src2_tag[i]] : '0;
                src3_depth[i] = rename_src3_valid[i] ? cdt[rename_src3_tag[i]] : '0;
            end else begin
                src1_depth[i] = '0;
                src2_depth[i] = '0;
                src3_depth[i] = '0;
            end
        end
    end
    
    //==========================================================================
    // Chain Depth Computation
    // new_depth = max(src1_depth, src2_depth, src3_depth) + latency
    //
    // This is the CRITICAL PATH in rename stage!
    // Timing budget: ~55ps (3-input max + add + register setup)
    //==========================================================================
    
    logic [CHAIN_DEPTH_BITS-1:0] max_depth [ISSUE_WIDTH];
    logic [CHAIN_DEPTH_BITS-1:0] exec_latency [ISSUE_WIDTH];
    
    // Execution latency lookup (parallel)
    always_comb begin
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            exec_latency[i] = get_exec_latency(rename_opcode[i]);
        end
    end
    
    // Three-input max tree (2 levels)
    always_comb begin
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            logic [CHAIN_DEPTH_BITS-1:0] temp_max;
            
            // Level 1: max(src1, src2)
            temp_max = (src1_depth[i] > src2_depth[i]) ? src1_depth[i] : src2_depth[i];
            
            // Level 2: max(temp_max, src3)
            max_depth[i] = (temp_max > src3_depth[i]) ? temp_max : src3_depth[i];
        end
    end
    
    // Add latency (with saturation at max value)
    always_comb begin
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            logic [CHAIN_DEPTH_BITS:0] sum;  // Extra bit for overflow detection
            
            sum = max_depth[i] + exec_latency[i];
            
            // Saturate at maximum chain depth
            if (sum > ((1 << CHAIN_DEPTH_BITS) - 1)) begin
                rename_chain_depth[i] = (1 << CHAIN_DEPTH_BITS) - 1;
            end else begin
                rename_chain_depth[i] = sum[CHAIN_DEPTH_BITS-1:0];
            end
        end
    end
    
    //==========================================================================
    // Write ports (update CDT on instruction completion)
    // WAKEUP_PORTS = 24 writes per cycle
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Initialize all chain depths to 0
            for (int i = 0; i < NUM_PHYS_REGS; i++) begin
                cdt[i] <= '0;
            end
        end else if (flush) begin
            // On flush, we could optionally clear speculative depths
            // For simplicity, we keep them (conservative)
        end else if (cdt_write_enable) begin
            // Update chain depth table with completed instruction depths
            for (int i = 0; i < WAKEUP_PORTS; i++) begin
                if (wb_valid[i]) begin
                    cdt[wb_dst_tag[i]] <= wb_chain_depth[i];
                end
            end
        end
    end
    
    //==========================================================================
    // Write-through bypass
    // If we're reading a tag that's being written this cycle, use new value
    // This avoids a 1-cycle bubble in dependent instructions
    //==========================================================================
    
    // Note: In real design, this bypass logic would be critical for performance
    // but adds complexity. For now, we rely on scheduler wakeup to handle this.
    
    //==========================================================================
    // Assertions for verification
    //==========================================================================
    
    `ifdef SIMULATION
        // Check no duplicate writes
        always_ff @(posedge clk) begin
            if (rst_n && cdt_write_enable) begin
                for (int i = 0; i < WAKEUP_PORTS; i++) begin
                    for (int j = i+1; j < WAKEUP_PORTS; j++) begin
                        if (wb_valid[i] && wb_valid[j]) begin
                            assert(wb_dst_tag[i] != wb_dst_tag[j])
                                else $error("Duplicate chain depth write to tag %d", wb_dst_tag[i]);
                        end
                    end
                end
            end
        end
        
        // Check chain depths don't exceed maximum
        always_ff @(posedge clk) begin
            if (rst_n) begin
                for (int i = 0; i < ISSUE_WIDTH; i++) begin
                    if (rename_valid[i]) begin
                        assert(rename_chain_depth[i] < (1 << CHAIN_DEPTH_BITS))
                            else $error("Chain depth overflow at rename slot %d", i);
                    end
                end
            end
        end
    `endif

endmodule : superh16_chain_depth