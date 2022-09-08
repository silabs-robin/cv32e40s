// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Authors:        Sven Stucki - svstucki@student.ethz.ch                     //
//                 Andreas Traber - atraber@iis.ee.ethz.ch                    //
//                 Michael Gautschi - gautschi@iis.ee.ethz.ch                 //
//                 Davide Schiavone - pschiavo@iis.ee.ethz.ch                 //
//                 Andrea Bettati - andrea.bettati@studenti.unipr.it          //
//                 Halfdan Bechmann - halfdan.bechmann@silabs.com             //
//                 Øystein Knauserud - oystein.knauserud@silabs.com           //
//                                                                            //
// Description:    RTL assertions for the cs_registers module                 //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

module cv32e40s_cs_registers_sva
  import uvm_pkg::*;
  import cv32e40s_pkg::*;
#(
    parameter bit SMCLIC = 0
  )

  (
   input logic        clk,
   input logic        rst_n,
   input ctrl_fsm_t   ctrl_fsm_i,
   input id_ex_pipe_t id_ex_pipe_i,
   input ex_wb_pipe_t ex_wb_pipe_i,
   input logic [31:0] csr_rdata_o,
   input logic        csr_we_int,
   input logic [1:0]  mtvec_mode_o,
   input logic        wb_valid_i,
   input logic        mnxti_we,
   input logic        mintstatus_we,
   input logic        mcause_we,
   input logic [31:0] clic_pa_o,
   input logic        clic_pa_valid_o,
   input mintstatus_t mintstatus_rdata,
   input privlvl_t    priv_lvl_n,
   input privlvl_t    priv_lvl_rdata,
   input logic [31:0] mscratch_rdata,
   input mcause_t     mcause_rdata,
   csr_num_e          csr_waddr,
   input logic        mscratch_we,
   input logic        instr_valid,
   input csr_opcode_e csr_op

   );


   // CSR file shall not be written when WB is halted or killed
  a_csr_halt_kill:
  assert property (@(posedge clk) disable iff (!rst_n)
                  (ctrl_fsm_i.kill_wb || ctrl_fsm_i.halt_wb)
                  |-> !csr_we_int)
    else `uvm_error("wb_stage", "Register file written while WB is halted or killed")

  if (SMCLIC) begin
    // Assert that mtvec[1:0] are always 2'b11
    a_mtvec_mode_clic:
    assert property (@(posedge clk) disable iff (!rst_n)
                    1'b1 |-> mtvec_mode_o == 2'b11)
      else `uvm_error("cs_registers", "mtvec_mode is not 2'b11 in CLIC mode")

    // Accesses to MNXTI are stalled in EX if there is a LSU instruction in WB.
    // Thus no mnxti should be in WB (clic_pa_valid_o) the cycle after an LSU instruction
    // is done in WB.
    property p_no_mnxti_after_lsu;
      @(posedge clk) disable iff (!rst_n)
      (  wb_valid_i && ex_wb_pipe_i.lsu_en && ex_wb_pipe_i.instr_valid
        |=>
        !clic_pa_valid_o);
    endproperty;

    a_no_mnxti_after_lsu: assert property(p_no_mnxti_after_lsu)
      else `uvm_error("cs_registers", "Mnxti should not we in WB the cycle after an LSU instruction");


    // Check that horizontal traps keep the current interrupt level
    property p_htrap_interrupt_level;
      @(posedge clk) disable iff (!rst_n)
      (  ctrl_fsm_i.csr_save_cause && !ctrl_fsm_i.debug_csr_save && !ctrl_fsm_i.csr_cause.irq && (priv_lvl_n == priv_lvl_rdata)
         |=>
         $stable(mintstatus_rdata.mil));

    endproperty;

    a_htrap_interrupt_level: assert property(p_htrap_interrupt_level)
      else `uvm_error("cs_registers", "Horizontal trap taken caused interrupt level to change");

    // Check that vertical traps use interrupt level 0
    property p_vtrap_interrupt_level;
      @(posedge clk) disable iff (!rst_n)
      (  ctrl_fsm_i.csr_save_cause && !ctrl_fsm_i.debug_csr_save && !ctrl_fsm_i.csr_cause.irq && (priv_lvl_n == PRIV_LVL_M) && (priv_lvl_rdata == PRIV_LVL_U)
          |=>
          (mintstatus_rdata.mil == '0));

    endproperty;

    a_vtrap_interrupt_level: assert property(p_vtrap_interrupt_level)
      else `uvm_error("cs_registers", "Vertical trap taken with nonzero interrupt level");
    // Check that mscratch do not update due to mscratchcsw if the conditions are not right
    property p_mscratchcsw_mscratch;
      @(posedge clk) disable iff (!rst_n)
      (  ex_wb_pipe_i.csr_en && (csr_waddr == CSR_MSCRATCHCSW) && (mcause_rdata.mpp == PRIV_LVL_M)
        |=> $stable(mscratch_rdata));
    endproperty;

    a_mscratchcsw_mscratch: assert property(p_mscratchcsw_mscratch)
      else `uvm_error("cs_registers", "Mscratch not stable after mscratwchsw with mpp=M");

    // Check that mscratch do not update due to mscratchcswl if the conditions are not right
    property p_mscratchcswl_mscratch;
      @(posedge clk) disable iff (!rst_n)
      (  ex_wb_pipe_i.csr_en && (csr_waddr == CSR_MSCRATCHCSWL) && !((mcause_rdata.mpil == '0) != (mintstatus_rdata.mil == '0))
        |=> $stable(mscratch_rdata));
    endproperty;

    a_mscratchcswl_mscratch: assert property(p_mscratchcswl_mscratch)
      else `uvm_error("cs_registers", "Mscratch not stable after mscratwchswl");

    // Check that mscratch is written by mscratchcswl when the conditions are right
    property p_mscratchcswl_mscratch_we;
      @(posedge clk) disable iff (!rst_n)
      (  ex_wb_pipe_i.csr_en && (csr_waddr == CSR_MSCRATCHCSWL) && ((mcause_rdata.mpil == '0) != (mintstatus_rdata.mil == '0))
         && (csr_op != CSR_OP_READ) && instr_valid
        |-> mscratch_we);
    endproperty;

    a_mscratchcswl_mscratch_we: assert property(p_mscratchcswl_mscratch_we)
      else `uvm_error("cs_registers", "Mscratch not written by mscratchcswl");

  end
endmodule // cv32e40s_cs_registers_sva

