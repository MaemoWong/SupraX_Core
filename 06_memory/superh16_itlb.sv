//==============================================================================
// File: 06_memory/superh16_itlb.sv
// Description: Instruction TLB (64 entries, fully associative)
// Similar to DTLB but optimized for instruction fetches
//==============================================================================

module superh16_itlb
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
    input  logic [1:0]                              ptw_page_size,
    input  logic                                    ptw_valid,
    input  logic                                    ptw_executable,
    
    // Flush
    input  logic                                    flush_all
);

    //==========================================================================
    // TLB entry structure (simplified for I-TLB)
    //==========================================================================
    
    typedef struct packed {
        logic                       valid;
        logic [VADDR_WIDTH-1:0]     vpn;
        logic [PADDR_WIDTH-1:0]     ppn;
        logic [1:0]                 page_size;
        logic                       executable;
    } itlb_entry_t;
    
    localparam int NUM_ENTRIES = 64;
    itlb_entry_t tlb_entries [NUM_ENTRIES];
    
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
    // TLB lookup
    //==========================================================================
    
    logic [NUM_ENTRIES-1:0] entry_match;
    logic hit;
    logic [$clog2(NUM_ENTRIES)-1:0] hit_index;
    
    always_comb begin
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            logic [VADDR_WIDTH-1:0] page_mask;
            logic [VADDR_WIDTH-1:0] req_vpn;
            logic [VADDR_WIDTH-1:0] entry_vpn;
            
            page_mask = get_page_mask(tlb_entries[i].page_size);
            req_vpn = req_vaddr & ~page_mask;
            entry_vpn = tlb_entries[i].vpn & ~page_mask;
            
            entry_match[i] = tlb_entries[i].valid && (req_vpn == entry_vpn);
        end
        
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
    // Response
    //==========================================================================
    
    assign resp_hit = req_valid && hit;
    assign resp_paddr = translated_paddr;
    
    always_comb begin
        resp_exception = 1'b0;
        resp_exc_code = 8'd0;
        
        if (req_valid && hit && !tlb_entries[hit_index].executable) begin
            resp_exception = 1'b1;
            resp_exc_code = 8'd12;  // Instruction page fault
        end
    end
    
    //==========================================================================
    // Page table walk
    //==========================================================================
    
    assign ptw_req = req_valid && !hit;
    assign ptw_vaddr = req_vaddr;
    
    //==========================================================================
    // TLB fill
    //==========================================================================
    
    logic [$clog2(NUM_ENTRIES)-1:0] replace_index;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                tlb_entries[i].valid <= 1'b0;
            end
            replace_index <= '0;
        end else if (flush_all) begin
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                tlb_entries[i].valid <= 1'b0;
            end
        end else if (ptw_ack && ptw_valid) begin
            tlb_entries[replace_index].valid <= 1'b1;
            tlb_entries[replace_index].vpn <= ptw_vaddr;
            tlb_entries[replace_index].ppn <= ptw_paddr;
            tlb_entries[replace_index].page_size <= ptw_page_size;
            tlb_entries[replace_index].executable <= ptw_executable;
            
            replace_index <= replace_index + 1;
        end
    end

endmodule : superh16_itlb