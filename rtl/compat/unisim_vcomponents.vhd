-- Quartus 17 library stub: the vendored vendor-library package `vcomponents`
-- (Xilinx Unisim/Virtex primitive component declarations, referenced by some
-- converted modules) is not present when those libraries are not compiled, and
-- Quartus 17 aborts analysis on the reference. Upstream Vivado builds get it for
-- free; here it is provided as an EMPTY package compiled into library `unisim`
-- (added to the project with -library unisim). Result of the stage-1 spike
-- (docs/superpowers/plans/stage1-assets/compize_proto.py run); nothing in the
-- pinned upstream instantiates a component from this package.
package vcomponents is
end package vcomponents;
