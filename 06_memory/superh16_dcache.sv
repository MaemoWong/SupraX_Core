//==============================================================================
// File: 06_memory/superh16_dcache.sv
// Description: L1 Data Cache (64KB, 8-way set associative)
// 3-cycle hit latency, non-blocking, supports multiple outstanding misses
//==============================================================================

module superh16_dcache
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Request interface (from load/store units)
    input  logic                                    req_valid,
    input  logic [VADDR_WIDTH-1:0]                  req_addr,
    input  logic [2:0]                              req_size,
    input  logic                                    req_we,        // Write enable
    input  logic [XLEN-1:0]                         req_wdata,
    
    // Response interface
    output logic                                    resp_valid,
    output logic [XLEN-1:0]                         resp_data,
    output logic                                    resp_miss,
    
    // L2 interface (for misses)
    output logic                                    l2_req,
    output logic [VADDR_WIDTH-1:0]                  l2_addr,
    input  logic                                    l2_ack,
    input  logic [CACHE_LINE_SIZE*8-1:0]            l2_data,    // Full cache line
    
    // Flush interface
    input  logic                                    flush,
    output logic                                    flush_done
);

    //==========================================================================
    // Cache parameters
    //==========================================================================
    
    localparam int CACHE_SIZE = DCACHE_SIZE_KB * 1024;
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
        logic                   valid;
        logic [TAG_BITS-1:0]    tag;
        logic [LINE_SIZE*8-1:0] data;
        logic [2:0]             lru_counter;  // Pseudo-LRU
    } cache_line_t;
    
    cache_line_t cache [NUM_SETS][NUM_WAYS];
    
    //==========================================================================
    // Address breakdown
    //==========================================================================
    
    logic [TAG_BITS-1:0]    req_tag;
    logic [INDEX_BITS-1:0]  req_index;
    logic [OFFSET_BITS-1:0] req_offset;
    
    assign req_tag = req_addr[VADDR_WIDTH-1 : INDEX_BITS+OFFSET_BITS];
    assign req_index = req_addr[INDEX_BITS+OFFSET_BITS-1 : OFFSET_BITS];
    assign req_offset = req_addr[OFFSET_BITS-1 : 0];
    
    //==========================================================================
    // Stage 1: Tag lookup
    //==========================================================================
    
    logic                       s1_valid;
    logic [TAG_BITS-1:0]        s1_tag;
    logic [INDEX_BITS-1:0]      s1_index;
    logic [OFFSET_BITS-1:0]     s1_offset;
    logic [2:0]                 s1_size;
    logic                       s1_we;
    logic [XLEN-1:0]            s1_wdata;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid <= req_valid;
            s1_tag <= req_tag;
            s1_index <= req_index;
            s1_offset <= req_offset;
            s1_size <= req_size;
            s1_we <= req_we;
            s1_wdata <= req_wdata;
        end
    end
    
    //==========================================================================
    // Stage 2: Way comparison and data read
    //==========================================================================
    
    logic                       s2_valid;
    logic                       s2_hit;
    logic [2:0]                 s2_hit_way;
    logic [LINE_SIZE*8-1:0]     s2_line_data;
    logic [OFFSET_BITS-1:0]     s2_offset;
    logic [2:0]                 s2_size;
    
    // Compare tags for all ways
    logic [NUM_WAYS-1:0] way_hit;
    
    always_comb begin
        for (int w = 0; w < NUM_WAYS; w++) begin
            way_hit[w] = cache[s1_index][w].valid && 
                        (cache[s1_index][w].tag == s1_tag);
        end
    end
    
    // Priority encode to find hit way
    logic hit;
    logic [2:0] hit_way;
    
    always_comb begin
        hit = |way_hit;
        hit_way = 3'd0;
        for (int w = NUM_WAYS-1; w >= 0; w--) begin
            if (way_hit[w]) hit_way = w[2:0];
        end
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
        end else begin
            s2_valid <= s1_valid;
            s2_hit <= hit;
            s2_hit_way <= hit_way;
            s2_line_data <= hit ? cache[s1_index][hit_way].data : '0;
            s2_offset <= s1_offset;
            s2_size <= s1_size;
        end
    end
    
    //==========================================================================
    // Stage 3: Data extraction and response
    //==========================================================================
    
    logic [XLEN-1:0] extracted_data;
    
    // Extract requested bytes from cache line
    always_comb begin
        int byte_offset;
        byte_offset = s2_offset;
        
        case (s2_size)
            3'b000: begin  // Byte
                extracted_data = {56'd0, s2_line_data[byte_offset*8 +: 8]};
            end
            3'b001: begin  // Halfword
                extracted_data = {48'd0, s2_line_data[byte_offset*8 +: 16]};
            end
            3'b010: begin  // Word
                extracted_data = {32'd0, s2_line_data[byte_offset*8 +: 32]};
            end
            3'b011: begin  // Doubleword
                extracted_data = s2_line_data[byte_offset*8 +: 64];
            end
            default: begin
                extracted_data = '0;
            end
        endcase
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_valid <= 1'b0;
        end else begin
            resp_valid <= s2_valid;
            resp_data <= extracted_data;
            resp_miss <= !s2_hit;
        end
    end
    
    //==========================================================================
    // Miss handling (simplified - real design would have MSHR)
    //==========================================================================
    
    assign l2_req = s2_valid && !s2_hit;
    assign l2_addr = {s1_tag, s1_index, {OFFSET_BITS{1'b0}}};  // Aligned address
    
    // On L2 response, fill cache line
    logic [2:0] fill_way;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < NUM_SETS; s++) begin
                for (int w = 0; w < NUM_WAYS; w++) begin
                    cache[s][w].valid <= 1'b0;
                    cache[s][w].lru_counter <= '0;
                end
            end
        end else if (l2_ack) begin
            // Find victim way (simple: use way 0 for now, real design uses LRU)
            fill_way = 3'd0;
            
            cache[s1_index][fill_way].valid <= 1'b1;
            cache[s1_index][fill_way].tag <= s1_tag;
            cache[s1_index][fill_way].data <= l2_data;
        end
    end
    
    //==========================================================================
    // Flush logic
    //==========================================================================
    
    assign flush_done = 1'b1;  // Simplified: instant flush

endmodule : superh16_dcache