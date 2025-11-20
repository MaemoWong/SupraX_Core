//==============================================================================
// File: 06_memory/superh16_dtlb.sv
// Description: Data Translation Lookaside Buffer (128 entries, fully assoc)
// Supports 4KB, 2MB, 1GB pages
//==============================================================================

module superh16_dtlb
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Lookup request
    input  logic                                    req_valid,
    input  logic [VADDR_WIDTH-1:0]                  req_vaddr,
    
    // Lookup response
    output logic                                    resp_hit,
    output logic [PADDR_WIDTH-1:0]                  resp_paddr,
    output logic                                    resp_exception,
    output logic [7:0]                              resp_exc_code,
    
    // Page table walk interface
    output logic                                    ptw_req,
    output logic [VADDR_WIDTH-1:0]                  ptw_vaddr,
    input  logic                                    ptw_ack,
    input  logic [PADDR_WIDTH-1:0]                  ptw_paddr,
    input  logic [1:0]                              ptw_page_size,  // 0=4K, 1=2M, 2=1G
    input  logic                                    ptw_valid,
    input  logic                                    ptw_readable,
    input  logic                                    ptw_writable,
    input  logic                                    ptw_executable,
    
    // Flush
    input  logic                                    flush,
    input  logic [VADDR_WIDTH-1:0]                  flush_vaddr,
    input  logic                                    flush_all
);

    //==========================================================================
    // TLB entry structure
    //==========================================================================
    
    typedef struct packed {
        logic                       valid;
        logic [VADDR_WIDTH-1:0]     vpn;          // Virtual page number
        logic [PADDR_WIDTH-1:0]     ppn;          // Physical page number
        logic [1:0]                 page_size;    // 0=4KB, 1=2MB, 2=1GB
        logic                       readable;
        logic                       writable;
        logic                       executable;
        logic                       user;
        logic                       global;
        logic [2:0]                 lru_counter;
    } dtlb_entry_t;
    
    localparam int NUM_ENTRIES = 128;
    dtlb_entry_t tlb_entries [NUM_ENTRIES];
    
    //==========================================================================
    // Page size masks
    //==========================================================================
    
    function automatic logic [VADDR_WIDTH-1:0] get_page_mask(
        input logic [1:0] page_size
    );
        case (page_size)
            2'b00: return 64'h0000_0000_0000_0FFF;  // 4KB
            2'b01: return 64'h0000_0000_001F_FFFF;  // 2MB
            2'b10: return 64'h0000_0000_3FFF_FFFF;  // 1GB
            default: return 64'h0000_0000_0000_0FFF;
        endcase
    endfunction
    
    //==========================================================================
    // TLB lookup (fully associative)
    //==========================================================================
    
    logic [NUM_ENTRIES-1:0] entry_match;
    logic hit;
    logic [$clog2(NUM_ENTRIES)-1:0] hit_index;
    
    always_comb begin
        // Check all entries in parallel
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            logic [VADDR_WIDTH-1:0] page_mask;
            logic [VADDR_WIDTH-1:0] req_vpn;
            logic [VADDR_WIDTH-1:0] entry_vpn;
            
            page_mask = get_page_mask(tlb_entries[i].page_size);
            req_vpn = req_vaddr & ~page_mask;
            entry_vpn = tlb_entries[i].vpn & ~page_mask;
            
            entry_match[i] = tlb_entries[i].valid && (req_vpn == entry_vpn);
        end
        
        // Priority encoder to find hit
        hit = |entry_match;
        hit_index = '0;
        for (int i = NUM_ENTRIES-1; i >= 0; i--) begin
            if (entry_match[i]) hit_index = i[$clog2(NUM_ENTRIES)-1:0];
        end
    end
    
    //==========================================================================
    // Physical address translation
    //==========================================================================
    
    logic [VADDR_WIDTH-1:0] page_offset;
    logic [PADDR_WIDTH-1:0] translated_paddr;
    
    always_comb begin
        if (hit) begin
            logic [VADDR_WIDTH-1:0] page_mask;
            page_mask = get_page_mask(tlb_entries[hit_index].page_size);
            page_offset = req_vaddr & page_mask;
            translated_paddr = tlb_entries[hit_index].ppn | page_offset;
        end else begin
            translated_paddr = '0;
        end
    end
    
    //==========================================================================
    // Response generation
    //==========================================================================
    
    assign resp_hit = req_valid && hit;
    assign resp_paddr = translated_paddr;
    
    // Exception handling (access permissions)
    always_comb begin
        resp_exception = 1'b0;
        resp_exc_code = 8'd0;
        
        if (req_valid && hit) begin
            // Check for access violations
            if (!tlb_entries[hit_index].readable) begin
                resp_exception = 1'b1;
                resp_exc_code = 8'd13;  // Load page fault
            end
            // Additional permission checks would go here
        end else if (req_valid && !hit) begin
            // TLB miss - trigger page table walk
            resp_exception = 1'b0;  // Not an exception, just a miss
        end
    end
    
    //==========================================================================
    // Page table walk request
    //==========================================================================
    
    assign ptw_req = req_valid && !hit;
    assign ptw_vaddr = req_vaddr;
    
    //==========================================================================
    // TLB fill (on page table walk completion)
    //==========================================================================
    
    logic [$clog2(NUM_ENTRIES)-1:0] replace_index;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                tlb_entries[i].valid <= 1'b0;
                tlb_entries[i].lru_counter <= '0;
            end
            replace_index <= '0;
        end else if (flush_all) begin
            // Invalidate all entries
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                tlb_entries[i].valid <= 1'b0;
            end
        end else if (flush) begin
            // Invalidate specific entry
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                if (tlb_entries[i].valid) begin
                    logic [VADDR_WIDTH-1:0] page_mask;
                    logic [VADDR_WIDTH-1:0] flush_vpn;
                    logic [VADDR_WIDTH-1:0] entry_vpn;
                    
                    page_mask = get_page_mask(tlb_entries[i].page_size);
                    flush_vpn = flush_vaddr & ~page_mask;
                    entry_vpn = tlb_entries[i].vpn & ~page_mask;
                    
                    if (flush_vpn == entry_vpn) begin
                        tlb_entries[i].valid <= 1'b0;
                    end
                end
            end
        end else if (ptw_ack && ptw_valid) begin
            // Fill TLB with new translation
            // Simple replacement: round-robin
            tlb_entries[replace_index].valid <= 1'b1;
            tlb_entries[replace_index].vpn <= ptw_vaddr;
            tlb_entries[replace_index].ppn <= ptw_paddr;
            tlb_entries[replace_index].page_size <= ptw_page_size;
            tlb_entries[replace_index].readable <= ptw_readable;
            tlb_entries[replace_index].writable <= ptw_writable;
            tlb_entries[replace_index].executable <= ptw_executable;
            
            replace_index <= replace_index + 1;
        end
    end

endmodule : superh16_dtlb