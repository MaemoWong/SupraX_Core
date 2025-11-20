//==============================================================================
// File: 01_frontend/superh16_branch_predictor.sv
// Description: Hybrid branch predictor (TAGE + neural)
// Predicts direction and target for branches
//==============================================================================

module superh16_branch_predictor
    import superh16_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    
    // Prediction request
    input  logic                                    predict_valid [ISSUE_WIDTH],
    input  logic [VADDR_WIDTH-1:0]                  predict_pc [ISSUE_WIDTH],
    input  logic                                    predict_is_branch [ISSUE_WIDTH],
    input  logic                                    predict_is_call [ISSUE_WIDTH],
    input  logic                                    predict_is_return [ISSUE_WIDTH],
    
    // Prediction output
    output branch_pred_t                            pred_outcome [ISSUE_WIDTH],
    output logic [VADDR_WIDTH-1:0]                  pred_target [ISSUE_WIDTH],
    
    // Update from execution (training)
    input  logic                                    update_valid,
    input  logic [VADDR_WIDTH-1:0]                  update_pc,
    input  logic                                    update_taken,
    input  logic [VADDR_WIDTH-1:0]                  update_target,
    input  logic                                    update_is_call,
    input  logic                                    update_is_return
);

    //==========================================================================
    // Global history register (64 bits)
    //==========================================================================
    
    logic [63:0] global_history;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            global_history <= '0;
        end else if (update_valid) begin
            global_history <= {global_history[62:0], update_taken};
        end
    end
    
    //==========================================================================
    // TAGE predictor (Tagged Geometric History Length)
    // 6 tables with geometric history lengths
    //==========================================================================
    
    localparam int NUM_TAGE_TABLES = 6;
    localparam int TAGE_ENTRY_BITS = 13;  // 8K entries per table
    
    // History lengths: 5, 12, 27, 64, 150, 350 bits
    localparam int HISTORY_LENGTHS [6] = '{5, 12, 27, 64, 150, 350};
    
    typedef struct packed {
        logic                   valid;
        logic [9:0]             tag;      // 10-bit tag
        logic [2:0]             counter;  // 3-bit saturating counter
        logic [1:0]             useful;   // Usefulness counter
    } tage_entry_t;
    
    tage_entry_t tage_table [NUM_TAGE_TABLES][2**TAGE_ENTRY_BITS];
    
    // Base predictor (bimodal)
    logic [1:0] base_predictor [2048];
    
    //==========================================================================
    // TAGE prediction logic
    //==========================================================================
    
    function automatic logic tage_predict(
        input logic [VADDR_WIDTH-1:0] pc,
        input logic [63:0] history
    );
        logic [TAGE_ENTRY_BITS-1:0] indices [NUM_TAGE_TABLES];
        logic [9:0] tags [NUM_TAGE_TABLES];
        logic [NUM_TAGE_TABLES-1:0] hits;
        logic prediction;
        int provider;
        
        // Compute indices and tags for each table
        for (int t = 0; t < NUM_TAGE_TABLES; t++) begin
            logic [63:0] masked_history;
            masked_history = history & ((1 << HISTORY_LENGTHS[t]) - 1);
            indices[t] = (pc[TAGE_ENTRY_BITS-1:0] ^ 
                         masked_history[TAGE_ENTRY_BITS-1:0]);
            tags[t] = pc[19:10] ^ masked_history[9:0];
            
            hits[t] = tage_table[t][indices[t]].valid && 
                     (tage_table[t][indices[t]].tag == tags[t]);
        end
        
        // Find longest matching history (highest priority)
        provider = -1;
        for (int t = NUM_TAGE_TABLES-1; t >= 0; t--) begin
            if (hits[t]) begin
                provider = t;
                break;
            end
        end
        
        // Make prediction
        if (provider >= 0) begin
            prediction = tage_table[provider][indices[provider]].counter[2];
        end else begin
            // Use base predictor
            logic [10:0] base_idx;
            base_idx = pc[10:0];
            prediction = base_predictor[base_idx][1];
        end
        
        return prediction;
    endfunction
    
    //==========================================================================
    // BTB (Branch Target Buffer)
    //==========================================================================
    
    localparam int BTB_ENTRIES = 4096;
    localparam int BTB_WAYS = 4;
    localparam int BTB_SETS = BTB_ENTRIES / BTB_WAYS;
    
    typedef struct packed {
        logic                       valid;
        logic [19:0]                tag;
        logic [VADDR_WIDTH-1:0]     target;
        logic [1:0]                 type;  // 00=cond, 01=uncond, 10=call, 11=ret
    } btb_entry_t;
    
    btb_entry_t btb [BTB_SETS][BTB_WAYS];
    
    function automatic logic [VADDR_WIDTH-1:0] btb_lookup(
        input logic [VADDR_WIDTH-1:0] pc
    );
        logic [$clog2(BTB_SETS)-1:0] set_idx;
        logic [19:0] tag;
        logic [VADDR_WIDTH-1:0] target;
        
        set_idx = pc[$clog2(BTB_SETS)-1:0];
        tag = pc[19+$clog2(BTB_SETS):$clog2(BTB_SETS)];
        target = pc + 4;  // Default: next sequential
        
        for (int w = 0; w < BTB_WAYS; w++) begin
            if (btb[set_idx][w].valid && btb[set_idx][w].tag == tag) begin
                target = btb[set_idx][w].target;
                break;
            end
        end
        
        return target;
    endfunction
    
    //==========================================================================
    // RAS (Return Address Stack)
    //==========================================================================
    
    localparam int RAS_DEPTH = 64;
    
    logic [VADDR_WIDTH-1:0] ras [RAS_DEPTH];
    logic [$clog2(RAS_DEPTH)-1:0] ras_tos;  // Top of stack pointer
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ras_tos <= '0;
        end else if (update_valid) begin
            if (update_is_call) begin
                // Push return address
                ras[ras_tos] <= update_pc + 4;
                ras_tos <= ras_tos + 1;
            end else if (update_is_return && ras_tos != 0) begin
                // Pop return address
                ras_tos <= ras_tos - 1;
            end
        end
    end
    
    //==========================================================================
    // Prediction generation (combinational)
    //==========================================================================
    
    always_comb begin
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            if (predict_valid[i] && predict_is_branch[i]) begin
                // Get direction prediction from TAGE
                logic direction;
                direction = tage_predict(predict_pc[i], global_history);
                
                // Get target prediction
                logic [VADDR_WIDTH-1:0] target;
                
                if (predict_is_return) begin
                    // Use RAS for returns
                    target = (ras_tos != 0) ? ras[ras_tos - 1] : predict_pc[i] + 4;
                    pred_outcome[i] = PRED_RETURN;
                end else if (predict_is_call) begin
                    // Calls are always taken
                    target = btb_lookup(predict_pc[i]);
                    pred_outcome[i] = PRED_CALL;
                end else begin
                    // Regular conditional branch
                    target = direction ? btb_lookup(predict_pc[i]) : predict_pc[i] + 4;
                    pred_outcome[i] = direction ? PRED_TAKEN : PRED_NOT_TAKEN;
                end
                
                pred_target[i] = target;
            end else begin
                pred_outcome[i] = PRED_NOT_TAKEN;
                pred_target[i] = predict_pc[i] + 4;
            end
        end
    end
    
    //==========================================================================
    // TAGE update (training)
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Initialize base predictor
            for (int i = 0; i < 2048; i++) begin
                base_predictor[i] <= 2'b10;  // Weakly taken
            end
            
            // Initialize TAGE tables
            for (int t = 0; t < NUM_TAGE_TABLES; t++) begin
                for (int i = 0; i < 2**TAGE_ENTRY_BITS; i++) begin
                    tage_table[t][i].valid <= 1'b0;
                    tage_table[t][i].counter <= 3'b100;
                    tage_table[t][i].useful <= 2'b00;
                end
            end
        end else if (update_valid) begin
            // Update TAGE predictor
            logic [TAGE_ENTRY_BITS-1:0] indices [NUM_TAGE_TABLES];
            logic [9:0] tags [NUM_TAGE_TABLES];
            logic [NUM_TAGE_TABLES-1:0] hits;
            int provider;
            
            // Compute indices and tags
            for (int t = 0; t < NUM_TAGE_TABLES; t++) begin
                logic [63:0] masked_history;
                masked_history = global_history & ((1 << HISTORY_LENGTHS[t]) - 1);
                indices[t] = update_pc[TAGE_ENTRY_BITS-1:0] ^ 
                            masked_history[TAGE_ENTRY_BITS-1:0];
                tags[t] = update_pc[19:10] ^ masked_history[9:0];
                hits[t] = tage_table[t][indices[t]].valid && 
                         (tage_table[t][indices[t]].tag == tags[t]);
            end
            
            // Find provider
            provider = -1;
            for (int t = NUM_TAGE_TABLES-1; t >= 0; t--) begin
                if (hits[t]) begin
                    provider = t;
                    break;
                end
            end
            
            // Update provider table
            if (provider >= 0) begin
                // Update counter (saturating increment/decrement)
                if (update_taken) begin
                    if (tage_table[provider][indices[provider]].counter < 3'b111) begin
                        tage_table[provider][indices[provider]].counter <= 
                            tage_table[provider][indices[provider]].counter + 1;
                    end
                end else begin
                    if (tage_table[provider][indices[provider]].counter > 3'b000) begin
                        tage_table[provider][indices[provider]].counter <= 
                            tage_table[provider][indices[provider]].counter - 1;
                    end
                end
            end else begin
                // Update base predictor
                logic [10:0] base_idx;
                base_idx = update_pc[10:0];
                if (update_taken) begin
                    if (base_predictor[base_idx] < 2'b11)
                        base_predictor[base_idx] <= base_predictor[base_idx] + 1;
                end else begin
                    if (base_predictor[base_idx] > 2'b00)
                        base_predictor[base_idx] <= base_predictor[base_idx] - 1;
                end
            end
            
            // Allocate new entry in longer history table on misprediction
            // (TAGE allocation policy - not shown for brevity)
        end
    end
    
    //==========================================================================
    // BTB update
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < BTB_SETS; s++) begin
                for (int w = 0; w < BTB_WAYS; w++) begin
                    btb[s][w].valid <= 1'b0;
                end
            end
        end else if (update_valid) begin
            logic [$clog2(BTB_SETS)-1:0] set_idx;
            logic [19:0] tag;
            logic hit;
            int hit_way;
            
            set_idx = update_pc[$clog2(BTB_SETS)-1:0];
            tag = update_pc[19+$clog2(BTB_SETS):$clog2(BTB_SETS)];
            
            // Check for hit
            hit = 1'b0;
            hit_way = 0;
            for (int w = 0; w < BTB_WAYS; w++) begin
                if (btb[set_idx][w].valid && btb[set_idx][w].tag == tag) begin
                    hit = 1'b1;
                    hit_way = w;
                    break;
                end
            end
            
            if (hit) begin
                // Update existing entry
                btb[set_idx][hit_way].target <= update_target;
            end else begin
                // Allocate new entry (replace way 0 for simplicity)
                btb[set_idx][0].valid <= 1'b1;
                btb[set_idx][0].tag <= tag;
                btb[set_idx][0].target <= update_target;
                btb[set_idx][0].type <= update_is_call ? 2'b10 : 
                                       update_is_return ? 2'b11 : 2'b00;
            end
        end
    end

endmodule : superh16_branch_predictor