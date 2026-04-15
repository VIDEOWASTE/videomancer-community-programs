-- Copyright (C) 2026 VIDEOWASTE
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of Videomancer Community Programs.
-- See LICENSE file in the repository root for full license text.
--
-- Program Name:
--   Temporal Diff
--
-- Author:
--   VIDEOWASTE
--
-- Overview:
--   Motion detection via temporal pixel difference. Compares current
--   pixels against delayed versions using BRAM variable delay to
--   extract motion/change information. Includes threshold, gain,
--   colorization, persistence, and overlay modes.
--
-- Architecture:
--   Stage 1: Input registration (1 clk)
--   Stage 2: Variable delay for comparison (3 clk)
--   Stage 3: Difference calculation (1 clk)
--   Stage 4: Threshold + gain + colorize (1 clk)
--   Stage 5: Persistence filter (1 clk)
--   Stage 6: Dry/wet mix (4 clk)
--
-- Register Map:
--   Register 0: Delay depth (comparison distance)
--   Register 1: Sensitivity / threshold
--   Register 2: Difference gain
--   Register 3: Colorize hue
--   Register 4: Decay / persistence
--   Register 5: (unused)
--   Register 6: Flags [abs_diff, full_color, invert, overlay, bypass]
--   Register 7: Dry/wet mix
--
-- Timing:
--   Total pipeline latency: 11 clock cycles

--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.all;
use work.core_pkg.all;
use work.video_stream_pkg.all;
use work.video_timing_pkg.all;

