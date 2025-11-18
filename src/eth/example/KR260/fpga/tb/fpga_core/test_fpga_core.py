#!/usr/bin/env python
# SPDX-License-Identifier: MIT
"""

Copyright (c) 2020-2025 FPGA Ninja, LLC

Authors:
- Alex Forencich

"""

import logging
import os
import sys

import pytest
import cocotb_test.simulator

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, Combine

from cocotbext.eth import GmiiFrame, GmiiSource, GmiiSink, RgmiiPhy
from cocotbext.eth import XgmiiFrame

try:
    from baser import BaseRSerdesSource, BaseRSerdesSink
except ImportError:
    # attempt import from current directory
    sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
    try:
        from baser import BaseRSerdesSource, BaseRSerdesSink
    finally:
        del sys.path[0]


class TB:
    def __init__(self, dut, speed=1000e6):
        self.dut = dut

        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.DEBUG)

        self.baset_phy2 = RgmiiPhy(dut.phy2_rgmii_txd, dut.phy2_rgmii_tx_ctl, dut.phy2_rgmii_tx_clk,
            dut.phy2_rgmii_rxd, dut.phy2_rgmii_rx_ctl, dut.phy2_rgmii_rx_clk, speed=speed)

        self.baset_phy3 = RgmiiPhy(dut.phy3_rgmii_txd, dut.phy3_rgmii_tx_ctl, dut.phy3_rgmii_tx_clk,
            dut.phy3_rgmii_rxd, dut.phy3_rgmii_rx_ctl, dut.phy3_rgmii_rx_clk, speed=speed)

        self.sfp_sources = []
        self.sfp_sinks = []

        if dut.SFP_RATE.value == 0:
            cocotb.start_soon(Clock(dut.sfp_gmii_clk, 8, units="ns").start())

            self.sfp_sources.append(GmiiSource(dut.sfp_gmii_rxd, dut.sfp_gmii_rx_er, dut.sfp_gmii_rx_dv,
                dut.sfp_gmii_clk, dut.sfp_gmii_rst, dut.sfp_gmii_clk_en))
            self.sfp_sinks.append(GmiiSink(dut.sfp_gmii_txd, dut.sfp_gmii_tx_er, dut.sfp_gmii_tx_en,
                dut.sfp_gmii_clk, dut.sfp_gmii_rst, dut.sfp_gmii_clk_en))
        else:
            cocotb.start_soon(Clock(dut.sfp_mgt_refclk_p, 6.4, units="ns").start())

            ch = dut.sfp_mac.sfp_mac_inst.ch[0]
            gt_inst = ch.ch_inst.gt.gt_inst

            if ch.ch_inst.CFG_LOW_LATENCY.value:
                clk = 3.102
                gbx_cfg = (66, [64, 65])
            else:
                clk = 3.2
                gbx_cfg = None

            cocotb.start_soon(Clock(gt_inst.tx_clk, clk, units="ns").start())
            cocotb.start_soon(Clock(gt_inst.rx_clk, clk, units="ns").start())

            self.sfp_sources.append(BaseRSerdesSource(
                data=gt_inst.serdes_rx_data,
                data_valid=gt_inst.serdes_rx_data_valid,
                hdr=gt_inst.serdes_rx_hdr,
                hdr_valid=gt_inst.serdes_rx_hdr_valid,
                clock=gt_inst.rx_clk,
                slip=gt_inst.serdes_rx_bitslip,
                reverse=True,
                gbx_cfg=gbx_cfg
            ))
            self.sfp_sinks.append(BaseRSerdesSink(
                data=gt_inst.serdes_tx_data,
                data_valid=gt_inst.serdes_tx_data_valid,
                hdr=gt_inst.serdes_tx_hdr,
                hdr_valid=gt_inst.serdes_tx_hdr_valid,
                gbx_sync=gt_inst.serdes_tx_gbx_sync,
                clock=gt_inst.tx_clk,
                reverse=True,
                gbx_cfg=gbx_cfg
            ))

        cocotb.start_soon(self._run_clk())

    async def init(self):

        self.dut.rst.setimmediatevalue(0)
        self.dut.sfp_gmii_rst.setimmediatevalue(0)

        for k in range(10):
            await RisingEdge(self.dut.clk)

        self.dut.rst.value = 1
        self.dut.sfp_gmii_rst.value = 1

        for k in range(10):
            await RisingEdge(self.dut.clk)

        self.dut.rst.value = 0
        self.dut.sfp_gmii_rst.value = 0

        for k in range(10):
            await RisingEdge(self.dut.clk)

    async def _run_clk(self):
        t = Timer(2, 'ns')
        while True:
            self.dut.clk.value = 1
            await t
            self.dut.clk90.value = 1
            await t
            self.dut.clk.value = 0
            await t
            self.dut.clk90.value = 0
            await t


