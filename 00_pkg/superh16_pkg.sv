//==============================================================================
// File: 00_pkg/superh16_pkg.sv
// Description: Main package with all types, parameters, and constants
// Author: AI-Generated Production-Quality RTL
// Date: 2025
//==============================================================================

package superh16_pkg;

    //==========================================================================
    // GLOBAL PARAMETERS
    //==========================================================================
    
    // Core dimensions
    parameter int ISSUE_WIDTH = 12;           // 12-wide issue
    parameter int RETIRE_WIDTH = 12;          // 12-wide retire
    parameter int FETCH_WIDTH = 12;           // 12 instructions per cycle
    
    // Physical resources
    parameter int NUM_PHYS_INT_REGS = 384;    // Integer physical registers
    parameter int NUM_PHYS_FP_REGS = 384;     // FP physical registers
    parameter int NUM_PHYS_REGS = 768;        // Total physical registers
    parameter int NUM_ARCH_REGS = 32;         // Architectural registers (RISC-V)
    
    // Buffer sizes
    parameter int ROB_ENTRIES = 240;          // Reorder buffer entries
    parameter int SCHED_ENTRIES = 192;        // Scheduler entries
    parameter int SCHED_BANKS = 3;            // Number of scheduler banks
    parameter int SCHED_ENTRIES_PER_BANK = 64;// Entries per bank
    parameter int LOAD_QUEUE_ENTRIES = 32;    // Load queue depth
    parameter int STORE_QUEUE_ENTRIES = 24;   // Store queue depth
    
    // Wakeup network
    parameter int WAKEUP_PORTS = 24;          // Wakeup tags per cycle
    
    // Execution units
    parameter int NUM_INT_ALU = 6;            // Integer ALUs
    parameter int NUM_INT_MUL = 3;            // Integer multipliers
    parameter int NUM_LOAD_UNITS = 5;         // Load units
    parameter int NUM_STORE_UNITS = 2;        // Store units
    parameter int NUM_FP_UNITS = 5;           // FP/SIMD units
    parameter int NUM_VECTOR_UNITS = 2;       // Vector units
    parameter int NUM_BRANCH_UNITS = 1;       // Branch units
    
    // Cache parameters
    parameter int ICACHE_SIZE_KB = 96;        // I-cache size
    parameter int DCACHE_SIZE_KB = 64;        // D-cache size
    parameter int L2_CACHE_SIZE_KB = 448;     // L2 cache size
    parameter int CACHE_LINE_SIZE = 64;       // Cache line size (bytes)
    
    // Address widths
    parameter int VADDR_WIDTH = 64;           // Virtual address width
    parameter int PADDR_WIDTH = 56;           // Physical address width (3nm supports 56-bit)
    
    // Data widths
    parameter int XLEN = 64;                  // Register width (64-bit RISC-V)
    parameter int VECTOR_LEN = 256;           // Vector register width
    
    // Timing parameters
    parameter int BRANCH_MISPREDICT_PENALTY = 10; // Cycles
    parameter int L1_HIT_LATENCY = 3;         // Cycles from address gen
    parameter int L2_HIT_LATENCY = 12;        // Cycles from L1 miss
    
    //==========================================================================
    // BIT FIELD WIDTHS
    //==========================================================================
    
    parameter int PHYS_REG_BITS = $clog2(NUM_PHYS_REGS);      // 10 bits
    parameter int ARCH_REG_BITS = $clog2(NUM_ARCH_REGS);      // 5 bits
    parameter int ROB_IDX_BITS = $clog2(ROB_ENTRIES);         // 8 bits
    parameter int SCHED_IDX_BITS = $clog2(SCHED_ENTRIES);     // 8 bits
    parameter int SCHED_BANK_BITS = $clog2(SCHED_BANKS);      // 2 bits
    parameter int SCHED_BANK_IDX_BITS = $clog2(SCHED_ENTRIES_PER_BANK); // 6 bits
    parameter int LQ_IDX_BITS = $clog2(LOAD_QUEUE_ENTRIES);   // 5 bits
    parameter int SQ_IDX_BITS = $clog2(STORE_QUEUE_ENTRIES);  // 5 bits
    
    // Chain depth bits (max chain depth = 127)
    parameter int CHAIN_DEPTH_BITS = 7;
    
    //==========================================================================
    // ENUMERATIONS
    //==========================================================================
    
    // Execution unit types
    typedef enum logic [3:0] {
        EXEC_INT_ALU    = 4'd0,
        EXEC_INT_MUL    = 4'd1,
        EXEC_INT_DIV    = 4'd2,
        EXEC_LOAD       = 4'd3,
        EXEC_STORE      = 4'd4,
        EXEC_BRANCH     = 4'd5,
        EXEC_FP_ADD     = 4'd6,
        EXEC_FP_MUL     = 4'd7,
        EXEC_FP_FMA     = 4'd8,
        EXEC_FP_DIV     = 4'd9,
        EXEC_VECTOR     = 4'd10,
        EXEC_CRYPTO     = 4'd11,
        EXEC_NONE       = 4'd15
    } exec_unit_t;
    
    // Micro-op types
    typedef enum logic [6:0] {
        // Integer ALU
        UOP_ADD         = 7'd0,
        UOP_SUB         = 7'd1,
        UOP_AND         = 7'd2,
        UOP_OR          = 7'd3,
        UOP_XOR         = 7'd4,
        UOP_SLL         = 7'd5,
        UOP_SRL         = 7'd6,
        UOP_SRA         = 7'd7,
        UOP_SLT         = 7'd8,
        UOP_SLTU        = 7'd9,
        
        // Integer multiply/divide
        UOP_MUL         = 7'd10,
        UOP_MULH        = 7'd11,
        UOP_MULHU       = 7'd12,
        UOP_MULHSU      = 7'd13,
        UOP_DIV         = 7'd14,
        UOP_DIVU        = 7'd15,
        UOP_REM         = 7'd16,
        UOP_REMU        = 7'd17,
        
        // Load/Store
        UOP_LOAD        = 7'd20,
        UOP_STORE       = 7'd21,
        
        // Branch/Jump
        UOP_BEQ         = 7'd30,
        UOP_BNE         = 7'd31,
        UOP_BLT         = 7'd32,
        UOP_BGE         = 7'd33,
        UOP_BLTU        = 7'd34,
        UOP_BGEU        = 7'd35,
        UOP_JAL         = 7'd36,
        UOP_JALR        = 7'd37,
        
        // FP operations
        UOP_FADD        = 7'd40,
        UOP_FSUB        = 7'd41,
        UOP_FMUL        = 7'd42,
        UOP_FDIV        = 7'd43,
        UOP_FSQRT       = 7'd44,
        UOP_FMA         = 7'd45,
        
        // Vector
        UOP_VADD        = 7'd50,
        UOP_VSUB        = 7'd51,
        UOP_VMUL        = 7'd52,
        
        // System
        UOP_NOP         = 7'd127
    } uop_opcode_t;
    
    // Branch prediction outcome
    typedef enum logic [1:0] {
        PRED_NOT_TAKEN  = 2'b00,
        PRED_TAKEN      = 2'b01,
        PRED_CALL       = 2'b10,
        PRED_RETURN     = 2'b11
    } branch_pred_t;
    
    //==========================================================================
    // STRUCTURES
    //==========================================================================
    
    // Micro-op structure (compact encoding for scheduler)
    typedef struct packed {
        logic                           valid;
        uop_opcode_t                    opcode;
        logic [PHYS_REG_BITS-1:0]       src1_tag;
        logic [PHYS_REG_BITS-1:0]       src2_tag;
        logic [PHYS_REG_BITS-1:0]       src3_tag;    // For FMA, stores
        logic [PHYS_REG_BITS-1:0]       dst_tag;
        logic                           src1_valid;
        logic                           src2_valid;
        logic                           src3_valid;
        logic                           src1_ready;
        logic                           src2_ready;
        logic                           src3_ready;
        logic [CHAIN_DEPTH_BITS-1:0]    chain_depth; // NOVEL: priority metric
        logic [ROB_IDX_BITS-1:0]        rob_idx;
        exec_unit_t                     exec_unit;
        logic [15:0]                    imm;         // Immediate value
        logic                           is_load;
        logic                           is_store;
        logic                           is_branch;
        logic                           is_fence;
    } micro_op_t;
    
    // Decoded instruction (wider format for decode stage)
    typedef struct packed {
        logic                           valid;
        logic [VADDR_WIDTH-1:0]         pc;
        logic [31:0]                    inst;        // Raw instruction
        uop_opcode_t                    opcode;
        logic [ARCH_REG_BITS-1:0]       src1_arch;
        logic [ARCH_REG_BITS-1:0]       src2_arch;
        logic [ARCH_REG_BITS-1:0]       src3_arch;
        logic [ARCH_REG_BITS-1:0]       dst_arch;
        logic [XLEN-1:0]                imm;
        exec_unit_t                     exec_unit;
        logic                           is_load;
        logic                           is_store;
        logic                           is_branch;
        logic                           is_fence;
        branch_pred_t                   branch_pred;
        logic [VADDR_WIDTH-1:0]         branch_target;
    } decoded_inst_t;
    
    // Renamed instruction (after register renaming)
    typedef struct packed {
        logic                           valid;
        logic [VADDR_WIDTH-1:0]         pc;
        uop_opcode_t                    opcode;
        logic [PHYS_REG_BITS-1:0]       src1_tag;
        logic [PHYS_REG_BITS-1:0]       src2_tag;
        logic [PHYS_REG_BITS-1:0]       src3_tag;
        logic [PHYS_REG_BITS-1:0]       dst_tag;
        logic [PHYS_REG_BITS-1:0]       old_dst_tag; // For freelist reclaim
        logic                           src1_ready;  // From RAT or bypass
        logic                           src2_ready;
        logic                           src3_ready;
        logic [CHAIN_DEPTH_BITS-1:0]    chain_depth; // Computed during rename
        logic [ROB_IDX_BITS-1:0]        rob_idx;
        exec_unit_t                     exec_unit;
        logic [15:0]                    imm;
        logic                           is_load;
        logic                           is_store;
        logic                           is_branch;
        branch_pred_t                   branch_pred;
        logic [VADDR_WIDTH-1:0]         branch_target;
    } renamed_inst_t;
    
    // Wakeup tag (result forwarding)
    typedef struct packed {
        logic                           valid;
        logic [PHYS_REG_BITS-1:0]       tag;
        logic [XLEN-1:0]                data;        // For bypass network
    } wakeup_tag_t;
    
    // Issue slot (from scheduler to execution)
    typedef struct packed {
        logic                           valid;
        uop_opcode_t                    opcode;
        logic [XLEN-1:0]                src1_data;
        logic [XLEN-1:0]                src2_data;
        logic [XLEN-1:0]                src3_data;
        logic [PHYS_REG_BITS-1:0]       dst_tag;
        logic [15:0]                    imm;
        logic [ROB_IDX_BITS-1:0]        rob_idx;
        exec_unit_t                     exec_unit;
        logic                           is_load;
        logic                           is_store;
        logic                           is_branch;
    } issue_slot_t;
    
    // Execution result
    typedef struct packed {
        logic                           valid;
        logic [PHYS_REG_BITS-1:0]       dst_tag;
        logic [XLEN-1:0]                result;
        logic [ROB_IDX_BITS-1:0]        rob_idx;
        logic                           exception;
        logic [7:0]                     exception_code;
        // Branch resolution
        logic                           is_branch;
        logic                           branch_taken;
        logic                           branch_mispredicted;
        logic [VADDR_WIDTH-1:0]         branch_target;
    } exec_result_t;
    
    // ROB entry
    typedef struct packed {
        logic                           valid;
        logic                           complete;
        logic                           exception;
        logic [VADDR_WIDTH-1:0]         pc;
        logic [PHYS_REG_BITS-1:0]       dst_tag;
        logic [ARCH_REG_BITS-1:0]       dst_arch;
        logic [PHYS_REG_BITS-1:0]       old_dst_tag;
        logic [XLEN-1:0]                result;
        logic [7:0]                     exception_code;
        logic                           is_branch;
        logic                           branch_taken;
        logic                           branch_mispredicted;
        logic [VADDR_WIDTH-1:0]         branch_target;
    } rob_entry_t;
    
    //==========================================================================
    // FUNCTIONS
    //==========================================================================
    
    // Get execution latency for different operations
    function automatic int get_exec_latency(uop_opcode_t opcode);
        case (opcode)
            // ALU: 1 cycle
            UOP_ADD, UOP_SUB, UOP_AND, UOP_OR, UOP_XOR,
            UOP_SLL, UOP_SRL, UOP_SRA, UOP_SLT, UOP_SLTU:
                return 1;
            
            // Multiply: 3 cycles
            UOP_MUL, UOP_MULH, UOP_MULHU, UOP_MULHSU:
                return 3;
            
            // Divide: 12 cycles
            UOP_DIV, UOP_DIVU, UOP_REM, UOP_REMU:
                return 12;
            
            // Load: 4 cycles (L1 hit assumed)
            UOP_LOAD:
                return 4;
            
            // Branch: 1 cycle
            UOP_BEQ, UOP_BNE, UOP_BLT, UOP_BGE, UOP_BLTU, UOP_BGEU,
            UOP_JAL, UOP_JALR:
                return 1;
            
            // FP add/sub: 3 cycles
            UOP_FADD, UOP_FSUB:
                return 3;
            
            // FP mul: 4 cycles
            UOP_FMUL:
                return 4;
            
            // FP FMA: 4 cycles
            UOP_FMA:
                return 4;
            
            // FP div: 16 cycles
            UOP_FDIV:
                return 16;
            
            // FP sqrt: 20 cycles
            UOP_FSQRT:
                return 20;
            
            default:
                return 1;
        endcase
    endfunction
    
    // Check if opcode needs source 3
    function automatic logic needs_src3(uop_opcode_t opcode);
        return (opcode == UOP_FMA) || (opcode == UOP_STORE);
    endfunction
    
    // Priority encoder (find first set bit)
    function automatic logic [7:0] priority_encode_256(logic [255:0] bitmap);
        for (int i = 255; i >= 0; i--) begin
            if (bitmap[i]) return i[7:0];
        end
        return 8'd0;
    endfunction

endpackage : superh16_pkg