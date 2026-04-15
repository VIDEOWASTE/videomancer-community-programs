-- Copyright (C) 2026 VIDEOWASTE
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of Videomancer Community Programs.
-- See LICENSE file in the repository root for full license text.
--
-- Program Name:
--   Time Sculpt
--
-- Author:
--   VIDEOWASTE
--
-- Overview:
--   Movable temporal lens effect. A zone on screen is time-displaced
--   while the rest plays in real-time. Zone position, size, and shape
--   are controllable. Luma modulates the delay amount within the zone.
--   IIR smoothing stabilizes the displacement map.
--
-- Architecture:
--   Stage 1: Input registration + pixel counting (1 clk)
--   Stage 2: Zone distance + delay calculation (1 clk)
--   Stage 3: Variable delay x3 (2 clk)
--   Stage 4: Zone masking + output (1 clk)
--   Stage 5: Dry/wet mix (4 clk)
--
-- Register Map:
--   Register 0: Zone X (horizontal center, 0=left, 1023=right)
--   Register 1: Zone Y (vertical center, 0=top, 1023=bottom)
--   Register 2: Zone Size (radius, 0=tiny, 1023=full screen)
--   Register 3: Depth (maximum temporal delay)
--   Register 4: Smoothing (IIR on delay map)
--   Register 5: Luma Mod (0=position only, 1023=fully luma-driven)
--   Register 6: Flags [invert_zone, square_zone, soft_edge, freeze, bypass]
--   Register 7: Dry/wet mix
--
-- Timing:
--   Total pipeline latency: 9 clock cycles

--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.all;
use work.core_pkg.all;
use work.video_stream_pkg.all;
use work.video_timing_pkg.all;
use work.resolution_pkg.all;

architecture time_sculpt of program_top is
    constant C_PROCESSING_DELAY_CLKS : integer := 9;
    constant C_DELAY_DEPTH           : integer := 10;

    -- Controls
    signal s_zone_x        : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_zone_y        : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_zone_size     : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_depth         : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_smoothing     : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_luma_mod      : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_invert_zone   : std_logic;
    signal s_square_zone   : std_logic;
    signal s_soft_edge     : std_logic;
    signal s_freeze_map    : std_logic;
    signal s_bypass_enable : std_logic;
    signal s_dry_wet       : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);

    -- Resolution
    signal s_timing_id : t_video_timing_id;
    signal s_h_active  : unsigned(11 downto 0);
    signal s_v_active  : unsigned(11 downto 0);

    -- Counters
    signal s_h_count     : unsigned(11 downto 0) := (others => '0');
    signal s_v_count     : unsigned(11 downto 0) := (others => '0');
    signal s_prev_hsync  : std_logic := '1';
    signal s_prev_vsync  : std_logic := '1';

    -- Stage 1
    signal s_s1_y, s_s1_u, s_s1_v : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s1_avid : std_logic;

    -- Stage 2
    signal s_s2_delay    : unsigned(C_DELAY_DEPTH - 1 downto 0);
    signal s_s2_inside   : std_logic;
    signal s_s2_zone_frac : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s2_y, s_s2_u, s_s2_v : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s2_avid     : std_logic;
    signal s_smooth_delay : unsigned(C_DELAY_DEPTH - 1 downto 0) := (others => '0');

    -- Original video pipeline (3 clk delay to align with variable_delay output)
    type t_pipe3 is array (0 to 2) of unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_orig_y_pipe, s_orig_u_pipe, s_orig_v_pipe : t_pipe3 :=
        (others => (others => '0'));

    -- Zone mask pipeline (2 clk to align)
    type t_mask_pipe is array (0 to 1) of unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_mask_pipe : t_mask_pipe := (others => (others => '0'));
    signal s_inside_pipe : std_logic_vector(1 downto 0) := "00";

    -- Stage 3: delay outputs
    signal s_del_y, s_del_u, s_del_v : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_del_y_valid, s_del_u_valid, s_del_v_valid : std_logic;

    -- Stage 4
    signal s_s4_y, s_s4_u, s_s4_v : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s4_avid : std_logic;

    -- Dry/wet
    signal s_mix_y_result, s_mix_u_result, s_mix_v_result : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_mix_y_valid, s_mix_u_valid, s_mix_v_valid : std_logic;

    -- Bypass
    signal s_hsync_n_delayed, s_vsync_n_delayed, s_field_n_delayed : std_logic;
    signal s_y_delayed, s_u_delayed, s_v_delayed : std_logic_vector(C_VIDEO_DATA_WIDTH - 1 downto 0);

