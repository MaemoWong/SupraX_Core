//==============================================================================
// File: 06_memory/superh16_l2_cache.sv
// Description: L2 Cache (448KB, 8-way, private per core)
// 12-cycle hit latency
//==============================================================================

module superh16_l2_cache
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Request from L1 I-cache
    input  logic                                    icache_req,
    input  logic [VADDR_WIDTH-1:0]                  icache_addr,
    output logic                                    icache_ack,
    output logic [511:0]                            icache_data,
    
    // Request from L1 D-cache
    input  logic                                    dcache_req,
    input  logic [VADDR_WIDTH-1:0]                  dcache_addr,
    output logic                                    dcache_ack,
    output logic [CACHE_LINE_SIZE*8-1:0]            dcache_data,
    
    // Interface to memory system / L3
    output logic                                    mem_req,
    output logic [PADDR_WIDTH-1:0]                  mem_addr,
    output logic                                    mem_we,
    output logic [CACHE_LINE_SIZE*8-1:0]            mem_wdata,
    input  logic                                    mem_ack,
    input  logic [CACHE_LINE_SIZE*8-1:0]            mem_rdata
);

    //==========================================================================
    // L2 Cache parameters
    //==========================================================================
    
    localparam int CACHE_SIZE = L2_CACHE_SIZE_KB * 1024;
    localparam int LINE_SIZE = CACHE_LINE_SIZE;
    localparam int NUM_WAYS = 8;
    localparam int NUM_SETS = CACHE_SIZE / (LINE_SIZE * NUM_WAYS);
    
    localparam int OFFSET_BITS = $clog2(LINE_SIZE);
    localparam int INDEX_BITS = $clog2(NUM_SETS);
    localparam int TAG_BITS = VADDR_WIDTH - INDEX_BITS - OFFSET_BITS;
    
    //==========================================================================
    // Cache storage
    //==========================================================================
    
    typedef struct packed {
        logic                       valid;
        logic                       dirty;
        logic [TAG_BITS-1:0]        tag;
        logic [LINE_SIZE*8-1:0]     data;
        logic [2:0]                 lru_counter;
    } l2_cache_line_t;
    
    l2_cache_line_t cache [NUM_SETS][NUM_WAYS];
    
    //==========================================================================
    // Arbitrate between I-cache and D-cache requests
    // Priority: D-cache > I-cache (data is more critical)
    //==========================================================================
    
    logic                       arb_req;
    logic [VADDR_WIDTH-1:0]     arb_addr;
    logic                       arb_is_icache;
    
    always_comb begin
        if (dcache_req) begin
            arb_req = 1'b1;
            arb_addr = dcache_addr;
            arb_is_icache = 1'b0;
        end else if (icache_req) begin
            arb_req = 1'b1;
            arb_addr = icache_addr;
            arb_is_icache = 1'b1;
        end else begin
            arb_req = 1'b0;
            arb_addr = '0;
            arb_is_icache = 1'b0;
        end
    end
    
    //==========================================================================
    // Multi-cycle pipeline for L2 access
    // 12 cycles total: 2 tag + 8 data read + 2 response
    //==========================================================================
    
    typedef struct packed {
        logic                       valid;
        logic                       is_icache;
        logic [TAG_BITS-1:0]        tag;
        logic [INDEX_BITS-1:0]      index;
    } l2_pipeline_t;
    
    l2_pipeline_t pipe_stages [12];
    
    // Stage 0-1: Tag lookup
    logic [TAG_BITS-1:0]    req_tag;
    logic [INDEX_BITS-1:0]  req_index;
    
    assign req_tag = arb_addr[VADDR_WIDTH-1 : INDEX_BITS+OFFSET_BITS];
    assign req_index = arb_addr[INDEX_BITS+OFFSET_BITS-1 : OFFSET_BITS];
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_stages[0].valid <= 1'b0;
        end else begin
            pipe_stages[0].valid <= arb_req;
            pipe_stages[0].is_icache <= arb_is_icache;
            pipe_stages[0].tag <= req_tag;
            pipe_stages[0].index <= req_index;
        end
    end
    
    // Tag comparison at stage 1
    logic [NUM_WAYS-1:0] way_hit_s1;
    logic hit_s1;
    logic [2:0] hit_way_s1;
    
    always_comb begin
        for (int w = 0; w < NUM_WAYS; w++) begin
            way_hit_s1[w] = cache[pipe_stages[0].index][w].valid && 
                           (cache[pipe_stages[0].index][w].tag == pipe_stages[0].tag);
        end
        
        hit_s1 = |way_hit_s1;
        hit_way_s1 = 3'd0;
        for (int w = NUM_WAYS-1; w >= 0; w--) begin
            if (way_hit_s1[w]) hit_way_s1 = w[2:0];
        end
    end
    
    // Pipeline stages 1-11
    generate
        for (genvar i = 1; i < 12; i++) begin : gen_pipe_stages
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    pipe_stages[i].valid <= 1'b0;
                end else begin
                    pipe_stages[i] <= pipe_stages[i-1];
                end
            end
        end
    endgenerate
    
    // Data read at final stage
    logic [LINE_SIZE*8-1:0] read_data;
    assign read_data = cache[pipe_stages[10].index][hit_way_s1].data;
    
    // Response
    assign icache_ack = pipe_stages[11].valid && pipe_stages[11].is_icache && hit_s1;
    assign icache_data = read_data;
    assign dcache_ack = pipe_stages[11].valid && !pipe_stages[11].is_icache && hit_s1;
    assign dcache_data = read_data;
    
    //==========================================================================
    // Miss handling (simplified)
    //==========================================================================
    
    assign mem_req = pipe_stages[11].valid && !hit_s1;
    assign mem_addr = {pipe_stages[11].tag, pipe_stages[11].index, {OFFSET_BITS{1'b0}}};
    assign mem_we = 1'b0;  // Read-only for now
    assign mem_wdata = '0;
    
    // Fill cache on memory response
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < NUM_SETS; s++) begin
                for (int w = 0; w < NUM_WAYS; w++) begin
                    cache[s][w].valid <= 1'b0;
                    cache[s][w].dirty <= 1'b0;
                end
            end
        end else if (mem_ack) begin
            // Fill cache (use way 0 for simplicity)
            cache[pipe_stages[11].index][0].valid <= 1'b1;
            cache[pipe_stages[11].index][0].tag <= pipe_stages[11].tag;
            cache[pipe_stages[11].index][0].data <= mem_rdata;
            cache[pipe_stages[11].index][0].dirty <= 1'b0;
        end
    end

endmodule : superh16_l2_cache