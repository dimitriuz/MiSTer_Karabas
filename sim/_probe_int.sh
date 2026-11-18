#!/usr/bin/env bash
cd "$(dirname "$0")/.."
T=upstream/karabas-go-core-profi/src/rtl/t80se; U=upstream/karabas-go-core-profi/src/rtl/mouse
STD="--std=93c -fsynopsys -fexplicit"
MOUSE=${MOUSE:-build/sim/serial_mouse/serial_mouse_rewritten.vhd}
rm -rf build/sim/pi; mkdir -p build/sim/pi
ghdl -a $STD --workdir=build/sim/pi $T/T80_Pack.vhd $T/T80_MCode.vhd $T/T80_ALU.vhd $T/T80_Reg.vhd $T/T80.vhd $T/T80s.vhd $U/hw_int.vhd $MOUSE sim/_probe_int.vhd 2>&1 | grep -i "error"
ghdl -e $STD --workdir=build/sim/pi probe_int && ghdl -r $STD --workdir=build/sim/pi probe_int --stop-time=800us 2>&1 | grep -E "event|error|OUT"
