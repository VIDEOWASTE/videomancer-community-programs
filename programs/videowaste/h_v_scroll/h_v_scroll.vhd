-- Copyright (C) 2026 VIDEOWASTE
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of Videomancer Community Programs.
-- See LICENSE file in the repository root for full license text.
--
-- Program Name:
--   H/V Scroll
--
-- Author:
--   VIDEOWASTE
--
-- Overview:
--   Horizontal scroll/pan with animated motion and diagonal rolling.
--   Uses variable delay lines for horizontal pixel displacement with
--   optional per-line variation creating diagonal or rolling patterns.
--
-- Architecture:
--   Stage 1: Input registration (1 clk)
--   Stage 2: Scroll offset calculation (1 clk)
--   Stage 3: Variable delay for H scroll (3 clk)
--   Stage 4: Compose with wrap blend (1 clk)
--   Stage 5: Dry/wet mix (4 clk)
--
-- Register Map:
--   Register 0: H scroll position (0-1023)
--   Register 1: H scroll speed (auto-animation)
--   Register 2: V scroll speed (rolling effect rate)
--   Register 3: Diagonal amount (per-line H offset variation)
--   Register 4: Wrap blend
--   Register 5: Bounce amplitude (0=off/linear scroll, 1023=max oscillation)
--   Register 6: Flags [animate_h, animate_v, reverse, quantize, bypass]
--   Register 7: Dry/wet mix
--
-- Timing:
--   Total pipeline latency: 10 clock cycles

--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.all;
use work.core_pkg.all;
use work.video_stream_pkg.all;
use work.video_timing_pkg.all;

