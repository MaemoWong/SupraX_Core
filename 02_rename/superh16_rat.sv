//==============================================================================
// File: 02_rename/superh16_rat.sv
// Description: Register Alias Table for register renaming
// Maps architectural registers to physical registers
// Supports checkpointing for branch speculation recovery
//==============================================================================

module superh16_rat
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Lookup (read) ports - 12 instructions × 3 sources max = 36 reads
    input  logic [ARCH_REG_BITS-1:0]                lookup_arch_reg [ISSUE_WIDTH*3],
    output logic [PHYS_REG_BITS-1:0]                lookup_phys_reg [ISSUE_WIDTH*3],
    
    // Update (write) ports - 12 instructions per cycle
    input  logic                                    update_valid [ISSUE_WIDTH],
    input  logic [ARCH_REG_BITS-1:0]                update_arch_reg [ISSUE_WIDTH],
    input  logic [PHYS_REG_BITS-1:0]                update_phys_reg [ISSUE_WIDTH],
    output logic [PHYS_REG_BITS-1:0]                update_old_phys_reg [ISSUE_WIDTH],
    
    // Checkpoint creation (for branch speculation)
    input  logic                                    checkpoint_create,
    input  logic [1:0]                              checkpoint_id,
    
    // Checkpoint restore (on branch misprediction)
    input  logic                                    checkpoint_restore,
    input  logic [1:0]                              restore_checkpoint_id,
    
    // Full flush (on exception)
    input  logic                                    flush
);

    //==========================================================================
    // RAT storage
    // One entry per architectural register
    //==========================================================================
    
    logic [PHYS_REG_BITS-1:0] rat [NUM_ARCH_REGS];
    
    // Checkpointed RAT state (4 checkpoints for nested speculation)
    logic [PHYS_REG_BITS-1:0] rat_checkpoint [4][NUM_ARCH_REGS];
    
    //==========================================================================
    // Lookup (combinational read)
    //==========================================================================
    
    always_comb begin
        for (int i = 0; i < ISSUE_WIDTH*3; i++) begin
            // Register 0 always maps to physical register 0 (hardwired zero)
            if (lookup_arch_reg[i] == 0) begin
                lookup_phys_reg[i] = '0;
            end else begin
                lookup_phys_reg[i] = rat[lookup_arch_reg[i]];
            end
        end
    end
    
    //==========================================================================
    // Update (sequential write with bypass)
    //==========================================================================
    
    always_comb begin
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            // Read old mapping before update
            update_old_phys_reg[i] = rat[update_arch_reg[i]];
        end
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Initialize RAT: arch reg i → phys reg i
            for (int i = 0; i < NUM_ARCH_REGS; i++) begin
                rat[i] <= i[PHYS_REG_BITS-1:0];
            end
            
            // Initialize checkpoints
            for (int c = 0; c < 4; c++) begin
                for (int i = 0; i < NUM_ARCH_REGS; i++) begin
                    rat_checkpoint[c][i] <= i[PHYS_REG_BITS-1:0];
                end
            end
        end
        else if (flush) begin
            // Reset to identity mapping on flush
            for (int i = 0; i < NUM_ARCH_REGS; i++) begin
                rat[i] <= i[PHYS_REG_BITS-1:0];
            end
        end
        else if (checkpoint_restore) begin
            // Restore from checkpoint
            for (int i = 0; i < NUM_ARCH_REGS; i++) begin
                rat[i] <= rat_checkpoint[restore_checkpoint_id][i];
            end
        end
        else begin
            // Create checkpoint if requested
            if (checkpoint_create) begin
                for (int i = 0; i < NUM_ARCH_REGS; i++) begin
                    rat_checkpoint[checkpoint_id][i] <= rat[i];
                end
            end
            
            // Normal update
            for (int i = 0; i < ISSUE_WIDTH; i++) begin
                if (update_valid[i] && update_arch_reg[i] != 0) begin
                    rat[update_arch_reg[i]] <= update_phys_reg[i];
                end
            end
        end
    end
    
    //==========================================================================
    // Bypass logic (read-after-write within same cycle)
    // If we're updating a register that's being read this cycle,
    // bypass the new mapping
    //==========================================================================
    
    // Note: This is handled implicitly by having lookup as combinational
    // and update as sequential. The lookup will see the old value,
    // which is correct for the current cycle's instructions.

endmodule : superh16_rat