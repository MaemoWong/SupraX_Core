//==============================================================================
// File: superh16_core_tb.sv
// Description: Basic testbench for SuperH-16 core
//==============================================================================

module superh16_core_tb;

    import superh16_pkg::*;
    
    logic clk;
    logic rst_n;
    
    // Memory interface
    logic mem_req;
    logic [PADDR_WIDTH-1:0] mem_addr;
    logic mem_we;
    logic [CACHE_LINE_SIZE*8-1:0] mem_wdata;
    logic mem_ack;
    logic [CACHE_LINE_SIZE*8-1:0] mem_rdata;
    
    // Interrupts
    logic irq_external;
    logic irq_timer;
    logic irq_software;
    
    // Debug
    logic debug_halt_req;
    logic debug_halted;
    logic [VADDR_WIDTH-1:0] debug_pc;
    
    // Performance counters
    logic [63:0] perf_cycles;
    logic [63:0] perf_instructions_retired;
    logic [63:0] perf_branches;
    logic [63:0] perf_branch_mispredicts;
    
    //==========================================================================
    // DUT instantiation
    //==========================================================================
    
    superh16_core dut (
        .clk,
        .rst_n,
        .mem_req,
        .mem_addr,
        .mem_we,
        .mem_wdata,
        .mem_ack,
        .mem_rdata,
        .irq_external,
        .irq_timer,
        .irq_software,
        .debug_halt_req,
        .debug_halted,
        .debug_pc,
        .perf_cycles,
        .perf_instructions_retired,
        .perf_branches,
        .perf_branch_mispredicts
    );
    
    //==========================================================================
    // Clock generation (4.2 GHz = 238ps period)
    //==========================================================================
    
    initial clk = 0;
    always #0.119ns clk = ~clk;  // 119ps half-period
    
    //==========================================================================
    // Memory model (simple)
    //==========================================================================
    
    logic [7:0] memory [logic [PADDR_WIDTH-1:0]];
    
    always @(posedge clk) begin
        if (mem_req) begin
            mem_ack <= #10ns 1'b1;
            if (!mem_we) begin
                // Read
                for (int i = 0; i < CACHE_LINE_SIZE; i++) begin
                    mem_rdata[i*8 +: 8] <= memory[mem_addr + i];
                end
            end else begin
                // Write
                for (int i = 0; i < CACHE_LINE_SIZE; i++) begin
                    memory[mem_addr + i] <= mem_wdata[i*8 +: 8];
                end
            end
        end else begin
            mem_ack <= 1'b0;
        end
    end
    
    //==========================================================================
    // Test stimulus
    //==========================================================================
    
    initial begin
        $dumpfile("superh16_core.vcd");
        $dumpvars(0, superh16_core_tb);
        
        // Initialize
        rst_n = 0;
        irq_external = 0;
        irq_timer = 0;
        irq_software = 0;
        debug_halt_req = 0;
        
        // Load simple program into memory
        // (This would normally load from ELF file)
        for (int i = 0; i < 1024; i++) begin
            memory[64'h8000_0000 + i] = 8'h13;  // NOP (ADDI x0, x0, 0)
        end
        
        // Reset
        #100ns;
        rst_n = 1;
        
        // Run for some cycles
        #10us;
        
        // Print statistics
        $display("===========================================");
        $display("SuperH-16 Core Simulation Results");
        $display("===========================================");
        $display("Cycles:              %0d", perf_cycles);
        $display("Instructions:        %0d", perf_instructions_retired);
        $display("Branches:            %0d", perf_branches);
        $display("Branch Mispredicts:  %0d", perf_branch_mispredicts);
        
        if (perf_cycles > 0) begin
            real ipc;
            real mispredict_rate;
            ipc = real'(perf_instructions_retired) / real'(perf_cycles);
            if (perf_branches > 0) begin
                mispredict_rate = 100.0 * real'(perf_branch_mispredicts) / real'(perf_branches);
            end else begin
                mispredict_rate = 0.0;
            end
            $display("IPC:                 %.2f", ipc);
            $display("Mispredict Rate:     %.2f%%", mispredict_rate);
        end
        $display("===========================================");
        
        $finish;
    end

endmodule