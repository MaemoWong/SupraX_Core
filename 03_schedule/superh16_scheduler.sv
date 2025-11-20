//==============================================================================
// File: 03_schedule/superh16_scheduler.sv
// Description: Main scheduler - integrates 3 banks and issue arbitration
// 192 total entries (3 banks × 64 entries)
// 12 total issues per cycle (3 banks × 4 issues)
//==============================================================================

module superh16_scheduler
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Allocation from rename (12 per cycle)
    input  logic                                    alloc_valid [ISSUE_WIDTH],
    input  renamed_inst_t                           alloc_inst [ISSUE_WIDTH],
    output logic                                    alloc_ready,
    
    // Wakeup from execution units (24 tags per cycle)
    input  logic                                    wakeup_valid [WAKEUP_PORTS],
    input  logic [PHYS_REG_BITS-1:0]                wakeup_tag [WAKEUP_PORTS],
    
    // Issue to execution units (12 per cycle)
    output logic                                    issue_valid [ISSUE_WIDTH],
    output micro_op_t                               issue_uop [ISSUE_WIDTH],
    
    // Register file read requests
    output logic [PHYS_REG_BITS-1:0]                rf_read_tag [ISSUE_WIDTH*3],  // 3 sources
    input  logic [XLEN-1:0]                         rf_read_data [ISSUE_WIDTH*3],
    
    // Flush from ROB
    input  logic                                    flush,
    input  logic [ROB_IDX_BITS-1:0]                 flush_rob_idx
);

    //==========================================================================
    // Bank instantiation (3 banks)
    //==========================================================================
    
    logic bank_alloc_valid [SCHED_BANKS][4];
    renamed_inst_t bank_alloc_inst [SCHED_BANKS][4];
    logic bank_alloc_ready [SCHED_BANKS];
    
    logic bank_issue_valid [SCHED_BANKS][4];
    logic [5:0] bank_issue_index [SCHED_BANKS][4];
    micro_op_t bank_issue_uop [SCHED_BANKS][4];
    
    generate
        for (genvar b = 0; b < SCHED_BANKS; b++) begin : gen_banks
            superh16_sched_bank #(
                .BANK_ID(b)
            ) bank (
                .clk,
                .rst_n,
                .alloc_valid        (bank_alloc_valid[b]),
                .alloc_inst         (bank_alloc_inst[b]),
                .alloc_ready        (bank_alloc_ready[b]),
                .wakeup_valid,
                .wakeup_tag,
                .issue_valid        (bank_issue_valid[b]),
                .issue_index        (bank_issue_index[b]),
                .issue_uop          (bank_issue_uop[b]),
                .flush,
                .flush_rob_idx
            );
        end
    endgenerate
    
    // Scheduler is ready if all banks can accept allocations
    assign alloc_ready = &bank_alloc_ready;
    
    //==========================================================================
    // Allocation distribution (round-robin across banks)
    // Distribute 12 allocations across 3 banks (4 per bank)
    //==========================================================================
    
    always_comb begin
        // Initialize
        for (int b = 0; b < SCHED_BANKS; b++) begin
            for (int i = 0; i < 4; i++) begin
                bank_alloc_valid[b][i] = 1'b0;
                bank_alloc_inst[b][i] = '{default: '0};
            end
        end
        
        // Distribute allocations
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            int bank = i / 4;  // Bank 0: inst 0-3, Bank 1: inst 4-7, Bank 2: inst 8-11
            int slot = i % 4;  // Slot within bank
            
            bank_alloc_valid[bank][slot] = alloc_valid[i] && alloc_ready;
            bank_alloc_inst[bank][slot] = alloc_inst[i];
        end
    end
    
    //==========================================================================
    // Issue collection and arbitration
    // Each bank provides 4 issues → 12 total
    // Directly map bank outputs to issue outputs (no arbitration needed!)
    //==========================================================================
    
    always_comb begin
        for (int b = 0; b < SCHED_BANKS; b++) begin
            for (int i = 0; i < 4; i++) begin
                int issue_slot = b * 4 + i;
                issue_valid[issue_slot] = bank_issue_valid[b][i];
                issue_uop[issue_slot] = bank_issue_uop[b][i];
            end
        end
    end
    
    //==========================================================================
    // Register file read port assignment
    // Each issued instruction needs 0-3 source operands
    //==========================================================================
    
    always_comb begin
        int rf_port = 0;
        
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            if (issue_valid[i]) begin
                // Source 1
                if (issue_uop[i].src1_valid) begin
                    rf_read_tag[rf_port] = issue_uop[i].src1_tag;
                    rf_port++;
                end
                
                // Source 2
                if (issue_uop[i].src2_valid) begin
                    rf_read_tag[rf_port] = issue_uop[i].src2_tag;
                    rf_port++;
                end
                
                // Source 3
                if (issue_uop[i].src3_valid) begin
                    rf_read_tag[rf_port] = issue_uop[i].src3_tag;
                    rf_port++;
                end
            end
        end
        
        // Fill remaining ports with zeros
        for (int i = rf_port; i < ISSUE_WIDTH*3; i++) begin
            rf_read_tag[i] = '0;
        end
    end
    
    //==========================================================================
    // Performance counters
    //==========================================================================
    
    logic [31:0] cycle_counter;
    logic [31:0] issue_counter;
    logic [31:0] stall_counter;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_counter <= '0;
            issue_counter <= '0;
            stall_counter <= '0;
        end else begin
            cycle_counter <= cycle_counter + 1;
            
            // Count issued instructions
            for (int i = 0; i < ISSUE_WIDTH; i++) begin
                if (issue_valid[i]) issue_counter <= issue_counter + 1;
            end
            
            // Count stall cycles (no issues)
            if (!(|issue_valid)) stall_counter <= stall_counter + 1;
        end
    end

endmodule : superh16_scheduler