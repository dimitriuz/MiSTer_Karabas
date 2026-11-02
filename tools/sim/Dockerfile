# Simulation image for the Karabas_Profi MiSTer port: GHDL (VHDL-93c) + Icarus Verilog.
# Tagged karabas-sim:1 and driven by tools/sim.sh.
FROM debian:trixie
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ghdl iverilog python3 make \
    && rm -rf /var/lib/apt/lists/*
