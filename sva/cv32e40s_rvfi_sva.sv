// Copyright 2021 Silicon Labs, Inc.
//
// This file, and derivatives thereof are licensed under the
// Solderpad License, Version 2.0 (the "License");
// Use of this file means you agree to the terms and conditions
// of the license and are in full compliance with the License.
// You may obtain a copy of the License at
//
//     https://solderpad.org/licenses/SHL-2.0/
//
// Unless required by applicable law or agreed to in writing, software
// and hardware implementations thereof
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, EITHER EXPRESSED OR IMPLIED.
// See the License for the specific language governing permissions and
// limitations under the License.

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Authors:        Oivind Ekelund - oivind.ekelund@silabs.com                 //
//                                                                            //
// Description:    Assertions for RVFI                                        //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

module cv32e40s_rvfi_sva
  import uvm_pkg::*;
  import cv32e40s_pkg::*;
  import cv32e40s_rvfi_pkg::*;
  #(
    parameter bit SMCLIC = 0
)
(
   input logic             clk_i,
   input logic             rst_ni,

   input logic             rvfi_valid,
   input rvfi_intr_t       rvfi_intr,
   input rvfi_trap_t       rvfi_trap,
   input logic [2:0]       rvfi_dbg,

   input ctrl_fsm_t        ctrl_fsm_i,
   input logic [31:0]      rvfi_csr_dcsr_rdata,
   input logic [31:0]      rvfi_csr_mcause_rdata,
   input logic [31:0]      rvfi_pc_rdata,
   input logic [24:0]      mtvec_addr_i,
   input logic [31:0]      rvfi_csr_mie_rdata,
   input logic [31:0]      rvfi_csr_mip_rdata,
   input logic             irq_ack,
   input logic             dbg_ack,
   input logic             ebreak_in_wb_i,
   input rvfi_intr_t [4:0] in_trap,
   input logic [4:0] [2:0] debug_cause,

   input logic             if_valid_i,
   input logic             id_ready_i,
   input logic [31:0]      pc_if_i,
   input inst_resp_t       prefetch_instr_if_i,
   input logic             prefetch_compressed_if_i,
   input  logic [31:0]     prefetch_addr_if_i,
   input  logic            prefetch_valid_if_i,
   input  logic            prefetch_ready_if_i,
   input rvfi_obi_instr_t  obi_instr_if,
   input rvfi_obi_instr_t [0:3] obi_instr_fifo_q,
   input logic [1:0]       obi_instr_rptr_q_inc,
   input logic [1:0]       obi_instr_rptr_q,
   input logic             mret_ptr_wb,
   input logic [31:0]      instr_rdata_wb_past
);

rvfi_trap_t rvfi_trap_q; // RVFI trap value of the previous valid rvfi instruction

