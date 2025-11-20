//==============================================================================
// File: 04_regfile/superh16_regfile.sv
// Description: Physical register file (768 registers)
// 2-cluster design for timing: 384 regs per cluster
// 24 read ports, 12 write ports
//==============================================================================

module superh16_regfile
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Read ports (24 total: 12 instructions × average 2 sources)
    input  logic                                    read_enable [24],
    input  logic [PHYS_REG_BITS-1:0]                read_tag [24],
    output logic [XLEN-1:0]                         read_data [24],
    
    // Write ports (12 total: 12 instructions can complete per cycle)
    input  logic                                    write_enable [ISSUE_WIDTH],
    input  logic [PHYS_REG_BITS-1:0]                write_tag [ISSUE_WIDTH],
    input  logic [XLEN-1:0]                         write_data [ISSUE_WIDTH],
    
    // Bypass network (forward results before write)
    output logic [XLEN-1:0]                         bypassed_data [24]
);

    //==========================================================================
    // Cluster assignment
    // Cluster 0: Physical regs 0-383
    // Cluster 1: Physical regs 384-767
    //==========================================================================
    
    localparam int CLUSTER_SIZE = NUM_PHYS_REGS / 2;
    
    // Determine which cluster each tag belongs to
    function automatic logic get_cluster(logic [PHYS_REG_BITS-1:0] tag);
        return tag[PHYS_REG_BITS-1];  // MSB determines cluster
    endfunction
    
    //==========================================================================
    // Register file storage (2 clusters)
    //==========================================================================
    
    logic [XLEN-1:0] rf_cluster0 [CLUSTER_SIZE];
    logic [XLEN-1:0] rf_cluster1 [CLUSTER_SIZE];
    
    // Physical register 0 is always zero (x0 mapping)
    assign rf_cluster0[0] = '0;
    
    //==========================================================================
    // Read ports (combinational read)
    //==========================================================================
    
    logic [XLEN-1:0] read_data_raw [24];
    
    always_comb begin
        for (int i = 0; i < 24; i++) begin
            if (read_enable[i]) begin
                logic cluster;
                logic [PHYS_REG_BITS-2:0] cluster_idx;
                
                cluster = get_cluster(read_tag[i]);
                cluster_idx = read_tag[i][PHYS_REG_BITS-2:0];
                
                if (cluster == 0) begin
                    read_data_raw[i] = rf_cluster0[cluster_idx];
                end else begin
                    read_data_raw[i] = rf_cluster1[cluster_idx];
                end
            end else begin
                read_data_raw[i] = '0;
            end
        end
    end
    
    //==========================================================================
    // Bypass network
    // If a read port is reading a tag that's being written this cycle,
    // bypass the write data directly (avoids 1-cycle bubble)
    //==========================================================================
    
    always_comb begin
        for (int r = 0; r < 24; r++) begin
            logic bypass_hit;
            logic [XLEN-1:0] bypass_data;
            
            bypass_hit = 1'b0;
            bypass_data = '0;
            
            // Check all write ports for matching tag
            for (int w = 0; w < ISSUE_WIDTH; w++) begin
                if (write_enable[w] && read_enable[r] && 
                    (write_tag[w] == read_tag[r])) begin
                    bypass_hit = 1'b1;
                    bypass_data = write_data[w];
                end
            end
            
            // Select bypassed or raw data
            if (bypass_hit) begin
                bypassed_data[r] = bypass_data;
            end else begin
                bypassed_data[r] = read_data_raw[r];
            end
        end
    end
    
    assign read_data = bypassed_data;
    
    //==========================================================================
    // Write ports (registered write)
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Initialize to zero
            for (int i = 0; i < CLUSTER_SIZE; i++) begin
                rf_cluster0[i] <= '0;
                rf_cluster1[i] <= '0;
            end
        end else begin
            // Process all write ports
            for (int i = 0; i < ISSUE_WIDTH; i++) begin
                if (write_enable[i]) begin
                    logic cluster;
                    logic [PHYS_REG_BITS-2:0] cluster_idx;
                    
                    cluster = get_cluster(write_tag[i]);
                    cluster_idx = write_tag[i][PHYS_REG_BITS-2:0];
                    
                    // Don't write to physical register 0 (hardwired zero)
                    if (write_tag[i] != 0) begin
                        if (cluster == 0) begin
                            rf_cluster0[cluster_idx] <= write_data[i];
                        end else begin
                            rf_cluster1[cluster_idx] <= write_data[i];
                        end
                    end
                end
            end
        end
    end
    
    //==========================================================================
    // Assertions
    //==========================================================================
    
    `ifdef SIMULATION
        // Check no duplicate writes to same tag
        always_ff @(posedge clk) begin
            if (rst_n) begin
                for (int i = 0; i < ISSUE_WIDTH; i++) begin
                    for (int j = i+1; j < ISSUE_WIDTH; j++) begin
                        if (write_enable[i] && write_enable[j]) begin
                            assert(write_tag[i] != write_tag[j])
                                else $error("Duplicate write to tag %d", write_tag[i]);
                        end
                    end
                end
            end
        end
        
        // Check physical reg 0 stays zero
        always_ff @(posedge clk) begin
            if (rst_n) begin
                assert(rf_cluster0[0] == 0)
                    else $error("Physical register 0 is not zero!");
            end
        end
    `endif

endmodule : superh16_regfile