architecture temporal_diff of program_top is
    constant C_PROCESSING_DELAY_CLKS : integer := 11;
    constant C_DIFF_DELAY_DEPTH      : integer := 11;  -- 2048 pixel delay

    -- Control signals
    signal s_delay_depth   : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_threshold     : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_diff_gain     : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_colorize      : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_persistence   : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_abs_diff      : std_logic;
    signal s_full_color    : std_logic;
    signal s_invert        : std_logic;
    signal s_overlay       : std_logic;
    signal s_bypass_enable : std_logic;
    signal s_dry_wet       : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);

    -- Stage 1
    signal s_s1_y    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s1_u    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s1_v    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s1_avid : std_logic;

    -- Delay value
    signal s_delay_val : unsigned(C_DIFF_DELAY_DEPTH - 1 downto 0);

    -- Stage 2: delay output
    signal s_delayed_y       : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_delayed_y_valid : std_logic;

    -- Pipeline delay for current Y to match delay latency (3 clk)
    type t_y_pipe is array (0 to 2) of unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_y_pipe : t_y_pipe := (others => (others => '0'));
    type t_u_pipe is array (0 to 2) of unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_u_pipe : t_u_pipe := (others => to_unsigned(512, 10));
    type t_v_pipe is array (0 to 2) of unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_v_pipe : t_v_pipe := (others => to_unsigned(512, 10));
    signal s_current_y : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_current_u : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_current_v : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);

    -- Stage 3: difference
    signal s_diff_val  : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_diff_sign : std_logic;  -- '0'=positive, '1'=negative
    signal s_s3_avid   : std_logic;

    -- Stage 4: threshold + colorize
    signal s_s4_y    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s4_u    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s4_v    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s4_avid : std_logic;

    -- Stage 5: persistence
    signal s_persist_y : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0) := (others => '0');
    signal s_s5_y      : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s5_u      : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s5_v      : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s5_avid   : std_logic;

    -- Dry/wet mix
    signal s_mix_y_result : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_mix_u_result : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_mix_v_result : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_mix_y_valid  : std_logic;
    signal s_mix_u_valid  : std_logic;
    signal s_mix_v_valid  : std_logic;

    -- Bypass delay
    signal s_hsync_n_delayed : std_logic;
    signal s_vsync_n_delayed : std_logic;
    signal s_field_n_delayed : std_logic;
    signal s_y_delayed       : std_logic_vector(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_u_delayed       : std_logic_vector(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_v_delayed       : std_logic_vector(C_VIDEO_DATA_WIDTH - 1 downto 0);

begin
    -- Register mapping
    s_delay_depth   <= unsigned(registers_in(0));
    s_threshold     <= unsigned(registers_in(1));
    s_diff_gain     <= unsigned(registers_in(2));
    s_colorize      <= unsigned(registers_in(3));
    s_persistence   <= unsigned(registers_in(4));
    s_abs_diff      <= registers_in(6)(0);
    s_full_color    <= registers_in(6)(1);
    s_invert        <= registers_in(6)(2);
    s_overlay       <= registers_in(6)(3);
    s_bypass_enable <= registers_in(6)(4);
    s_dry_wet       <= unsigned(registers_in(7));

    -- Map delay depth
    s_delay_val <= resize(shift_right(s_delay_depth, 0), C_DIFF_DELAY_DEPTH);

    -- Stage 1: Input registration
    p_input_stage : process(clk)
    begin
        if rising_edge(clk) then
            s_s1_y    <= unsigned(data_in.y);
            s_s1_u    <= unsigned(data_in.u);
            s_s1_v    <= unsigned(data_in.v);
            s_s1_avid <= data_in.avid;
        end if;
    end process p_input_stage;

    -- Pipeline current Y/U/V to match delay latency
    p_y_pipeline : process(clk)
    begin
        if rising_edge(clk) then
            s_y_pipe <= s_s1_y & s_y_pipe(0 to 1);
            s_u_pipe <= s_s1_u & s_u_pipe(0 to 1);
            s_v_pipe <= s_s1_v & s_v_pipe(0 to 1);
        end if;
    end process p_y_pipeline;
    s_current_y <= s_y_pipe(2);
    s_current_u <= s_u_pipe(2);
    s_current_v <= s_v_pipe(2);

    -- Stage 2: Variable delay for temporal comparison
    diff_delay_y : entity work.variable_delay_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_DEPTH => C_DIFF_DELAY_DEPTH)
        port map(
            clk    => clk,
            enable => s_s1_avid,
            delay  => s_delay_val,
            a      => s_s1_y,
            result => s_delayed_y,
            valid  => s_delayed_y_valid
        );

    -- Stage 3: Difference calculation
    p_difference : process(clk)
        variable v_diff : signed(10 downto 0);
    begin
        if rising_edge(clk) then
            v_diff := resize(signed('0' & std_logic_vector(s_current_y)), 11) -
                      resize(signed('0' & std_logic_vector(s_delayed_y)), 11);

            if s_abs_diff = '1' or v_diff >= to_signed(0, 11) then
                if v_diff < to_signed(0, 11) then
                    s_diff_val <= unsigned(std_logic_vector(-v_diff(9 downto 0)));
                else
                    s_diff_val <= unsigned(v_diff(9 downto 0));
                end if;
                s_diff_sign <= '0';
            else
                s_diff_val  <= unsigned(std_logic_vector(-v_diff(9 downto 0)));
                s_diff_sign <= '1';
            end if;

            s_s3_avid <= s_delayed_y_valid;
        end if;
    end process p_difference;

    -- Stage 4: Threshold + gain + colorize
    p_thresh_color : process(clk)
        variable v_edge     : unsigned(9 downto 0);
        variable v_gained   : unsigned(19 downto 0);
    begin
        if rising_edge(clk) then
            v_edge := s_diff_val;

            -- Threshold
            if v_edge < s_threshold then
                v_edge := to_unsigned(0, 10);
            else
                v_edge := v_edge - resize(s_threshold, 10);
            end if;

            -- Gain
            v_gained := v_edge * s_diff_gain;
            if shift_right(v_gained, 9) > to_unsigned(1023, 20) then
                v_edge := to_unsigned(1023, 10);
            else
                v_edge := resize(shift_right(v_gained, 9), 10);
            end if;

            -- Invert
            if s_invert = '1' then
                v_edge := to_unsigned(1023, 10) - v_edge;
            end if;

            -- Overlay mode: add difference to original
            if s_overlay = '1' then
                if resize(s_current_y, 11) + resize(v_edge, 11) > to_unsigned(1023, 11) then
                    s_s4_y <= to_unsigned(1023, 10);
                else
                    s_s4_y <= s_current_y + v_edge;
                end if;
                s_s4_u <= s_current_u;
                s_s4_v <= s_current_v;
            else
                s_s4_y <= v_edge;

                -- Colorize based on sign/intensity
                if v_edge > to_unsigned(16, 10) then
                    if s_full_color = '1' then
                        -- Full color mode: positive diffs shift U,
                        -- negative diffs shift V, creating two distinct hues
                        if s_diff_sign = '0' then
                            -- Positive (current brighter): shift U
                            s_s4_u <= to_unsigned(512, 10) + resize(shift_right(s_colorize, 1), 10);
                            s_s4_v <= to_unsigned(512, 10);
                        else
                            -- Negative (current darker): shift V
                            s_s4_u <= to_unsigned(512, 10);
                            s_s4_v <= to_unsigned(512, 10) + resize(shift_right(s_colorize, 1), 10);
                        end if;
                    else
                        -- Absolute difference only: same color regardless of sign
                        s_s4_u <= to_unsigned(512, 10) + resize(shift_right(s_colorize, 1), 10);
                        s_s4_v <= to_unsigned(512, 10) - resize(shift_right(s_colorize, 2), 10);
                    end if;
                else
                    s_s4_u <= to_unsigned(512, 10);
                    s_s4_v <= to_unsigned(512, 10);
                end if;
            end if;

            s_s4_avid <= s_s3_avid;
        end if;
    end process p_thresh_color;

    -- Stage 5: Persistence (simple IIR decay)
    p_persist : process(clk)
        variable v_decay : unsigned(19 downto 0);
        variable v_combined : unsigned(10 downto 0);
    begin
        if rising_edge(clk) then
            if s_persistence > to_unsigned(0, 10) then
                -- Decay previous: persist_y = persist_y * persistence / 1024
                v_decay := s_persist_y * s_persistence;
                s_persist_y <= resize(shift_right(v_decay, 10), 10);

                -- Take max of new and decayed
                if s_s4_y > resize(shift_right(v_decay, 10), 10) then
                    s_s5_y <= s_s4_y;
                    s_persist_y <= s_s4_y;
                else
                    s_s5_y <= resize(shift_right(v_decay, 10), 10);
                end if;
            else
                s_s5_y <= s_s4_y;
            end if;

            s_s5_u    <= s_s4_u;
            s_s5_v    <= s_s4_v;
            s_s5_avid <= s_s4_avid;
        end if;
    end process p_persist;

    -- Stage 6: Dry/wet mix
    mix_y : entity work.interpolator_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_FRAC_BITS => C_VIDEO_DATA_WIDTH, G_OUTPUT_MIN => 0, G_OUTPUT_MAX => 1023)
        port map(clk => clk, enable => s_s5_avid, a => unsigned(s_y_delayed), b => s_s5_y, t => s_dry_wet, result => s_mix_y_result, valid => s_mix_y_valid);

    mix_u : entity work.interpolator_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_FRAC_BITS => C_VIDEO_DATA_WIDTH, G_OUTPUT_MIN => 0, G_OUTPUT_MAX => 1023)
        port map(clk => clk, enable => s_s5_avid, a => unsigned(s_u_delayed), b => s_s5_u, t => s_dry_wet, result => s_mix_u_result, valid => s_mix_u_valid);

    mix_v : entity work.interpolator_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_FRAC_BITS => C_VIDEO_DATA_WIDTH, G_OUTPUT_MIN => 0, G_OUTPUT_MAX => 1023)
        port map(clk => clk, enable => s_s5_avid, a => unsigned(s_v_delayed), b => s_s5_v, t => s_dry_wet, result => s_mix_v_result, valid => s_mix_v_valid);

    -- Bypass delay line
    p_bypass_delay : process(clk)
        type t_sync_delay is array (0 to C_PROCESSING_DELAY_CLKS - 1) of std_logic;
        type t_data_delay is array (0 to C_PROCESSING_DELAY_CLKS - 1) of std_logic_vector(C_VIDEO_DATA_WIDTH - 1 downto 0);
        variable v_hsync_delay : t_sync_delay := (others => '1');
        variable v_vsync_delay : t_sync_delay := (others => '1');
        variable v_field_delay : t_sync_delay := (others => '1');
        variable v_y_delay     : t_data_delay := (others => (others => '0'));
        variable v_u_delay     : t_data_delay := (others => (others => '0'));
        variable v_v_delay     : t_data_delay := (others => (others => '0'));
    begin
        if rising_edge(clk) then
            v_hsync_delay := data_in.hsync_n & v_hsync_delay(0 to C_PROCESSING_DELAY_CLKS - 2);
            v_vsync_delay := data_in.vsync_n & v_vsync_delay(0 to C_PROCESSING_DELAY_CLKS - 2);
            v_field_delay := data_in.field_n & v_field_delay(0 to C_PROCESSING_DELAY_CLKS - 2);
            v_y_delay     := data_in.y       & v_y_delay(0 to C_PROCESSING_DELAY_CLKS - 2);
            v_u_delay     := data_in.u       & v_u_delay(0 to C_PROCESSING_DELAY_CLKS - 2);
            v_v_delay     := data_in.v       & v_v_delay(0 to C_PROCESSING_DELAY_CLKS - 2);

            s_hsync_n_delayed <= v_hsync_delay(C_PROCESSING_DELAY_CLKS - 1);
            s_vsync_n_delayed <= v_vsync_delay(C_PROCESSING_DELAY_CLKS - 1);
            s_field_n_delayed <= v_field_delay(C_PROCESSING_DELAY_CLKS - 1);
            s_y_delayed       <= v_y_delay(C_PROCESSING_DELAY_CLKS - 1);
            s_u_delayed       <= v_u_delay(C_PROCESSING_DELAY_CLKS - 1);
            s_v_delayed       <= v_v_delay(C_PROCESSING_DELAY_CLKS - 1);
        end if;
    end process p_bypass_delay;

    -- Output
    data_out.y <= std_logic_vector(s_mix_y_result) when s_bypass_enable = '0' else s_y_delayed;
    data_out.u <= std_logic_vector(s_mix_u_result) when s_bypass_enable = '0' else s_u_delayed;
    data_out.v <= std_logic_vector(s_mix_v_result) when s_bypass_enable = '0' else s_v_delayed;
    data_out.avid    <= s_mix_y_valid and s_mix_u_valid and s_mix_v_valid;
    data_out.hsync_n <= s_hsync_n_delayed;
    data_out.vsync_n <= s_vsync_n_delayed;
    data_out.field_n <= s_field_n_delayed;

end temporal_diff;