begin
    -- Resolution detection
    s_timing_id <= registers_in(8)(3 downto 0);
    s_h_active  <= get_h_active(s_timing_id);
    s_v_active  <= get_v_active(s_timing_id);

    -- Register mapping
    s_zone_x        <= unsigned(registers_in(0));
    s_zone_y        <= unsigned(registers_in(1));
    s_zone_size     <= unsigned(registers_in(2));
    s_depth         <= unsigned(registers_in(3));
    s_smoothing     <= unsigned(registers_in(4));
    s_luma_mod      <= unsigned(registers_in(5));
    s_invert_zone   <= registers_in(6)(0);
    s_square_zone   <= registers_in(6)(1);
    s_soft_edge     <= registers_in(6)(2);
    s_freeze_map    <= registers_in(6)(3);
    s_bypass_enable <= registers_in(6)(4);
    s_dry_wet       <= unsigned(registers_in(7));

    -- Pixel counters
    p_count : process(clk)
    begin
        if rising_edge(clk) then
            s_prev_hsync <= data_in.hsync_n;
            s_prev_vsync <= data_in.vsync_n;
            if data_in.avid = '1' then
                s_h_count <= s_h_count + 1;
            end if;
            if data_in.hsync_n = '0' and s_prev_hsync = '1' then
                s_h_count <= (others => '0');
                s_v_count <= s_v_count + 1;
            end if;
            if data_in.vsync_n = '0' and s_prev_vsync = '1' then
                s_v_count <= (others => '0');
            end if;
        end if;
    end process p_count;

    -- Stage 1: Input registration (1 clk)
    p_input : process(clk)
    begin
        if rising_edge(clk) then
            s_s1_y    <= unsigned(data_in.y);
            s_s1_u    <= unsigned(data_in.u);
            s_s1_v    <= unsigned(data_in.v);
            s_s1_avid <= data_in.avid;
        end if;
    end process p_input;

    ---------------------------------------------------------------------------
    -- Stage 2: Zone + delay calculation (1 clk)
    -- Map zone knobs to screen coords, compute distance, blend with luma,
    -- apply depth + smoothing. Avoid divisions — use shift approximations.
    ---------------------------------------------------------------------------
    p_delay_calc : process(clk)
        variable v_cx        : unsigned(11 downto 0);
        variable v_cy        : unsigned(11 downto 0);
        variable v_dx        : unsigned(11 downto 0);
        variable v_dy        : unsigned(11 downto 0);
        variable v_dist      : unsigned(11 downto 0);
        variable v_radius    : unsigned(11 downto 0);
        variable v_inside    : std_logic;
        variable v_zone_frac : unsigned(9 downto 0);
        variable v_pos_mapped : unsigned(21 downto 0);  -- 10*12=22
        variable v_rad_mapped : unsigned(21 downto 0);
        -- Delay source
        variable v_luma_term : unsigned(19 downto 0);  -- 10*10=20
        variable v_pos_term  : unsigned(19 downto 0);
        variable v_delay_src : unsigned(9 downto 0);
        variable v_product   : unsigned(19 downto 0);
        variable v_raw_delay : unsigned(C_DELAY_DEPTH - 1 downto 0);
        -- Smoothing
        variable v_old_term  : unsigned(19 downto 0);
        variable v_new_term  : unsigned(19 downto 0);
        variable v_blended   : unsigned(C_DELAY_DEPTH - 1 downto 0);
        -- Edge difference for soft zone
        variable v_edge_val  : unsigned(11 downto 0);
    begin
        if rising_edge(clk) then
            -- Map zone X/Y to screen coordinates: cx = zone_x * h_active >> 10
            v_pos_mapped := s_zone_x * s_h_active;  -- 10*12=22
            v_cx := v_pos_mapped(21 downto 10);

            v_pos_mapped := s_zone_y * s_v_active;
            v_cy := v_pos_mapped(21 downto 10);

            -- Radius: zone_size * max_dim >> 10
            if s_h_active > s_v_active then
                v_rad_mapped := s_zone_size * s_h_active;
            else
                v_rad_mapped := s_zone_size * s_v_active;
            end if;
            v_radius := v_rad_mapped(21 downto 10);

            -- Distance from center
            if s_h_count >= v_cx then
                v_dx := s_h_count - v_cx;
            else
                v_dx := v_cx - s_h_count;
            end if;

            if s_v_count >= v_cy then
                v_dy := s_v_count - v_cy;
            else
                v_dy := v_cy - s_v_count;
            end if;

            -- Distance metric
            if s_square_zone = '1' then
                if v_dx >= v_dy then v_dist := v_dx; else v_dist := v_dy; end if;
            else
                v_dist := resize(shift_right(v_dx + v_dy, 0), 12);
            end if;

            -- Zone membership
            if v_dist <= v_radius then
                v_inside := '1';
                -- Zone frac: (radius - dist) clamped to 10 bits, then squared
                -- for a smooth organic falloff that matches time_displace's feel.
                -- Linear ramp would create harsh triangle shapes; squaring gives
                -- a gentle curve that accelerates toward center.
                v_edge_val := v_radius - v_dist;
                if v_edge_val > to_unsigned(1023, 12) then
                    v_zone_frac := to_unsigned(1023, 10);
                else
                    -- Square the linear ramp for smooth curve: frac^2 >> 10
                    v_zone_frac := resize(shift_right(
                        v_edge_val(9 downto 0) * v_edge_val(9 downto 0), 10), 10);
                end if;
            else
                v_inside := '0';
                v_zone_frac := (others => '0');
            end if;

            -- Invert zone
            if s_invert_zone = '1' then
                v_inside := not v_inside;
                v_zone_frac := to_unsigned(1023, 10) - v_zone_frac;
            end if;

            -- Delay source: blend luma with zone_frac based on luma_mod
            -- delay_src = (luma * luma_mod + zone_frac * (1023 - luma_mod)) >> 10
            v_luma_term := s_s1_y * s_luma_mod;
            v_pos_term  := v_zone_frac * (to_unsigned(1023, 10) - s_luma_mod);
            v_delay_src := resize(shift_right(v_luma_term + v_pos_term, 10), 10);

            -- Depth scaling: delay = depth * delay_src >> 10
            v_product := s_depth * v_delay_src;
            v_raw_delay := resize(shift_right(v_product, 10), C_DELAY_DEPTH);

            -- Zero delay outside zone (hard edge)
            if v_inside = '0' and s_soft_edge = '0' then
                v_raw_delay := (others => '0');
            end if;

            -- Soft edge: scale delay by zone proximity
            if s_soft_edge = '1' and v_inside = '0' then
                v_raw_delay := (others => '0');
            end if;

            -- IIR smoothing
            if s_freeze_map = '1' then
                v_blended := s_smooth_delay;
            elsif s_smoothing > to_unsigned(0, 10) then
                v_old_term := s_smoothing * resize(s_smooth_delay, 10);
                v_new_term := (to_unsigned(1023, 10) - s_smoothing) *
                              resize(v_raw_delay, 10);
                v_blended := resize(shift_right(v_old_term + v_new_term, 10), C_DELAY_DEPTH);
            else
                v_blended := v_raw_delay;
            end if;

            s_smooth_delay <= v_blended;
            s_s2_delay     <= v_blended;
            s_s2_inside    <= v_inside;
            s_s2_zone_frac <= v_zone_frac;
            s_s2_y <= s_s1_y;
            s_s2_u <= s_s1_u;
            s_s2_v <= s_s1_v;
            s_s2_avid <= s_s1_avid;
        end if;
    end process p_delay_calc;

    -- Pipeline original video (3 clk: 1 for stage 2 + 2 for variable_delay_u)
    p_orig_pipe : process(clk)
    begin
        if rising_edge(clk) then
            s_orig_y_pipe <= s_s1_y & s_orig_y_pipe(0 to 1);
            s_orig_u_pipe <= s_s1_u & s_orig_u_pipe(0 to 1);
            s_orig_v_pipe <= s_s1_v & s_orig_v_pipe(0 to 1);
        end if;
    end process p_orig_pipe;

    -- Pipeline zone inside flag + frac (2 clk to align with delay output)
    p_mask_pipe : process(clk)
    begin
        if rising_edge(clk) then
            s_mask_pipe   <= s_s2_zone_frac & s_mask_pipe(0 to 0);
            s_inside_pipe <= s_s2_inside & s_inside_pipe(1 downto 1);
        end if;
    end process p_mask_pipe;

    -- Stage 3: Variable delay x3 (2 clk)
    delay_y : entity work.variable_delay_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_DEPTH => C_DELAY_DEPTH)
        port map(clk => clk, enable => s_s2_avid, delay => s_s2_delay,
                 a => s_s2_y, result => s_del_y, valid => s_del_y_valid);

    delay_u : entity work.variable_delay_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_DEPTH => C_DELAY_DEPTH)
        port map(clk => clk, enable => s_s2_avid, delay => s_s2_delay,
                 a => s_s2_u, result => s_del_u, valid => s_del_u_valid);

    delay_v : entity work.variable_delay_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_DEPTH => C_DELAY_DEPTH)
        port map(clk => clk, enable => s_s2_avid, delay => s_s2_delay,
                 a => s_s2_v, result => s_del_v, valid => s_del_v_valid);

    ---------------------------------------------------------------------------
    -- Stage 4: Zone masking + output (1 clk)
    -- Inside zone: show delayed video. Outside: show original.
    -- Soft edge: blend at boundary using zone_frac.
    ---------------------------------------------------------------------------
    p_zone_out : process(clk)
        variable v_in      : std_logic;
        variable v_frac    : unsigned(9 downto 0);
        variable v_blend_y : unsigned(19 downto 0);
        variable v_blend_u : unsigned(19 downto 0);
        variable v_blend_v : unsigned(19 downto 0);
    begin
        if rising_edge(clk) then
            v_in   := s_inside_pipe(0);
            v_frac := s_mask_pipe(1);

            if s_soft_edge = '1' then
                -- Soft blend: delayed * frac + original * (1023-frac) >> 10
                v_blend_y := s_del_y * v_frac +
                             s_orig_y_pipe(2) * (to_unsigned(1023, 10) - v_frac);
                v_blend_u := s_del_u * v_frac +
                             s_orig_u_pipe(2) * (to_unsigned(1023, 10) - v_frac);
                v_blend_v := s_del_v * v_frac +
                             s_orig_v_pipe(2) * (to_unsigned(1023, 10) - v_frac);
                s_s4_y <= v_blend_y(19 downto 10);
                s_s4_u <= v_blend_u(19 downto 10);
                s_s4_v <= v_blend_v(19 downto 10);
            else
                -- Hard edge: binary select
                if v_in = '1' then
                    s_s4_y <= s_del_y;
                    s_s4_u <= s_del_u;
                    s_s4_v <= s_del_v;
                else
                    s_s4_y <= s_orig_y_pipe(2);
                    s_s4_u <= s_orig_u_pipe(2);
                    s_s4_v <= s_orig_v_pipe(2);
                end if;
            end if;

            s_s4_avid <= s_del_y_valid and s_del_u_valid and s_del_v_valid;
        end if;
    end process p_zone_out;

    -- Stage 5: Dry/wet mix (4 clk)
    mix_y : entity work.interpolator_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_FRAC_BITS => C_VIDEO_DATA_WIDTH,
                    G_OUTPUT_MIN => 0, G_OUTPUT_MAX => 1023)
        port map(clk => clk, enable => s_s4_avid,
                 a => unsigned(s_y_delayed), b => s_s4_y, t => s_dry_wet,
                 result => s_mix_y_result, valid => s_mix_y_valid);

    mix_u : entity work.interpolator_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_FRAC_BITS => C_VIDEO_DATA_WIDTH,
                    G_OUTPUT_MIN => 0, G_OUTPUT_MAX => 1023)
        port map(clk => clk, enable => s_s4_avid,
                 a => unsigned(s_u_delayed), b => s_s4_u, t => s_dry_wet,
                 result => s_mix_u_result, valid => s_mix_u_valid);

    mix_v : entity work.interpolator_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_FRAC_BITS => C_VIDEO_DATA_WIDTH,
                    G_OUTPUT_MIN => 0, G_OUTPUT_MAX => 1023)
        port map(clk => clk, enable => s_s4_avid,
                 a => unsigned(s_v_delayed), b => s_s4_v, t => s_dry_wet,
                 result => s_mix_v_result, valid => s_mix_v_valid);

    -- Bypass + sync delay
    p_bypass : process(clk)
        type t_sync_delay is array (0 to C_PROCESSING_DELAY_CLKS - 1) of std_logic;
        type t_data_delay is array (0 to C_PROCESSING_DELAY_CLKS - 1) of
            std_logic_vector(C_VIDEO_DATA_WIDTH - 1 downto 0);
        variable v_hs : t_sync_delay := (others => '1');
        variable v_vs : t_sync_delay := (others => '1');
        variable v_fd : t_sync_delay := (others => '1');
        variable v_yd : t_data_delay := (others => (others => '0'));
        variable v_ud : t_data_delay := (others => (others => '0'));
        variable v_vd : t_data_delay := (others => (others => '0'));
    begin
        if rising_edge(clk) then
            v_hs := data_in.hsync_n & v_hs(0 to C_PROCESSING_DELAY_CLKS - 2);
            v_vs := data_in.vsync_n & v_vs(0 to C_PROCESSING_DELAY_CLKS - 2);
            v_fd := data_in.field_n & v_fd(0 to C_PROCESSING_DELAY_CLKS - 2);
            v_yd := data_in.y       & v_yd(0 to C_PROCESSING_DELAY_CLKS - 2);
            v_ud := data_in.u       & v_ud(0 to C_PROCESSING_DELAY_CLKS - 2);
            v_vd := data_in.v       & v_vd(0 to C_PROCESSING_DELAY_CLKS - 2);
            s_hsync_n_delayed <= v_hs(C_PROCESSING_DELAY_CLKS - 1);
            s_vsync_n_delayed <= v_vs(C_PROCESSING_DELAY_CLKS - 1);
            s_field_n_delayed <= v_fd(C_PROCESSING_DELAY_CLKS - 1);
            s_y_delayed <= v_yd(C_PROCESSING_DELAY_CLKS - 1);
            s_u_delayed <= v_ud(C_PROCESSING_DELAY_CLKS - 1);
            s_v_delayed <= v_vd(C_PROCESSING_DELAY_CLKS - 1);
        end if;
    end process p_bypass;

    -- Output
    data_out.y <= std_logic_vector(s_mix_y_result) when s_bypass_enable = '0'
                  else s_y_delayed;
    data_out.u <= std_logic_vector(s_mix_u_result) when s_bypass_enable = '0'
                  else s_u_delayed;
    data_out.v <= std_logic_vector(s_mix_v_result) when s_bypass_enable = '0'
                  else s_v_delayed;
    data_out.avid    <= s_mix_y_valid and s_mix_u_valid and s_mix_v_valid;
    data_out.hsync_n <= s_hsync_n_delayed;
    data_out.vsync_n <= s_vsync_n_delayed;
    data_out.field_n <= s_field_n_delayed;

end time_sculpt;