always_ff @(posedge clk_i, negedge rst_ni) begin
  if (rst_ni == 1'b0) begin
    rvfi_trap_q <= '0;
  end else begin
    if (rvfi_valid) begin
      rvfi_trap_q <= rvfi_trap;
    end
  end
end

  a_mret_pointer :
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                  (mret_ptr_wb |-> (instr_rdata_wb_past == 32'h30200073)))
    else `uvm_error("rvfi", "mret not in STAGE_WB_PAST when mret pointer arrived in WB")

  // Check that irq_ack results in RVFI capturing a trap
  // Ideally, we should assert that every irq_ack eventually leads to rvfi_intr,
  // but since there can be an infinite delay between irq_ack and rvfi_intr (e.g. because of bus stalls), we're settling for asserting
  // that irq_ack leads to RVFI capturing a trap (in_trap[IF_STAGE] = 1)

  a_irq_ack_rvfi_capture :
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                    (irq_ack |=> in_trap[STAGE_IF].intr))
      else `uvm_error("rvfi", "irq_ack not captured by RVFI")

  // Every irq_ack shall cause rvfi_intr on next rvfi_valid
  property p_every_ack_followed_by_rvfi_intr;
    @(posedge clk_i) disable iff (!rst_ni)
    irq_ack ##1 rvfi_valid[->1]
      |->
        rvfi_intr.intr;
  endproperty : p_every_ack_followed_by_rvfi_intr

  a_every_ack_followed_by_rvfi_intr: assert property (p_every_ack_followed_by_rvfi_intr)
  else
    `uvm_error("rvfi",
      $sformatf("Every irq_ack should be followed by the corresponding rvfi_intr"));


  // Helper signal, indicating debug cause
  // Special case for debug entry from debug mode caused by EBREAK as it is not captured by debug_cause_i
  logic [2:0] debug_cause_int;
  assign debug_cause_int = (ctrl_fsm_i.debug_mode && ebreak_in_wb_i) ? 3'h1 : ctrl_fsm_i.debug_cause;

  // Check that dbg_ack results in RVFI capturing a debug_cause
  // Ideally, we should assert that every dbg_ack eventually leads to rvfi_dbg,
  // but since there can be an infinite delay between dbg_ack and rvfi_dbg (e.g. because of bus stalls), we're settling for asserting
  // that dbg_ack leads to RVFI capturing the debug cause
  a_dbg_ack_rvfi_capture :
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     (dbg_ack |=> (debug_cause[STAGE_IF] == $past(debug_cause_int))))
            else `uvm_error("rvfi", "dbg_ack did not lead to rvfi_dbg != 0")

  // Helper signal, indicate that a debug entry was signaled on RVFI
  logic  rvfi_dbg_ack;
  assign rvfi_dbg_ack = |rvfi_dbg && rvfi_valid;

  // Helper signal, count outstanding dbg_ack
  bit [1:0] dbg_ack_cnt;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dbg_ack_cnt <= '0;
    end
    else begin
      if (dbg_ack && !rvfi_dbg_ack) begin
        dbg_ack_cnt <= dbg_ack_cnt+2'd1;
      end
      else if (rvfi_dbg_ack && !dbg_ack) begin
        dbg_ack_cnt <= dbg_ack_cnt-2'd1;
      end
    end
  end
  // Check that rvfi_dbg_ack is preceeded by dbg_ack
  a_rvfi_dbg_dbg_ack :
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     (rvfi_dbg_ack |-> (dbg_ack_cnt != 0)))
      else `uvm_error("rvfi", "rvfi_dbg not preceeded by dbg_ack")


  // Sequence used to locate rvfi_valid following rvfi_valid with prereq set
  sequence s_goto_next_rvfi_valid(prereq);
    (prereq && rvfi_valid) ##1 rvfi_valid[->1];
  endsequence

  logic no_debug;

  // Indicate debug mode, or single stepping
  assign no_debug = !(rvfi_csr_dcsr_rdata[2] || ctrl_fsm_i.debug_mode);

  // rvfi_trap should always be followed by rvfi_intr (as long as we're not in debug mode)
  a_rvfi_trap_intr :
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     no_debug throughout s_goto_next_rvfi_valid(|rvfi_trap) |->
                     rvfi_intr.intr)
      else `uvm_error("rvfi", "rvfi_trap not followed by rvfi_intr")

  // rvfi_trap[2] should always be followed by rvfi_dbg
  a_rvfi_trap_dbg :
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     s_goto_next_rvfi_valid(rvfi_trap.debug) |->
                     rvfi_dbg != '0)
      else `uvm_error("rvfi", "rvfi_trap.debug not followed by rvfi_dbg")

  // Exception code in rvfi_trap.exception_cause should align with mcause exception cause in the following retired instruction
  // This is exempt if we have an NMI, because NMI will result in mcause being updated in between retired instructions.
  // Also, in debug mode, mcause is not updated.
  a_rvfi_trap_mcause_align:
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                    (no_debug && !ctrl_fsm_i.pending_nmi) throughout s_goto_next_rvfi_valid(|rvfi_trap) |->
                     rvfi_intr.intr && (rvfi_csr_mcause_rdata[5:0] == rvfi_trap_q.exception_cause))
      else `uvm_error("rvfi", "rvfi_trap.exception_cause not consistent with mcause[5:0] in following retired instruction")

  // Exception code in rvfi_trap[11:9] should align with rvfi_dbg the following retired instruction
  a_rvfi_trap_rvfi_dbg_align:
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     s_goto_next_rvfi_valid(rvfi_trap.debug) |->
                     rvfi_dbg == rvfi_trap_q.debug_cause)
     else `uvm_error("rvfi", "rvfi_trap.debug_cause not consistent with rvfi_dbg in following retired instruction")

  // Check that rvfi_trap always indicate single step if rvfi_trap[2:1] == 2'b11
  a_rvfi_single_step_trap:
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     rvfi_trap.exception && rvfi_trap.debug |-> rvfi_trap.debug_cause == DBG_CAUSE_STEP)
     else `uvm_error("rvfi", "rvfi_trap[2:1] == 2'b11, but debug cause bits do not indicate single stepping")

  // Check that the trap is always signalled on the instruction before single step debug entry (unless killed by interrupt)
  a_rvfi_single_step_no_trap_no_dbg_entry:
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     s_goto_next_rvfi_valid(rvfi_trap.debug_cause != DBG_CAUSE_STEP) |-> ((rvfi_dbg != DBG_CAUSE_STEP) || rvfi_intr.intr))
     else `uvm_error("rvfi", "Single step debug entry without correct rvfi_trap first")

  // Check that dcsr.cause and mcause exception align with rvfi_trap when rvfi_trap[2:1] == 2'b11
  // rvfi_intr should also always be set in this case
  a_rvfi_trap_step_exception:
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     s_goto_next_rvfi_valid(rvfi_trap.exception && rvfi_trap.debug) |->
                     (rvfi_dbg == DBG_CAUSE_STEP) && (rvfi_csr_dcsr_rdata[8:6] == DBG_CAUSE_STEP) &&
                     (rvfi_csr_mcause_rdata[5:0] == rvfi_trap_q.exception_cause) &&
                     rvfi_intr.intr)
     else `uvm_error("rvfi", "dcsr.cause, mcause and rvfi_intr not as expected following an exception during single step")


  // Todo: Add assertion for rvfi_trap[13:12]


  // When dcsr.nmip is set, the next retired instruction should be the NMI handler (except in debug mode).
  // rvfi_intr should also be set.
  a_rvfi_nmip_nmi_handler:
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     (no_debug && $stable(mtvec_addr_i)) throughout s_goto_next_rvfi_valid(rvfi_csr_dcsr_rdata[3]) |->
                     rvfi_intr.intr &&
                     (rvfi_pc_rdata == {mtvec_addr_i, ctrl_fsm_i.nmi_mtvec_index, 2'b00}) &&
                     ((rvfi_csr_mcause_rdata[10:0] == INT_CAUSE_LSU_LOAD_FAULT) || (rvfi_csr_mcause_rdata[10:0] == INT_CAUSE_LSU_STORE_FAULT) ||
                     (rvfi_csr_mcause_rdata[10:0] == INT_CAUSE_LSU_LOAD_INTEGRITY_FAULT) || (rvfi_csr_mcause_rdata[10:0] == INT_CAUSE_LSU_STORE_INTEGRITY_FAULT)))
      else `uvm_error("rvfi", "dcsr.nmip not followed by rvfi_intr and NMI handler")


  /* TODO: Add back in.
     Currently, the alignment buffer can interpret pointers as compressed instructions and pass on two "instructions" from the IF stage.
     cv32e40x_rvfi_instr_obi will not be in sync with the alignment buffer until this is fixed. See https://github.com/openhwgroup/cv32e40x/issues/704

  // Check that cv32e40x_rvfi_instr_obi tracks alignment buffer
  a_rvfi_instr_obi_addr:
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     if_valid_i && id_ready_i && (obi_instr_if.resp_payload.mpu_status == MPU_OK) |->
                     (pc_if_i[31:2] == obi_instr_if.req_payload.addr[31:2]))
      else `uvm_error("rvfi", "rvfi_instr_obi addr does not track alignment buffer")

  a_rvfi_instr_obi_rdata_compressed:
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     if_valid_i && id_ready_i && prefetch_compressed_if_i && (obi_instr_if.resp_payload.mpu_status == MPU_OK) |->
                     (prefetch_instr_if_i.bus_resp.rdata[15:0] == obi_instr_if.resp_payload.bus_resp.rdata[15:0]))
      else `uvm_error("rvfi", "rvfi_instr_obi compressed rdata does not track alignment buffer")

  a_rvfi_instr_obi_rdata_uncompressed:
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     if_valid_i && id_ready_i && !prefetch_compressed_if_i && (obi_instr_if.resp_payload.mpu_status == MPU_OK) |->
                     (prefetch_instr_if_i.bus_resp.rdata[31:0] == obi_instr_if.resp_payload.bus_resp.rdata[31:0]))
      else `uvm_error("rvfi", "rvfi_instr_obi uncompressed rdata does not track alignment buffer")

  a_rvfi_instr_obi_err:
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     if_valid_i && id_ready_i && (obi_instr_if.resp_payload.mpu_status == MPU_OK) |->
                     (prefetch_instr_if_i.bus_resp.err == obi_instr_if.resp_payload.bus_resp.err))
      else `uvm_error("rvfi", "rvfi_instr_obi err does not track alignment buffer")

  a_rvfi_instr_mpu_status:
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     if_valid_i && id_ready_i |->
                     (prefetch_instr_if_i.mpu_status == obi_instr_if.resp_payload.mpu_status))
      else `uvm_error("rvfi", "rvfi_instr_obi mpu_status does not track alignment buffer")

  // Check that instructions fetched over two OBI transfers have the same OBI prot.
  // Ideally, this should be checked with a design assertion, but that is cumbersome since the aligmnent buffer interprets rdata to decide if an instruction is compressed or not.
  // By this time, the obi.prot for the given transfer(s) is no longer available.
  a_rvfi_instr_split_transfer_obi_prot:
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     prefetch_valid_if_i && prefetch_ready_if_i && !prefetch_compressed_if_i && (prefetch_addr_if_i[1:0] != 2'b00 && (obi_instr_if.resp_payload.mpu_status == MPU_OK)) |->
                     obi_instr_fifo_q[obi_instr_rptr_q].req_payload.prot == obi_instr_fifo_q[obi_instr_rptr_q_inc].req_payload.prot)
      else `uvm_error("rvfi", "rvfi_instr_obi prot not the same for split transfers")
  */

endmodule


