module fm_signal_rom (
    input wire clk,
    input wire rst_n,
    input wire enable,
    output reg signed [15:0] fm_out,
    output reg signed [15:0] mod_out,
    output reg [17:0] addr
);

parameter ROM_DEPTH = 166667;

reg signed [15:0] fm_rom [0:ROM_DEPTH-1];
reg signed [15:0] mod_rom [0:ROM_DEPTH-1];

initial begin
    $readmemh("fm_signal_hex.txt", fm_rom);
    $readmemh("mod_signal_hex.txt", mod_rom);
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        addr <= 18'd0;
        fm_out <= 16'sd0;
        mod_out <= 16'sd0;
    end else if (enable) begin
        fm_out <= fm_rom[addr];
        mod_out <= mod_rom[addr];
        if (addr == ROM_DEPTH - 1)
            addr <= 18'd0;
        else
            addr <= addr + 18'd1;
    end
end

endmodule