architecture h_v_scroll of program_top is
    constant C_PROCESSING_DELAY_CLKS : integer := 10;
    constant C_SCROLL_DEPTH          : integer := 10;  -- 1024 pixel max

    -- Control signals
    signal s_h_position    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_h_speed       : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_v_speed       : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_diagonal      : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_wrap_blend    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_bounce        : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_animate_h     : std_logic;
    signal s_animate_v     : std_logic;
    signal s_reverse       : std_logic;
    signal s_quantize      : std_logic;
    signal s_bypass_enable : std_logic;
    signal s_dry_wet       : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);

    -- Animation counters
    signal s_prev_vsync  : std_logic := '1';
    signal s_prev_hsync  : std_logic := '1';
    signal s_frame_count : unsigned(15 downto 0) := (others => '0');
    signal s_line_count  : unsigned(11 downto 0) := (others => '0');

    -- Stage 1
    signal s_s1_y    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s1_u    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s1_v    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s1_avid : std_logic;

    -- Stage 2: scroll offset
    signal s_scroll_delay : unsigned(C_SCROLL_DEPTH - 1 downto 0);
    signal s_s2_avid      : std_logic;

    -- Stage 3: delay outputs
    signal s_scroll_y_result : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_scroll_u_result : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_scroll_v_result : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_scroll_y_valid  : std_logic;
    signal s_scroll_u_valid  : std_logic;
    signal s_scroll_v_valid  : std_logic;

    -- Delay-matched scroll offset for compose stage
    signal s_scroll_delay_d3 : unsigned(C_SCROLL_DEPTH - 1 downto 0);

    -- Compose
    signal s_comp_y    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_comp_u    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_comp_v    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_comp_avid : std_logic;

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
    s_h_position    <= unsigned(registers_in(0));
    s_h_speed       <= unsigned(registers_in(1));
    s_v_speed       <= unsigned(registers_in(2));
    s_diagonal      <= unsigned(registers_in(3));
    s_wrap_blend    <= unsigned(registers_in(4));
    s_bounce        <= unsigned(registers_in(5));
    s_animate_h     <= registers_in(6)(0);
    s_animate_v     <= registers_in(6)(1);
    s_reverse       <= registers_in(6)(2);
    s_quantize      <= registers_in(6)(3);
    s_bypass_enable <= registers_in(6)(4);
    s_dry_wet       <= unsigned(registers_in(7));

    -- Frame and line counters
    p_counters : process(clk)
    begin
        if rising_edge(clk) then
            s_prev_vsync <= data_in.vsync_n;
            s_prev_hsync <= data_in.hsync_n;

            if data_in.hsync_n = '0' and s_prev_hsync = '1' then
                s_line_count <= s_line_count + 1;
            end if;

            if data_in.vsync_n = '0' and s_prev_vsync = '1' then
                s_line_count <= (others => '0');
                if s_reverse = '1' then
                    s_frame_count <= s_frame_count - 1;
                else
                    s_frame_count <= s_frame_count + 1;
                end if;
            end if;
        end if;
    end process p_counters;

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

    -- Stage 2: Scroll offset calculation
    p_scroll_calc : process(clk)
        variable v_offset   : unsigned(15 downto 0);
        variable v_diag     : unsigned(15 downto 0);
        variable v_bounce_phase : unsigned(9 downto 0);
        variable v_triangle : unsigned(9 downto 0);
        variable v_bounce_offset : unsigned(15 downto 0);
        variable v_final    : unsigned(C_SCROLL_DEPTH - 1 downto 0);
    begin
        if rising_edge(clk) then
            -- Base position
            v_offset := resize(s_h_position, 16);

            -- Add animated H offset
            if s_animate_h = '1' then
                v_offset := v_offset + resize(
                    shift_right(s_frame_count * resize(s_h_speed, 16), 4), 16);
            end if;

            -- Add per-line diagonal
            v_diag := resize(shift_right(
                resize(s_line_count, 16) * resize(s_diagonal, 16), 10), 16);
            v_offset := v_offset + v_diag;

            -- Add animated V component (rolling)
            if s_animate_v = '1' then
                v_offset := v_offset + resize(
                    shift_right(s_frame_count * resize(s_v_speed, 16), 2), 16);
            end if;

            -- Bounce: oscillate scroll position with a triangle wave
            -- bounce=0: no effect, bounce=1023: full ping-pong oscillation
            -- Triangle wave from frame counter: ramp up then down
            if s_bounce > to_unsigned(0, C_VIDEO_DATA_WIDTH) then
                -- Use bits 9:0 of frame count as phase (1024 frames per cycle)
                v_bounce_phase := s_frame_count(9 downto 0);

                -- Triangle wave: 0->511->0 over one cycle
                if v_bounce_phase(9) = '0' then
                    -- First half: ramp up
                    v_triangle := '0' & v_bounce_phase(8 downto 0);
                else
                    -- Second half: ramp down
                    v_triangle := '0' & (not v_bounce_phase(8 downto 0));
                end if;

                -- Scale triangle by bounce amplitude: (triangle * bounce) >> 9
                v_bounce_offset := resize(shift_right(
                    resize(v_triangle, 16) * resize(s_bounce, 16), 9), 16);

                v_offset := v_offset + v_bounce_offset;
            end if;

            -- Truncate to delay line width
            v_final := resize(v_offset, C_SCROLL_DEPTH);

            -- Quantize: snap to 32-pixel grid for stuttery jump-cut scroll
            if s_quantize = '1' then
                v_final := v_final(C_SCROLL_DEPTH - 1 downto 5) & "00000";
            end if;

            s_scroll_delay <= v_final;
            s_s2_avid      <= s_s1_avid;
        end if;
    end process p_scroll_calc;

    -- Stage 3: Variable delay for H scroll
    scroll_y : entity work.variable_delay_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_DEPTH => C_SCROLL_DEPTH)
        port map(clk => clk, enable => s_s1_avid, delay => s_scroll_delay, a => s_s1_y, result => s_scroll_y_result, valid => s_scroll_y_valid);

    scroll_u : entity work.variable_delay_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_DEPTH => C_SCROLL_DEPTH)
        port map(clk => clk, enable => s_s1_avid, delay => s_scroll_delay, a => s_s1_u, result => s_scroll_u_result, valid => s_scroll_u_valid);

    scroll_v : entity work.variable_delay_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_DEPTH => C_SCROLL_DEPTH)
        port map(clk => clk, enable => s_s1_avid, delay => s_scroll_delay, a => s_s1_v, result => s_scroll_v_result, valid => s_scroll_v_valid);

    -- Delay scroll offset by 3 clocks to match variable_delay latency
    p_scroll_delay_match : process(clk)
        variable v_d1 : unsigned(C_SCROLL_DEPTH - 1 downto 0) := (others => '0');
        variable v_d2 : unsigned(C_SCROLL_DEPTH - 1 downto 0) := (others => '0');
    begin
        if rising_edge(clk) then
            s_scroll_delay_d3 <= v_d2;
            v_d2 := v_d1;
            v_d1 := s_scroll_delay;
        end if;
    end process p_scroll_delay_match;

    -- Compose with wrap blend
    -- When wrap_blend > 0, pixels near the delay line boundary fade to black.
    -- Distance to nearest boundary = min(scroll_delay, 1023 - scroll_delay).
    -- If distance < wrap_blend, pixel brightness is scaled by (distance / wrap_blend).
    -- wrap_blend=0: hard wrap (no fading), wrap_blend=1023: maximum fade zone.
    p_compose : process(clk)
        variable v_dist_lo : unsigned(C_SCROLL_DEPTH - 1 downto 0);
        variable v_dist_hi : unsigned(C_SCROLL_DEPTH - 1 downto 0);
        variable v_dist    : unsigned(C_SCROLL_DEPTH - 1 downto 0);
        variable v_fade    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
        variable v_scaled  : unsigned(2 * C_VIDEO_DATA_WIDTH - 1 downto 0);
    begin
        if rising_edge(clk) then
            -- Compute distance to nearest delay line boundary
            v_dist_lo := s_scroll_delay_d3;
            v_dist_hi := to_unsigned(1023, C_SCROLL_DEPTH) - s_scroll_delay_d3;

            if v_dist_lo < v_dist_hi then
                v_dist := v_dist_lo;
            else
                v_dist := v_dist_hi;
            end if;

            -- Compute fade factor (0 = black, 1023 = full brightness)
            if s_wrap_blend = to_unsigned(0, C_VIDEO_DATA_WIDTH) then
                -- Hard wrap: no fading
                v_fade := to_unsigned(1023, C_VIDEO_DATA_WIDTH);
            elsif resize(v_dist, C_VIDEO_DATA_WIDTH) >= s_wrap_blend then
                -- Outside blend zone: full brightness
                v_fade := to_unsigned(1023, C_VIDEO_DATA_WIDTH);
            else
                -- Inside blend zone: fade = (dist * 1023) / wrap_blend
                v_scaled := resize(v_dist, C_VIDEO_DATA_WIDTH) *
                            to_unsigned(1023, C_VIDEO_DATA_WIDTH);
                v_fade := resize(v_scaled / resize(s_wrap_blend, 2 * C_VIDEO_DATA_WIDTH),
                                 C_VIDEO_DATA_WIDTH);
            end if;

            -- Apply fade: scale Y toward 0, U toward 512, V toward 512
            -- Y_out = Y * fade / 1023
            v_scaled := resize(s_scroll_y_result, C_VIDEO_DATA_WIDTH) *
                        resize(v_fade, C_VIDEO_DATA_WIDTH);
            s_comp_y <= resize(shift_right(v_scaled, C_VIDEO_DATA_WIDTH),
                               C_VIDEO_DATA_WIDTH);

            -- U_out = 512 + ((U - 512) * fade) / 1023
            -- Since U is unsigned, compute as: 512 + ((U * fade) - (512 * fade)) >> 10
            -- Simplified: (U * fade + 512 * (1023 - fade)) / 1023
            v_scaled := resize(s_scroll_u_result, C_VIDEO_DATA_WIDTH) *
                        resize(v_fade, C_VIDEO_DATA_WIDTH) +
                        to_unsigned(512, C_VIDEO_DATA_WIDTH) *
                        resize(to_unsigned(1023, C_VIDEO_DATA_WIDTH) - v_fade,
                               C_VIDEO_DATA_WIDTH);
            s_comp_u <= resize(shift_right(v_scaled, C_VIDEO_DATA_WIDTH),
                               C_VIDEO_DATA_WIDTH);

            -- V_out same as U
            v_scaled := resize(s_scroll_v_result, C_VIDEO_DATA_WIDTH) *
                        resize(v_fade, C_VIDEO_DATA_WIDTH) +
                        to_unsigned(512, C_VIDEO_DATA_WIDTH) *
                        resize(to_unsigned(1023, C_VIDEO_DATA_WIDTH) - v_fade,
                               C_VIDEO_DATA_WIDTH);
            s_comp_v <= resize(shift_right(v_scaled, C_VIDEO_DATA_WIDTH),
                               C_VIDEO_DATA_WIDTH);

            s_comp_avid <= s_scroll_y_valid;
        end if;
    end process p_compose;

    -- Dry/wet mix
    mix_y : entity work.interpolator_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_FRAC_BITS => C_VIDEO_DATA_WIDTH, G_OUTPUT_MIN => 0, G_OUTPUT_MAX => 1023)
        port map(clk => clk, enable => s_comp_avid, a => unsigned(s_y_delayed), b => s_comp_y, t => s_dry_wet, result => s_mix_y_result, valid => s_mix_y_valid);

    mix_u : entity work.interpolator_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_FRAC_BITS => C_VIDEO_DATA_WIDTH, G_OUTPUT_MIN => 0, G_OUTPUT_MAX => 1023)
        port map(clk => clk, enable => s_comp_avid, a => unsigned(s_u_delayed), b => s_comp_u, t => s_dry_wet, result => s_mix_u_result, valid => s_mix_u_valid);

    mix_v : entity work.interpolator_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_FRAC_BITS => C_VIDEO_DATA_WIDTH, G_OUTPUT_MIN => 0, G_OUTPUT_MAX => 1023)
        port map(clk => clk, enable => s_comp_avid, a => unsigned(s_v_delayed), b => s_comp_v, t => s_dry_wet, result => s_mix_v_result, valid => s_mix_v_valid);

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

end h_v_scroll;