async def mac_test(tb, source, sink):
    tb.log.info("Test MAC")

    tb.log.info("Multiple small packets")

    count = 64

    pkts = [bytearray([(x+k) % 256 for x in range(60)]) for k in range(count)]

    for p in pkts:
        await source.send(GmiiFrame.from_payload(p))

    for k in range(count):
        rx_frame = await sink.recv()

        tb.log.info("RX frame: %s", rx_frame)

        assert rx_frame.get_payload() == pkts[k]
        assert rx_frame.check_fcs()
        assert rx_frame.error is None

    tb.log.info("Multiple large packets")

    count = 32

    pkts = [bytearray([(x+k) % 256 for x in range(1514)]) for k in range(count)]

    for p in pkts:
        await source.send(GmiiFrame.from_payload(p))

    for k in range(count):
        rx_frame = await sink.recv()

        tb.log.info("RX frame: %s", rx_frame)

        assert rx_frame.get_payload() == pkts[k]
        assert rx_frame.check_fcs()
        assert rx_frame.error is None

    tb.log.info("MAC test done")


async def mac_test_10g(tb, source, sink):
    tb.log.info("Test MAC")

    tb.log.info("Wait for block lock")
    for k in range(1200):
        await RisingEdge(tb.dut.clk)

    tb.log.info("Multiple small packets")

    count = 64

    pkts = [bytearray([(x+k) % 256 for x in range(60)]) for k in range(count)]

    for p in pkts:
        await source.send(XgmiiFrame.from_payload(p))

    for k in range(count):
        rx_frame = await sink.recv()

        tb.log.info("RX frame: %s", rx_frame)

        assert rx_frame.get_payload() == pkts[k]
        assert rx_frame.check_fcs()

    tb.log.info("Multiple large packets")

    count = 32

    pkts = [bytearray([(x+k) % 256 for x in range(1514)]) for k in range(count)]

    for p in pkts:
        await source.send(XgmiiFrame.from_payload(p))

    for k in range(count):
        rx_frame = await sink.recv()

        tb.log.info("RX frame: %s", rx_frame)

        assert rx_frame.get_payload() == pkts[k]
        assert rx_frame.check_fcs()

    tb.log.info("MAC test done")


@cocotb.test()
async def run_test(dut):

    tb = TB(dut)

    await tb.init()

    tests = []

    tb.log.info("Start BASE-T MAC loopback test on PHY2")

    tests.append(cocotb.start_soon(mac_test(tb, tb.baset_phy2.rx, tb.baset_phy2.tx)))

    tb.log.info("Start BASE-T MAC loopback test on PHY3")

    tests.append(cocotb.start_soon(mac_test(tb, tb.baset_phy3.rx, tb.baset_phy3.tx)))

    if dut.SFP_RATE.value == 0:
        tb.log.info("Start 1G SFP MAC loopback test")
        tests.append(cocotb.start_soon(mac_test(tb, tb.sfp_sources[0], tb.sfp_sinks[0])))
    else:
        tb.log.info("Start 10G SFP MAC loopback test")
        tests.append(cocotb.start_soon(mac_test_10g(tb, tb.sfp_sources[0], tb.sfp_sinks[0])))

    await Combine(*tests)

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


# cocotb-test

tests_dir = os.path.abspath(os.path.dirname(__file__))
rtl_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'rtl'))
lib_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'lib'))
taxi_src_dir = os.path.abspath(os.path.join(lib_dir, 'taxi', 'src'))


def process_f_files(files):
    lst = {}
    for f in files:
        if f[-2:].lower() == '.f':
            with open(f, 'r') as fp:
                l = fp.read().split()
            for f in process_f_files([os.path.join(os.path.dirname(f), x) for x in l]):
                lst[os.path.basename(f)] = f
        else:
            lst[os.path.basename(f)] = f
    return list(lst.values())


@pytest.mark.parametrize("sfp_rate", [0, 1])
def test_fpga_core(request, sfp_rate):
    dut = "fpga_core"
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f"{dut}.sv"),
        os.path.join(taxi_src_dir, "eth", "rtl", "taxi_eth_mac_1g_fifo.f"),
        os.path.join(taxi_src_dir, "eth", "rtl", "us", "taxi_eth_mac_25g_us.f"),
        os.path.join(taxi_src_dir, "eth", "rtl", "taxi_eth_mac_1g_rgmii_fifo.f"),
        os.path.join(taxi_src_dir, "sync", "rtl", "taxi_sync_reset.sv"),
        os.path.join(taxi_src_dir, "sync", "rtl", "taxi_sync_signal.sv"),
    ]

    verilog_sources = process_f_files(verilog_sources)

    parameters = {}

    parameters['SIM'] = "1'b1"
    parameters['VENDOR'] = "\"XILINX\""
    parameters['FAMILY'] = "\"zynquplus\""
    parameters['USE_CLK90'] = "1'b1"
    parameters['SFP_RATE'] = f"1'b{sfp_rate}"

    extra_env = {f'PARAM_{k}': str(v) for k, v in parameters.items()}

    sim_build = os.path.join(tests_dir, "sim_build",
        request.node.name.replace('[', '-').replace(']', ''))

    cocotb_test.simulator.run(
        simulator="verilator",
        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        toplevel=toplevel,
        module=module,
        parameters=parameters,
        sim_build=sim_build,
        extra_env=extra_env,
    )
