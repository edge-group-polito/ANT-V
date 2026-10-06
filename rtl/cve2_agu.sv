// Copyright 2024 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: cve2_agu.sv
// Author: Alessio Caviglia, Flavia Guella


module cve2_agu #(
    parameter int unsigned AddrWidth = 32,
    parameter int unsigned VRF_START_ADDR = 32'h00010000, // base address of the VRF
    parameter bit VRFDynamic = 0, // 1 - the VRF base address is dynamic and can be changed at runtime writing the corresponding CSR
    parameter int unsigned VLEN = 128 // Max length in bits of vector registers
) (
    input logic clk_i,
    input logic rst_ni,

    // VRF base address if VRFDynamic is 1, otherwise it is the default VRF_START_ADDR
    input logic [31:0] vrf_addr_start_i,
    
    // input logic [....] vrf_base_addr_i, // base address of the VRF
    // addresses of registers
    input logic [4:0] rs1_i,
    input logic [4:0] rs2_i,
    input logic [4:0] rd_i,

    // control signals from VRF
    input logic load_i,           // parallel load_i for the counters
    input logic get_rs1_i,        // generate rs1
    input logic get_rs2_i,        // generate rs2
    input logic get_rd_i,         // generate rd
    input logic incr_i,

    // slide support signals
    input logic is_slide_i,       // the current instruction is a slide
    input logic is_slide_up_i,    // 1 - slide up, 0 - slide down

    // to/from pipeline
    input  logic [AddrWidth-1:0] addr_i,   // address with OFFSET
    output logic [AddrWidth-1:0] slide_start_addr_o,    // requested address
    output logic [AddrWidth-1:0] mem_if_addr_o         // requested address
);

    import cve2_pkg::*;

    // Localparameters using VLEN
    localparam int unsigned VlenBytes = VLEN / 8;
    localparam int unsigned VRegAddrWidth = $clog2(VlenBytes); // Max addr width of a vector register in bytes
    localparam int unsigned VRegAddrWidthW = VRegAddrWidth - 2; // Max addr width of a vector register in words (4 bytes)
    localparam int unsigned MaxVWidth = 3; // Log2 of max number of vectors that can be incorporated in a single one using LMUL
    //localparam int unsigned MaxCntWidth = VRegAddrWidth + MaxVWidth; // Max width of the counters
    localparam int unsigned MaxCntWidth = VRegAddrWidthW + MaxVWidth;
    // counter signals
    // TODO: check the -1
    // the +3 is due to LMUL
    logic [MaxCntWidth-1:0] addr_rs1_q, addr_rs2_q, addr_rd_q, addr_rs1_d, addr_rs2_d, addr_rd_d;
    
    logic [31:0] vrf_effective_start_addr;
    
    assign vrf_effective_start_addr = VRFDynamic ? vrf_addr_start_i : VRF_START_ADDR;

    //////////////
    // COUNTERS //
    //////////////

    // Sequential logic for the counters
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            addr_rs1_q <= '0;
            addr_rs2_q <= '0;
            addr_rd_q  <= '0;
        end else begin
            addr_rs1_q <= addr_rs1_d;
            addr_rs2_q <= addr_rs2_d;
            addr_rd_q  <= addr_rd_d;
        end
    end

    // Combinational logic for the counters
    //always_comb begin
    //    addr_rs1_d = load_i ? {rs1_i[2:0], 2'b00} : (get_rs1_i && incr_i) ? addr_rs1_q + 1 : addr_rs1_q;
    //    addr_rs2_d = load_i ? {rs2_i[2:0], 2'b00} : (get_rs2_i && incr_i) ? addr_rs2_q + 1 : addr_rs2_q;
    //    addr_rd_d = load_i ? {rd_i[2:0], 2'b00} : (get_rd_i && incr_i) ? addr_rd_q + 1 : addr_rd_q;
    //    if (is_slide_i && !is_slide_up_i && load_i) addr_rs2_d = addr_i[6:2];      // in slide down the address is vs2 since we start reading it from OFFSET
    //    else if (is_slide_i && is_slide_up_i && load_i) addr_rd_d = addr_i[6:2];   // in slide up the address is vd since we start writing it from OFFSET
    //end
    always_comb begin
        addr_rs1_d = load_i ? {rs1_i[2:0], {VRegAddrWidthW{1'b0}}} : (get_rs1_i && incr_i) ? addr_rs1_q[MaxCntWidth-1:0] + 1 : addr_rs1_q;
        addr_rs2_d = load_i ? {rs2_i[2:0], {VRegAddrWidthW{1'b0}}} : (get_rs2_i && incr_i) ? addr_rs2_q[MaxCntWidth-1:0] + 1 : addr_rs2_q; 
        addr_rd_d  = load_i ? {rd_i[2:0],  {VRegAddrWidthW{1'b0}}} : (get_rd_i  && incr_i) ? addr_rd_q[MaxCntWidth-1:0]  + 1  : addr_rd_q;
        // TODO: fix
        if (is_slide_i && !is_slide_up_i && load_i) begin
            addr_rs2_d = addr_i[MaxCntWidth+1:2];   // in slide down the address is vs2 since we start reading it from OFFSET
        end else if (is_slide_i && is_slide_up_i && load_i) begin
            addr_rd_d = addr_i[MaxCntWidth+1:2];    // in slide up the address is vd since we start writing it from OFFSET
        end
    end

    ////////////
    // OUTPUT //
    ////////////

    always_comb begin
        if (load_i && is_slide_i) begin
            slide_start_addr_o = {vrf_effective_start_addr[31:VRegAddrWidth+5], !is_slide_up_i ? rs2_i : rd_i, {VRegAddrWidth{1'b0}}};
        end else begin
            slide_start_addr_o = '0;
        end
        // chain 2 0s for byte alignment
        mem_if_addr_o = get_rs1_i ? {vrf_effective_start_addr[31:VRegAddrWidth+5], rs1_i[4:3], addr_rs1_q, 2'b00} :
                        get_rs2_i ? {vrf_effective_start_addr[31:VRegAddrWidth+5], rs2_i[4:3], addr_rs2_q, 2'b00} :
                        get_rd_i  ? {vrf_effective_start_addr[31:VRegAddrWidth+5], rd_i[4:3], addr_rd_q, 2'b00}  : '0;
    
        // TODO: need to mux in case of load and store with the correct address
    end
    
endmodule
