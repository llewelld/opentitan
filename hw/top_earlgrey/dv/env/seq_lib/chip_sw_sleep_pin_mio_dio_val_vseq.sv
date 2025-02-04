// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

class chip_sw_sleep_pin_mio_dio_val_vseq extends chip_sw_base_vseq;
  `uvm_object_utils(chip_sw_sleep_pin_mio_dio_val_vseq)

  `uvm_object_new

  import chip_common_pkg::*;  // chip_io_e

  localparam int unsigned NumMioPads = top_earlgrey_pkg::MioPadCount;
  localparam int unsigned NumDioPads = top_earlgrey_pkg::DioCount;

  typedef enum bit [2:0] {
    Ret0,  // PAD driving 0 while in retention
    Ret1,  // PAD driving 1 while in retention
    HighZ, // PAD is input mode while in retention
    RetP,  // PAD keeps the prev. value while in retention
    RetSkip // Skip the test
  } pad_ret_t;

  pad_ret_t [NumMioPads-1:0] mio_pad_ret;
  pad_ret_t [NumDioPads-1:0] dio_pad_ret;

  typedef pad_ret_t pads_ret_t[IoNumTotal];
  pads_ret_t pad_ret;

  string ios_to_miodio [IoNumTotal];

  bit [IoNumTotal-1:0] highz_oe;

  task pre_start();
    super.pre_start();

    // Create io -> miodio
    ios_to_miodio = '{default: "Unmapped"};
    foreach (MioPads[i]) begin
      `DV_CHECK_STREQ(ios_to_miodio[MioPads[i]], "Unmapped",
        $sformatf("MioPads cannot map to chip_io_e correctly: %s",
          ios_to_miodio[MioPads[i]]))
      ios_to_miodio[MioPads[i]] = $sformatf("MIO [%2d]", i);
    end
    foreach (DioPads[i]) begin
      `DV_CHECK_STREQ(ios_to_miodio[DioPads[i]], "Unmapped",
        $sformatf("DioPads cannot map to chip_io_e correctly: %s",
          ios_to_miodio[DioPads[i]]))
      ios_to_miodio[DioPads[i]] = $sformatf("DIO [%2d]", i);
    end

  endtask : pre_start

  task dut_init(string reset_kind = "HARD");
    super.dut_init();

    // Force LC state to Prod in order to disable strap.
    cfg.mem_bkdr_util_h[Otp].otp_write_lc_partition_state(LcStProd);
  endtask : dut_init

  // SW sends chosen values via sw_logger_if. receive_chosen_value waits and
  // stores the values to the list.
  //
  // The transfer begins with "BEGIN Chosen Retention Types" and ends with
  // "END Chosen Retention Types".
  // In between, the data format is:
  //
  //   {M/D}IO [pad_num]: {0,1,2}
  //
  // For example, "MIO [14]: 2" indicates the MIO 14 will be configured as
  // High-Z mode in deep powerdown.
  task receive_chosen_values();
    string       printed_log;
    int unsigned idx;
    pad_ret_t    pad_type;

    string rcv_str;

    `DV_WAIT(cfg.sw_logger_vif.printed_log == "BEGIN Chosen Retention Types")

    forever begin
      @(cfg.sw_logger_vif.printed_log_event);

      // Check if format matches
      printed_log = string'(cfg.sw_logger_vif.printed_log);

      // Check exit condition
      if (printed_log == "END Chosen Retention Types") break;

      case (printed_log.substr(0,4))

        "DIO [": begin
          idx      = cfg.sw_logger_vif.printed_arg[0];
          pad_type = pad_ret_t'(cfg.sw_logger_vif.printed_arg[1]);
          assert (cfg.sw_logger_vif.printed_arg[1] inside {[0:3]});

          dio_pad_ret[idx] = pad_type;
        end

        "MIO [": begin
          idx      = cfg.sw_logger_vif.printed_arg[0];
          pad_type = pad_ret_t'(cfg.sw_logger_vif.printed_arg[1]);
          assert (cfg.sw_logger_vif.printed_arg[1] inside {[0:3]});

          mio_pad_ret[idx] = pad_type;
        end

        default: begin
          `uvm_info(`gfn,
            $sformatf("Unexpected SW Log is received: %s", printed_log),
            UVM_LOW)
        end

      endcase

    end // forever

    // Convert received maps to Ios
    pad_ret = miodio_to_ios(mio_pad_ret, dio_pad_ret);

    // Print the received types
    rcv_str = "BEGIN Received PAD Retention Types:";
    foreach (dio_pad_ret[i]) begin
      rcv_str = {rcv_str, "\n",
                 $sformatf("  DIO [%d]: %d", i, dio_pad_ret[i])};
    end
    foreach (mio_pad_ret[i]) begin
      rcv_str = {rcv_str, "\n",
                 $sformatf("  MIO [%d]: %d", i, mio_pad_ret[i])};
    end
    rcv_str = {rcv_str, "\n", "END Received PAD Retention Types"};
    `uvm_info(`gfn, rcv_str, UVM_LOW)

    rcv_str = "";
    foreach (pad_ret[i]) begin
      chip_io_e pad = chip_io_e'(i);
      rcv_str = {rcv_str, "\n",
                 $sformatf(" IO[%2d/%20s]: %9s %s",
                   i, pad.name, pad_ret[i].name, ios_to_miodio[i])};
    end
    `uvm_info(`gfn, rcv_str, UVM_LOW)
  endtask : receive_chosen_values

  function pads_ret_t miodio_to_ios(
    pad_ret_t [NumMioPads-1:0] mio,
    pad_ret_t [NumDioPads-1:0] dio
  );
    // Default Skip
    pads_ret_t result;
    result = '{default: RetSkip};

    foreach (MioPads[i]) begin
      assert(result[MioPads[i]] == RetSkip)
      result[MioPads[i]] = mio[i];
    end

    foreach (DioPads[i]) begin
      assert(result[DioPads[i]] == RetSkip)
      result[DioPads[i]] = dio[i];
    end

    return result;
  endfunction : miodio_to_ios


  // Check Ret0, Ret1 sampled values with expected.
  // global member variables: ios_to_miodio, pad_ret
  function void check_pad_retention_out(logic [IoNumTotal-1:0] sampled);
    foreach (pad_ret[i]) begin
      bit pad_sampled    = sampled[i];
      bit pad_expected   = (pad_ret[i] == Ret1) ? 1'b 1 : 1'b 0;
      chip_io_e pad_name = chip_io_e'(i);

      // Skip if not candidate.
      if (!(pad_ret[i] inside {Ret0, Ret1})) continue;

      `DV_CHECK(pad_sampled == pad_expected,
                $sformatf(
                  "IO[%2d/%s] %s: sampled(%b) / exp(%b)",
                  i, pad_name.name, ios_to_miodio[i],
                  pad_sampled, pad_expected))
    end
  endfunction : check_pad_retention_out

  function bit [IoNumTotal-1:0] build_highz_oe(pads_ret_t ret);
    bit [IoNumTotal-1:0] result = '0;
    int find[$];

    find = ret.find_index(x) with (x == HighZ);
    foreach(find[i]) begin
      result[find[i]] = 1'b 1;
    end

    return result;
  endfunction : build_highz_oe

  task check_pads_retention_type();
    logic [IoNumTotal-1:0] pad;
    /**
     * How to check 0, 1, High-Z
     *
     * For 0, 1, DUT drives the PADs. First, let ENV high-Z any PADs interface
     * and capture. The signal should match with the config. Then, repeat with
     * Pull-down mode, then Pull-up mode. The values should same in all cases.
     *
     * For High-Z, DUT is in input mode. In this case, the PAD attributes may
     * affect the signal. To confirm, ENV drives 0 and samples, then drives
     * 1 and samples. In each case, the sampled value should match to the
     * driving value not X or othe values.
     */

    // High-Z for all ports
    `uvm_info(`gfn, "Testing Retention Outputs", UVM_LOW)
    cfg.chip_vif.ios_if.pins_pd = '0;
    cfg.chip_vif.ios_if.pins_pu = '0;
    pad = cfg.chip_vif.ios_if.sample();

    check_pad_retention_out(pad);

    // Pull-down then check
    `uvm_info(`gfn, "Testing Retention Outputs with Pull-down", UVM_LOW)
    cfg.chip_vif.ios_if.pins_pd = '1;
    cfg.chip_vif.ios_if.pins_pu = '0;
    @(cfg.chip_vif.pwrmgr_low_power_if.cb);
    pad = cfg.chip_vif.ios_if.sample();

    check_pad_retention_out(pad);

    // Pull-up then check
    `uvm_info(`gfn, "Testing Retention Outputs with Pull-up", UVM_LOW)
    cfg.chip_vif.ios_if.pins_pd = '0;
    cfg.chip_vif.ios_if.pins_pu = '1;
    @(cfg.chip_vif.pwrmgr_low_power_if.cb);
    pad = cfg.chip_vif.ios_if.sample();

    check_pad_retention_out(pad);


    // Build High-Z drive map (highz_oe)
    highz_oe = build_highz_oe(pad_ret);

    cfg.chip_vif.ios_if.pins_pd = '0;
    cfg.chip_vif.ios_if.pins_pu = '0;

    // High-Z check: Drive 0 then check
    cfg.chip_vif.ios_if.pins_o = '0;
    cfg.chip_vif.ios_if.pins_oe = highz_oe;
    @(cfg.chip_vif.pwrmgr_low_power_if.cb);
    pad = cfg.chip_vif.ios_if.sample();

    for (int i = 0; i < IoNumTotal; i++) begin
      if (highz_oe[i]) begin
        chip_io_e pad_name = chip_io_e'(i);
        `DV_CHECK_EQ(pad[i], 1'b 0,
          $sformatf("High-Z Drive0 failed: IO[%2d/%9s] %s %p",
            i, pad_name.name, ios_to_miodio[i], pad[i]))
      end
    end

    // High-Z check: Drive 1 then check
    cfg.chip_vif.ios_if.pins_o = '1;
    cfg.chip_vif.ios_if.pins_oe = highz_oe;
    @(cfg.chip_vif.pwrmgr_low_power_if.cb);
    pad = cfg.chip_vif.ios_if.sample();

    for (int i = 0; i < IoNumTotal; i++) begin
      if (highz_oe[i]) begin
        chip_io_e pad_name = chip_io_e'(i);
        `DV_CHECK_EQ(pad[i], 1'b 1,
          $sformatf("High-Z Drive1 failed: IO[%2d/%9s] %s %p",
            i, pad_name.name, ios_to_miodio[i], pad[i]))
      end
    end

  endtask : check_pads_retention_type

  virtual task body();
    super.body();

    // Wait until we reach the SW test state.
    `DV_WAIT(cfg.sw_test_status_vif.sw_test_status == SwTestStatusInTest)

    // TODO: Get expected MIO DIO value from SW
    fork
      receive_chosen_values();
    join_none

    // Wait until Chip enters Low Power Mode
    wait (cfg.chip_vif.pwrmgr_low_power_if.in_sleep);
    @(cfg.chip_vif.pwrmgr_low_power_if.cb);

    // Release any driver interfaces.
    cfg.chip_vif.disconnect_all_interfaces(
      .disconnect_default_pulls(1'b 0));

    @(cfg.chip_vif.pwrmgr_low_power_if.cb);

    `uvm_info(`gfn, "Chip Entered Deep Powerdown mode.", UVM_LOW)

    check_pads_retention_type();

    // If `chech_pad_retention_type()` runs without uvm_error and reach this point, the test passed full check
    override_test_status_and_finish(.passed(1'b 1));

  endtask : body

endclass : chip_sw_sleep_pin_mio_dio_val_vseq
