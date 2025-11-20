//==============================================================================
// File: 01_frontend/superh16_icache.sv
// Description: L1 Instruction Cache (96KB, 6-way set associative)
// 2-cycle hit latency
//==============================================================================

module superh16_icache
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Request interface
    input  logic                                    req_valid,
    input  logic [VADDR_WIDTH-1:0]                  req_addr,
    
    // Response interface
    output logic                                    resp_valid,
    output logic [511:0]                            resp_data,  // 64 bytes
    output logic                                    resp_miss,
    
    // L2 interface
    output logic                                    l2_req,
    output logic [VADDR_WIDTH-1:0]                  l2_addr,
    input  logic                                    l2_ack,
    input  logic [511:0]                            l2_data
);

    //==========================================================================
    // Cache parameters
    //==========================================================================
    
    localparam int CACHE_SIZE = ICACHE_SIZE_KB * 1024;
    localparam int LINE_SIZE = 64;  // 64 bytes per line
    localparam int NUM_WAYS = 6;
    localparam int NUM_SETS = CACHE_SIZE / (LINE_SIZE * NUM_WAYS);
    
    localparam int OFFSET_BITS = $clog2(LINE_SIZE);
    localparam int INDEX_BITS = $clog2(NUM_SETS);
    localparam int TAG_BITS = VADDR_WIDTH - INDEX_BITS - OFFSET_BITS;
    
    //==========================================================================
    // Cache storage
    //==========================================================================
    
    typedef struct packed {
        logic                   valid;
        logic [TAG_BITS-1:0]    tag;
        logic [511:0]           data;  // 64 bytes = 512 bits
        logic [2:0]             lru_counter;
    } icache_line_t;
    
    icache_line_t cache [NUM_SETS][NUM_WAYS];
    
    //==========================================================================
    // Address breakdown
    //==========================================================================
    
    logic [TAG_BITS-1:0]    req_tag;
    logic [INDEX_BITS-1:0]  req_index;
    
    assign req_tag = req_addr[VADDR_WIDTH-1 : INDEX_BITS+OFFSET_BITS];
    assign req_index = req_addr[INDEX_BITS+OFFSET_BITS-1 : OFFSET_BITS];
    
    //==========================================================================
    // Stage 1: Tag lookup
    //==========================================================================
    
    logic                       s1_valid;
    logic [TAG_BITS-1:0]        s1_tag;
    logic [INDEX_BITS-1:0]      s1_index;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid <= req_valid;
            s1_tag <= req_tag;
            s1_index <= req_index;
        end
    end
    
    //==========================================================================
    // Stage 2: Tag comparison and data read
    //==========================================================================
    
    logic [NUM_WAYS-1:0] way_hit;
    logic hit;
    logic [2:0] hit_way;
    
    always_comb begin
        for (int w = 0; w < NUM_WAYS; w++) begin
            way_hit[w] = cache[s1_index][w].valid && 
                        (cache[s1_index][w].tag == s1_tag);
        end
        
        hit = |way_hit;
        hit_way = 3'd0;
        for (int w = NUM_WAYS-1; w >= 0; w--) begin
            if (way_hit[w]) hit_way = w[2:0];
        end
    end
    
    logic [511:0] hit_data;
    assign hit_data = cache[s1_index][hit_way].data;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_valid <= 1'b0;
        end else begin
            resp_valid <= s1_valid;
            resp_data <= hit_data;
            resp_miss <= !hit;
        end
    end
    
    //==========================================================================
    // Miss handling
    //==========================================================================
    
    assign l2_req = s1_valid && !hit;
    assign l2_addr = {s1_tag, s1_index, {OFFSET_BITS{1'b0}}};
    
    // Fill on L2 response
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < NUM_SETS; s++) begin
                for (int w = 0; w < NUM_WAYS; w++) begin
                    cache[s][w].valid <= 1'b0;
                end
            end
        end else if (l2_ack) begin
            // Simple replacement: use way 0
            cache[s1_index][0].valid <= 1'b1;
            cache[s1_index][0].tag <= s1_tag;
            cache[s1_index][0].data <= l2_data;
        end
    end

endmodule : superh16_icache