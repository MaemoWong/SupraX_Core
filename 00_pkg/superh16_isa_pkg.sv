//==============================================================================
// File: 00_pkg/superh16_isa_pkg.sv
// Description: RISC-V ISA definitions and decode logic
// Author: AI-Generated Production-Quality RTL
//==============================================================================

package superh16_isa_pkg;

    import superh16_pkg::*;
    
    //==========================================================================
    // RISC-V INSTRUCTION FORMATS
    //==========================================================================
    
    // Opcode field (bits [6:0])
    typedef enum logic [6:0] {
        OPCODE_LOAD     = 7'b0000011,
        OPCODE_STORE    = 7'b0100011,
        OPCODE_MADD     = 7'b1000011,  // FP fused multiply-add
        OPCODE_BRANCH   = 7'b1100011,
        OPCODE_LOAD_FP  = 7'b0000111,
        OPCODE_STORE_FP = 7'b0100111,
        OPCODE_MSUB     = 7'b1000111,
        OPCODE_JALR     = 7'b1100111,
        OPCODE_NMSUB    = 7'b1001011,
        OPCODE_NMADD    = 7'b1001111,
        OPCODE_OP_IMM   = 7'b0010011,
        OPCODE_OP       = 7'b0110011,
        OPCODE_LUI      = 7'b0110111,
        OPCODE_OP_IMM_32= 7'b0011011,
        OPCODE_OP_32    = 7'b0111011,
        OPCODE_OP_FP    = 7'b1010011,
        OPCODE_AUIPC    = 7'b0010111,
        OPCODE_JAL      = 7'b1101111,
        OPCODE_SYSTEM   = 7'b1110011,
        OPCODE_VECTOR   = 7'b1010111
    } riscv_opcode_t;
    
    // Funct3 for integer ops
    typedef enum logic [2:0] {
        FUNCT3_ADD_SUB  = 3'b000,
        FUNCT3_SLL      = 3'b001,
        FUNCT3_SLT      = 3'b010,
        FUNCT3_SLTU     = 3'b011,
        FUNCT3_XOR      = 3'b100,
        FUNCT3_SRL_SRA  = 3'b101,
        FUNCT3_OR       = 3'b110,
        FUNCT3_AND      = 3'b111
    } riscv_funct3_t;
    
    // Funct3 for branches
    typedef enum logic [2:0] {
        FUNCT3_BEQ      = 3'b000,
        FUNCT3_BNE      = 3'b001,
        FUNCT3_BLT      = 3'b100,
        FUNCT3_BGE      = 3'b101,
        FUNCT3_BLTU     = 3'b110,
        FUNCT3_BGEU     = 3'b111
    } riscv_branch_funct3_t;
    
    // Funct3 for loads/stores
    typedef enum logic [2:0] {
        FUNCT3_BYTE     = 3'b000,
        FUNCT3_HALF     = 3'b001,
        FUNCT3_WORD     = 3'b010,
        FUNCT3_DOUBLE   = 3'b011,
        FUNCT3_BYTE_U   = 3'b100,
        FUNCT3_HALF_U   = 3'b101,
        FUNCT3_WORD_U   = 3'b110
    } riscv_mem_funct3_t;
    
    //==========================================================================
    // INSTRUCTION FIELD EXTRACTION
    //==========================================================================
    
    function automatic logic [6:0] get_opcode(logic [31:0] inst);
        return inst[6:0];
    endfunction
    
    function automatic logic [4:0] get_rd(logic [31:0] inst);
        return inst[11:7];
    endfunction
    
    function automatic logic [2:0] get_funct3(logic [31:0] inst);
        return inst[14:12];
    endfunction
    
    function automatic logic [4:0] get_rs1(logic [31:0] inst);
        return inst[19:15];
    endfunction
    
    function automatic logic [4:0] get_rs2(logic [31:0] inst);
        return inst[24:20];
    endfunction
    
    function automatic logic [6:0] get_funct7(logic [31:0] inst);
        return inst[31:25];
    endfunction
    
    //==========================================================================
    // IMMEDIATE EXTRACTION
    //==========================================================================
    
    // I-type immediate (12 bits, sign-extended)
    function automatic logic [63:0] get_imm_i(logic [31:0] inst);
        return {{52{inst[31]}}, inst[31:20]};
    endfunction
    
    // S-type immediate (store)
    function automatic logic [63:0] get_imm_s(logic [31:0] inst);
        return {{52{inst[31]}}, inst[31:25], inst[11:7]};
    endfunction
    
    // B-type immediate (branch)
    function automatic logic [63:0] get_imm_b(logic [31:0] inst);
        return {{51{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
    endfunction
    
    // U-type immediate (upper)
    function automatic logic [63:0] get_imm_u(logic [31:0] inst);
        return {{32{inst[31]}}, inst[31:12], 12'b0};
    endfunction
    
    // J-type immediate (jump)
    function automatic logic [63:0] get_imm_j(logic [31:0] inst);
        return {{43{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};
    endfunction
    
    //==========================================================================
    // DECODE LOGIC
    //==========================================================================
    
    // Main decode function
    function automatic decoded_inst_t decode_instruction(
        logic [31:0] inst,
        logic [63:0] pc
    );
        decoded_inst_t result;
        logic [6:0] opcode;
        logic [2:0] funct3;
        logic [6:0] funct7;
        
        opcode = get_opcode(inst);
        funct3 = get_funct3(inst);
        funct7 = get_funct7(inst);
        
        // Initialize
        result = '{default: '0};
        result.valid = 1'b1;
        result.pc = pc;
        result.inst = inst;
        result.src1_arch = get_rs1(inst);
        result.src2_arch = get_rs2(inst);
        result.dst_arch = get_rd(inst);
        
        case (opcode)
            //==================================================================
            // INTEGER IMMEDIATE OPS
            //==================================================================
            OPCODE_OP_IMM: begin
                result.imm = get_imm_i(inst);
                result.exec_unit = EXEC_INT_ALU;
                
                case (funct3)
                    FUNCT3_ADD_SUB: result.opcode = UOP_ADD;
                    FUNCT3_SLL:     result.opcode = UOP_SLL;
                    FUNCT3_SLT:     result.opcode = UOP_SLT;
                    FUNCT3_SLTU:    result.opcode = UOP_SLTU;
                    FUNCT3_XOR:     result.opcode = UOP_XOR;
                    FUNCT3_SRL_SRA: result.opcode = (funct7[5]) ? UOP_SRA : UOP_SRL;
                    FUNCT3_OR:      result.opcode = UOP_OR;
                    FUNCT3_AND:     result.opcode = UOP_AND;
                endcase
            end
            
            //==================================================================
            // INTEGER REGISTER OPS
            //==================================================================
            OPCODE_OP: begin
                result.exec_unit = (funct7[0]) ? EXEC_INT_MUL : EXEC_INT_ALU;
                
                if (funct7[0]) begin  // M extension (multiply/divide)
                    case (funct3)
                        3'b000: result.opcode = UOP_MUL;
                        3'b001: result.opcode = UOP_MULH;
                        3'b010: result.opcode = UOP_MULHSU;
                        3'b011: result.opcode = UOP_MULHU;
                        3'b100: result.opcode = UOP_DIV;
                        3'b101: result.opcode = UOP_DIVU;
                        3'b110: result.opcode = UOP_REM;
                        3'b111: result.opcode = UOP_REMU;
                    endcase
                end else begin  // Standard ALU
                    case (funct3)
                        FUNCT3_ADD_SUB: result.opcode = (funct7[5]) ? UOP_SUB : UOP_ADD;
                        FUNCT3_SLL:     result.opcode = UOP_SLL;
                        FUNCT3_SLT:     result.opcode = UOP_SLT;
                        FUNCT3_SLTU:    result.opcode = UOP_SLTU;
                        FUNCT3_XOR:     result.opcode = UOP_XOR;
                        FUNCT3_SRL_SRA: result.opcode = (funct7[5]) ? UOP_SRA : UOP_SRL;
                        FUNCT3_OR:      result.opcode = UOP_OR;
                        FUNCT3_AND:     result.opcode = UOP_AND;
                    endcase
                end
            end
            
            //==================================================================
            // LOADS
            //==================================================================
            OPCODE_LOAD: begin
                result.opcode = UOP_LOAD;
                result.exec_unit = EXEC_LOAD;
                result.is_load = 1'b1;
                result.imm = get_imm_i(inst);
            end
            
            //==================================================================
            // STORES
            //==================================================================
            OPCODE_STORE: begin
                result.opcode = UOP_STORE;
                result.exec_unit = EXEC_STORE;
                result.is_store = 1'b1;
                result.imm = get_imm_s(inst);
                result.src3_arch = get_rs2(inst);  // Store data in src3
            end
            
            //==================================================================
            // BRANCHES
            //==================================================================
            OPCODE_BRANCH: begin
                result.exec_unit = EXEC_BRANCH;
                result.is_branch = 1'b1;
                result.imm = get_imm_b(inst);
                result.branch_target = pc + get_imm_b(inst);
                
                case (funct3)
                    FUNCT3_BEQ:  result.opcode = UOP_BEQ;
                    FUNCT3_BNE:  result.opcode = UOP_BNE;
                    FUNCT3_BLT:  result.opcode = UOP_BLT;
                    FUNCT3_BGE:  result.opcode = UOP_BGE;
                    FUNCT3_BLTU: result.opcode = UOP_BLTU;
                    FUNCT3_BGEU: result.opcode = UOP_BGEU;
                endcase
            end
            
            //==================================================================
            // JAL
            //==================================================================
            OPCODE_JAL: begin
                result.opcode = UOP_JAL;
                result.exec_unit = EXEC_BRANCH;
                result.is_branch = 1'b1;
                result.imm = get_imm_j(inst);
                result.branch_target = pc + get_imm_j(inst);
                result.branch_pred = PRED_TAKEN;
            end
            
            //==================================================================
            // JALR
            //==================================================================
            OPCODE_JALR: begin
                result.opcode = UOP_JALR;
                result.exec_unit = EXEC_BRANCH;
                result.is_branch = 1'b1;
                result.imm = get_imm_i(inst);
                // Target computed at execute time (register-indirect)
            end
            
            //==================================================================
            // LUI
            //==================================================================
            OPCODE_LUI: begin
                result.opcode = UOP_ADD;
                result.exec_unit = EXEC_INT_ALU;
                result.imm = get_imm_u(inst);
                result.src1_arch = 5'd0;  // x0 + imm
            end
            
            //==================================================================
            // AUIPC
            //==================================================================
            OPCODE_AUIPC: begin
                result.opcode = UOP_ADD;
                result.exec_unit = EXEC_INT_ALU;
                result.imm = get_imm_u(inst);
                // Need to add PC - handled specially in rename
            end
            
            //==================================================================
            // FLOATING POINT
            //==================================================================
            OPCODE_OP_FP: begin
                result.exec_unit = EXEC_FP_FMA;
                
                case (funct7)
                    7'b0000000: result.opcode = UOP_FADD;   // FADD.S
                    7'b0000001: result.opcode = UOP_FADD;   // FADD.D
                    7'b0000100: result.opcode = UOP_FSUB;   // FSUB.S
                    7'b0000101: result.opcode = UOP_FSUB;   // FSUB.D
                    7'b0001000: result.opcode = UOP_FMUL;   // FMUL.S
                    7'b0001001: result.opcode = UOP_FMUL;   // FMUL.D
                    7'b0001100: result.opcode = UOP_FDIV;   // FDIV.S
                    7'b0001101: result.opcode = UOP_FDIV;   // FDIV.D
                    7'b0101100: result.opcode = UOP_FSQRT;  // FSQRT.S
                    7'b0101101: result.opcode = UOP_FSQRT;  // FSQRT.D
                    default:    result.opcode = UOP_NOP;
                endcase
            end
            
            //==================================================================
            // FUSED MULTIPLY-ADD
            //==================================================================
            OPCODE_MADD, OPCODE_MSUB, OPCODE_NMSUB, OPCODE_NMADD: begin
                result.opcode = UOP_FMA;
                result.exec_unit = EXEC_FP_FMA;
                result.src3_arch = inst[31:27];  // rs3
            end
            
            default: begin
                result.opcode = UOP_NOP;
                result.exec_unit = EXEC_NONE;
            end
        endcase
        
        return result;
    endfunction

endpackage : superh16_isa_pkg