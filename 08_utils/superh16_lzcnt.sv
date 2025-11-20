//==============================================================================
// File: 08_utils/superh16_lzcnt.sv
// Description: Production-quality LZCNT with power optimizations
// This is YOUR design from earlier! Integrating it here.
//==============================================================================

module superh16_lzcnt #(
    parameter int WIDTH = 64,
    parameter bit SHARED_WITH_CTZ = 1
) (
    input  logic              clk,
    input  logic              rst_n,
    
    // Control signals
    input  logic              enable,
    input  logic              mode_lzcnt,    // 1=LZCNT, 0=CTZNT
    
    // Data path
    input  logic [WIDTH-1:0]  data_in,
    output logic [6:0]        count_out,
    output logic              valid_out,
    output logic              all_zero
);

    // Clock gating
    logic clk_gated;
    logic enable_latched;
    
    always_latch begin
        if (!clk) enable_latched = enable;
    end
    
    assign clk_gated = clk & enable_latched;
    
    // Data gating
    logic [WIDTH-1:0] data_gated;
    assign data_gated = enable ? data_in : '0;
    
    // Bit reversal for CTZ
    logic [WIDTH-1:0] data_reversed;
    logic [WIDTH-1:0] data_conditioned;
    
    generate
        if (SHARED_WITH_CTZ) begin : gen_shared_ctz
            for (genvar i = 0; i < WIDTH; i++) begin : gen_reverse
                assign data_reversed[i] = data_gated[WIDTH-1-i];
            end
            assign data_conditioned = mode_lzcnt ? data_gated : data_reversed;
        end else begin : gen_lzcnt_only
            assign data_conditioned = data_gated;
        end
    endgenerate
    
    // Sector-based architecture
    localparam int SECTOR_SIZE = 8;
    localparam int NUM_SECTORS = WIDTH / SECTOR_SIZE;
    
    logic [NUM_SECTORS-1:0] sector_has_one;
    logic [2:0] sector_position [NUM_SECTORS];
    
    // Early termination
    logic early_term_sector_7;
    logic early_term_sector_6;
    
    assign early_term_sector_7 = |data_conditioned[63:56];
    assign early_term_sector_6 = |data_conditioned[55:48];
    
    // Per-sector encoding
    generate
        for (genvar s = 0; s < NUM_SECTORS; s++) begin : gen_sectors
            logic [SECTOR_SIZE-1:0] sector_data;
            logic sector_enable;
            
            assign sector_data = data_conditioned[s*SECTOR_SIZE +: SECTOR_SIZE];
            
            if (s == 7) begin
                assign sector_enable = enable;
            end else if (s == 6) begin
                assign sector_enable = enable & ~early_term_sector_7;
            end else begin
                logic any_upper_active;
                assign any_upper_active = |sector_has_one[NUM_SECTORS-1:s+1];
                assign sector_enable = enable & ~any_upper_active;
            end
            
            logic [SECTOR_SIZE-1:0] sector_gated;
            assign sector_gated = sector_enable ? sector_data : '0;
            assign sector_has_one[s] = |sector_gated;
            
            // 3-level balanced tree
            always_comb begin
                logic [1:0] upper_half, lower_half;
                logic [1:0] selected_half;
                logic use_upper_half;
                
                upper_half[1] = |sector_gated[7:6];
                upper_half[0] = |sector_gated[5:4];
                lower_half[1] = |sector_gated[3:2];
                lower_half[0] = |sector_gated[1:0];
                
                use_upper_half = |sector_gated[7:4];
                selected_half = use_upper_half ? upper_half : lower_half;
                
                sector_position[s][2] = ~use_upper_half;
                sector_position[s][1] = ~selected_half[1];
                
                case ({use_upper_half, selected_half[1]})
                    2'b11: sector_position[s][0] = ~sector_gated[7];
                    2'b10: sector_position[s][0] = ~sector_gated[5];
                    2'b01: sector_position[s][0] = ~sector_gated[3];
                    2'b00: sector_position[s][0] = ~sector_gated[1];
                endcase
            end
        end
    endgenerate
    
    // Sector selection
    logic [2:0] winning_sector;
    logic all_sectors_zero;
    
    always_comb begin
        all_sectors_zero = ~|sector_has_one;
        winning_sector = 3'd0;
        for (int s = NUM_SECTORS-1; s >= 0; s--) begin
            if (sector_has_one[s]) winning_sector = s[2:0];
        end
    end
    
    // Final combination
    logic [6:0] result_comb;
    logic [6:0] sector_base;
    logic [6:0] position_in_sector;
    
    assign sector_base = {winning_sector, 3'b000};
    assign position_in_sector = {4'b0000, sector_position[winning_sector]};
    assign result_comb = all_sectors_zero ? 7'd64 : (sector_base | position_in_sector);
    
    // Output registers
    always_ff @(posedge clk_gated or negedge rst_n) begin
        if (!rst_n) begin
            count_out <= '0;
            all_zero <= 1'b1;
            valid_out <= 1'b0;
        end else begin
            count_out <= result_comb;
            all_zero <= all_sectors_zero;
            valid_out <= 1'b1;
        end
    end

endmodule : superh16_lzcnt