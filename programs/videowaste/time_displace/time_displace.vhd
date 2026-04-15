-- Copyright (C) 2026 VIDEOWASTE
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of Videomancer Community Programs.
-- See LICENSE file in the repository root for full license text.
--
-- Program Name:
--   Time Displace
--
-- Author:
--   VIDEOWASTE
--
-- Overview:
--   Luma-controlled temporal delay. The temporal delay for each pixel
--   is derived from its luminance value, so bright areas show "now"
--   while dark areas show older video (or vice versa). Creates surreal
--   effects where motion leaves ghostly trails in shadows while
--   highlights stay sharp and current.
--
-- Architecture:
--   Stage 1: Input registration (1 clk)
--   Stage 2: Delay calculation from luma (1 clk)
--   Stage 3: Variable delay x3 (2 clk)
--   Stage 4: Edge enhancement + color effects (1 clk)
--   Stage 5: Output composition (1 clk)
--   Stage 6: Dry/wet mix via interpolator_u x3 (4 clk)
--
-- Register Map:
--   Register 0: Depth (maximum time displacement range)
--   Register 1: Threshold (luma cutoff for displacement)
--   Register 2: Smoothing (spatial smoothing of displacement map)
--   Register 3: Edge Boost (enhance edges at time boundaries)
--   Register 4: Color Shift (bits 9..8 = hue quadrant, bits 7..0 = intensity)
--   Register 5: Contrast (boost contrast of displaced output, 512=unity)
--   Register 6: Flags [negative, mono, solarize, edge_only, bypass]
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

architecture time_displace of program_top is
    constant C_PROCESSING_DELAY_CLKS : integer := 10;
    constant C_DELAY_DEPTH           : integer := 10;  -- 1024 pixel delay

    -- Control signals
    signal s_depth          : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_threshold      : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_smoothing      : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_edge_boost     : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_color_shift    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_contrast       : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_negative       : std_logic;
    signal s_mono           : std_logic;
    signal s_solarize       : std_logic;
    signal s_edge_only      : std_logic;
    signal s_bypass_enable  : std_logic;
    signal s_dry_wet        : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);

    -- Stage 1: Input registration
    signal s_s1_y    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s1_u    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s1_v    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s1_avid : std_logic;

    -- Stage 2: Delay calculation
    signal s_s2_delay  : unsigned(C_DELAY_DEPTH - 1 downto 0);
    signal s_s2_y      : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s2_u      : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s2_v      : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s2_avid   : std_logic;

    -- Smoothed delay (IIR state)
    signal s_smooth_delay : unsigned(C_DELAY_DEPTH - 1 downto 0) := (others => '0');

    -- Previous pixel delay for edge detection
    signal s_prev_delay : unsigned(C_DELAY_DEPTH - 1 downto 0) := (others => '0');

    -- Stage 3: Variable delay outputs
    signal s_delayed_y       : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_delayed_u       : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_delayed_v       : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_delayed_y_valid : std_logic;
    signal s_delayed_u_valid : std_logic;
    signal s_delayed_v_valid : std_logic;

    -- Pipeline delay for S2 signals to match variable_delay_u latency (2 clk)
    type t_data_pipe2 is array (0 to 1) of unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    type t_delay_pipe2 is array (0 to 1) of unsigned(C_DELAY_DEPTH - 1 downto 0);
    signal s_s2_delay_pipe : t_delay_pipe2 := (others => (others => '0'));

    -- Previous delay value pipelined to match Stage 4 timing
    signal s_prev_delay_pipe : t_delay_pipe2 := (others => (others => '0'));

    -- Stage 4: Edge enhancement + color effects
    signal s_s4_y    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s4_u    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s4_v    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s4_avid : std_logic;

    -- Stage 5: Output composition
    signal s_s5_y    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s5_u    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s5_v    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s5_avid : std_logic;

    -- Dry/wet mix outputs
    signal s_mix_y_result : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_mix_u_result : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_mix_v_result : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_mix_y_valid  : std_logic;
    signal s_mix_u_valid  : std_logic;
    signal s_mix_v_valid  : std_logic;

    -- Bypass delay line
    signal s_avid_delayed    : std_logic;
    signal s_hsync_n_delayed : std_logic;
    signal s_vsync_n_delayed : std_logic;
    signal s_field_n_delayed : std_logic;
    signal s_y_delayed       : std_logic_vector(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_u_delayed       : std_logic_vector(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_v_delayed       : std_logic_vector(C_VIDEO_DATA_WIDTH - 1 downto 0);

begin
    -- Register mapping (concurrent — same as original)
    s_depth         <= unsigned(registers_in(0));
    s_threshold     <= unsigned(registers_in(1));
    s_smoothing     <= unsigned(registers_in(2));
    s_edge_boost    <= unsigned(registers_in(3));
    s_color_shift   <= unsigned(registers_in(4));
    s_contrast      <= unsigned(registers_in(5));
    s_negative      <= registers_in(6)(0);
    s_mono          <= registers_in(6)(1);
    s_solarize      <= registers_in(6)(2);
    s_edge_only     <= registers_in(6)(3);
    s_bypass_enable <= registers_in(6)(4);
    s_dry_wet       <= unsigned(registers_in(7));

    ---------------------------------------------------------------------------
    -- Stage 1: Input registration (1 clk)
    ---------------------------------------------------------------------------
    p_input_stage : process(clk)
    begin
        if rising_edge(clk) then
            s_s1_y    <= unsigned(data_in.y);
            s_s1_u    <= unsigned(data_in.u);
            s_s1_v    <= unsigned(data_in.v);
            s_s1_avid <= data_in.avid;
        end if;
    end process p_input_stage;

    ---------------------------------------------------------------------------
    -- Stage 2: Delay calculation from luma (1 clk)
    ---------------------------------------------------------------------------
    p_delay_calc : process(clk)
        variable v_source     : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
        variable v_above      : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
        variable v_product    : unsigned(2 * C_VIDEO_DATA_WIDTH - 1 downto 0);  -- 20 bits
        variable v_raw_delay  : unsigned(C_DELAY_DEPTH - 1 downto 0);
        variable v_depth_eff  : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
        variable v_smooth_eff : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
        variable v_inv_smooth : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
        variable v_old_term   : unsigned(2 * C_VIDEO_DATA_WIDTH - 1 downto 0);
        variable v_new_term   : unsigned(2 * C_VIDEO_DATA_WIDTH - 1 downto 0);
        variable v_blended    : unsigned(C_DELAY_DEPTH - 1 downto 0);
    begin
        if rising_edge(clk) then
            -- Displacement source is luma (Y)
            v_source := s_s1_y;

            -- Apply threshold: if source > threshold, compute (source - threshold)
            if v_source > s_threshold then
                v_above := v_source - s_threshold;
            else
                v_above := (others => '0');
            end if;

            -- Taper depth: scale to 75% so max knob stays usable
            -- 0-1023 input → 0-767 effective
            v_depth_eff := s_depth - shift_right(s_depth, 2);

            -- Compute delay = depth_eff * v_above / 1023
            v_product := v_depth_eff * v_above;
            v_raw_delay := resize(shift_right(v_product, 10), C_DELAY_DEPTH);

            -- Taper smoothing: scale to 87.5% so IIR always lets new data in
            -- 0-1023 input → 0-895 effective (at max, inv_smooth = 128)
            v_smooth_eff := s_smoothing - shift_right(s_smoothing, 3);

            -- Apply spatial smoothing (IIR filter on delay value)
            -- blended = (smooth_eff * old + (1023 - smooth_eff) * new) / 1023
            if v_smooth_eff > to_unsigned(0, C_VIDEO_DATA_WIDTH) then
                v_old_term := v_smooth_eff * resize(s_smooth_delay, C_VIDEO_DATA_WIDTH);
                v_inv_smooth := to_unsigned(1023, C_VIDEO_DATA_WIDTH) - v_smooth_eff;
                v_new_term := v_inv_smooth * resize(v_raw_delay, C_VIDEO_DATA_WIDTH);
                v_blended := resize(shift_right(v_old_term + v_new_term, 10), C_DELAY_DEPTH);
            else
                v_blended := v_raw_delay;
            end if;

            s_smooth_delay <= v_blended;
            s_prev_delay   <= s_s2_delay;
            s_s2_delay     <= v_blended;
            s_s2_y         <= s_s1_y;
            s_s2_u         <= s_s1_u;
            s_s2_v         <= s_s1_v;
            s_s2_avid      <= s_s1_avid;
        end if;
    end process p_delay_calc;

    ---------------------------------------------------------------------------
    -- Pipeline delay for S2 delay value through variable_delay_u latency (2 clk)
    ---------------------------------------------------------------------------
    p_delay_pipe : process(clk)
    begin
        if rising_edge(clk) then
            s_s2_delay_pipe <= s_s2_delay & s_s2_delay_pipe(0 to 0);
            s_prev_delay_pipe <= s_prev_delay & s_prev_delay_pipe(0 to 0);
        end if;
    end process p_delay_pipe;

    ---------------------------------------------------------------------------
    -- Stage 3: Variable delay x3 (2 clk latency each)
    ---------------------------------------------------------------------------
    delay_y : entity work.variable_delay_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_DEPTH => C_DELAY_DEPTH)
        port map(
            clk    => clk,
            enable => s_s2_avid,
            delay  => s_s2_delay,
            a      => s_s2_y,
            result => s_delayed_y,
            valid  => s_delayed_y_valid
        );

    delay_u : entity work.variable_delay_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_DEPTH => C_DELAY_DEPTH)
        port map(
            clk    => clk,
            enable => s_s2_avid,
            delay  => s_s2_delay,
            a      => s_s2_u,
            result => s_delayed_u,
            valid  => s_delayed_u_valid
        );

    delay_v : entity work.variable_delay_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_DEPTH => C_DELAY_DEPTH)
        port map(
            clk    => clk,
            enable => s_s2_avid,
            delay  => s_s2_delay,
            a      => s_s2_v,
            result => s_delayed_v,
            valid  => s_delayed_v_valid
        );

    ---------------------------------------------------------------------------
    -- Stage 4: Edge enhancement + color effects (1 clk)
    ---------------------------------------------------------------------------
    p_edge_color : process(clk)
        variable v_delay_now  : unsigned(C_DELAY_DEPTH - 1 downto 0);
        variable v_delay_prev : unsigned(C_DELAY_DEPTH - 1 downto 0);
        variable v_edge_diff  : unsigned(C_DELAY_DEPTH - 1 downto 0);
        variable v_edge_val   : unsigned(2 * C_VIDEO_DATA_WIDTH - 1 downto 0);  -- 20-bit
        variable v_edge_add   : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
        variable v_y_out      : unsigned(C_VIDEO_DATA_WIDTH downto 0);  -- 11-bit for overflow
        variable v_u_shifted  : signed(C_VIDEO_DATA_WIDTH downto 0);   -- 11-bit signed
        variable v_v_shifted  : signed(C_VIDEO_DATA_WIDTH downto 0);
        variable v_color_amt  : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
        variable v_color_prod : unsigned(2 * C_VIDEO_DATA_WIDTH - 1 downto 0);  -- 20-bit
        variable v_phase      : unsigned(1 downto 0);
        variable v_intensity  : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    begin
        if rising_edge(clk) then
            -- Get the delay value that was used (pipelined to match Stage 3 latency)
            v_delay_now  := s_s2_delay_pipe(1);
            v_delay_prev := s_prev_delay_pipe(1);

            -- Edge detection: |current_delay - previous_pixel_delay|
            if v_delay_now >= v_delay_prev then
                v_edge_diff := v_delay_now - v_delay_prev;
            else
                v_edge_diff := v_delay_prev - v_delay_now;
            end if;

            -- Scale edge by edge_boost: edge_diff * edge_boost, amplified 32x
            -- (adjacent pixel delay diffs are small, needs strong gain)
            v_edge_val := resize(v_edge_diff, C_VIDEO_DATA_WIDTH) * s_edge_boost;
            if shift_right(v_edge_val, 5) > to_unsigned(1023, 2 * C_VIDEO_DATA_WIDTH) then
                v_edge_add := to_unsigned(1023, C_VIDEO_DATA_WIDTH);
            else
                v_edge_add := resize(shift_right(v_edge_val, 5), C_VIDEO_DATA_WIDTH);
            end if;

            -- Y channel: add edge enhancement
            v_y_out := resize(s_delayed_y, C_VIDEO_DATA_WIDTH + 1) +
                       resize(v_edge_add, C_VIDEO_DATA_WIDTH + 1);
            if v_y_out > to_unsigned(1023, C_VIDEO_DATA_WIDTH + 1) then
                s_s4_y <= to_unsigned(1023, C_VIDEO_DATA_WIDTH);
            else
                s_s4_y <= v_y_out(C_VIDEO_DATA_WIDTH - 1 downto 0);
            end if;

            -- Color shift: full-spectrum hue control
            -- Bits 9..8 = phase quadrant, bits 7..0 = intensity scaled to 10-bit
            v_phase := s_color_shift(9 downto 8);
            v_intensity := shift_left(resize(s_color_shift(7 downto 0), C_VIDEO_DATA_WIDTH), 2);

            -- color_amt = intensity * delay / 1023
            v_color_prod := v_intensity * resize(v_delay_now, C_VIDEO_DATA_WIDTH);
            v_color_amt := resize(shift_right(v_color_prod, 10), C_VIDEO_DATA_WIDTH);

            -- Apply UV offset direction based on phase quadrant
            -- Q0 "00": +U, -V = Blue    Q1 "01": +U, +V = Magenta
            -- Q2 "10": -U, +V = Red     Q3 "11": -U, -V = Green/Cyan
            case v_phase is
                when "00" =>
                    v_u_shifted := resize(signed('0' & std_logic_vector(s_delayed_u)), C_VIDEO_DATA_WIDTH + 1) +
                                   resize(signed('0' & std_logic_vector(v_color_amt)), C_VIDEO_DATA_WIDTH + 1);
                    v_v_shifted := resize(signed('0' & std_logic_vector(s_delayed_v)), C_VIDEO_DATA_WIDTH + 1) -
                                   resize(signed('0' & std_logic_vector(v_color_amt)), C_VIDEO_DATA_WIDTH + 1);
                when "01" =>
                    v_u_shifted := resize(signed('0' & std_logic_vector(s_delayed_u)), C_VIDEO_DATA_WIDTH + 1) +
                                   resize(signed('0' & std_logic_vector(v_color_amt)), C_VIDEO_DATA_WIDTH + 1);
                    v_v_shifted := resize(signed('0' & std_logic_vector(s_delayed_v)), C_VIDEO_DATA_WIDTH + 1) +
                                   resize(signed('0' & std_logic_vector(v_color_amt)), C_VIDEO_DATA_WIDTH + 1);
                when "10" =>
                    v_u_shifted := resize(signed('0' & std_logic_vector(s_delayed_u)), C_VIDEO_DATA_WIDTH + 1) -
                                   resize(signed('0' & std_logic_vector(v_color_amt)), C_VIDEO_DATA_WIDTH + 1);
                    v_v_shifted := resize(signed('0' & std_logic_vector(s_delayed_v)), C_VIDEO_DATA_WIDTH + 1) +
                                   resize(signed('0' & std_logic_vector(v_color_amt)), C_VIDEO_DATA_WIDTH + 1);
                when others =>
                    v_u_shifted := resize(signed('0' & std_logic_vector(s_delayed_u)), C_VIDEO_DATA_WIDTH + 1) -
                                   resize(signed('0' & std_logic_vector(v_color_amt)), C_VIDEO_DATA_WIDTH + 1);
                    v_v_shifted := resize(signed('0' & std_logic_vector(s_delayed_v)), C_VIDEO_DATA_WIDTH + 1) -
                                   resize(signed('0' & std_logic_vector(v_color_amt)), C_VIDEO_DATA_WIDTH + 1);
            end case;

            -- Clamp U
            if v_u_shifted > to_signed(1023, C_VIDEO_DATA_WIDTH + 1) then
                s_s4_u <= to_unsigned(1023, C_VIDEO_DATA_WIDTH);
            elsif v_u_shifted < to_signed(0, C_VIDEO_DATA_WIDTH + 1) then
                s_s4_u <= to_unsigned(0, C_VIDEO_DATA_WIDTH);
            else
                s_s4_u <= unsigned(v_u_shifted(C_VIDEO_DATA_WIDTH - 1 downto 0));
            end if;

            -- Clamp V
            if v_v_shifted > to_signed(1023, C_VIDEO_DATA_WIDTH + 1) then
                s_s4_v <= to_unsigned(1023, C_VIDEO_DATA_WIDTH);
            elsif v_v_shifted < to_signed(0, C_VIDEO_DATA_WIDTH + 1) then
                s_s4_v <= to_unsigned(0, C_VIDEO_DATA_WIDTH);
            else
                s_s4_v <= unsigned(v_v_shifted(C_VIDEO_DATA_WIDTH - 1 downto 0));
            end if;

            -- Edge-only mode: show only edge boundaries on black
            if s_edge_only = '1' then
                s_s4_y <= v_edge_add;
                s_s4_u <= to_unsigned(512, C_VIDEO_DATA_WIDTH);
                s_s4_v <= to_unsigned(512, C_VIDEO_DATA_WIDTH);
            end if;

            s_s4_avid <= s_delayed_y_valid and s_delayed_u_valid and s_delayed_v_valid;
        end if;
    end process p_edge_color;

    ---------------------------------------------------------------------------
    -- Stage 5: Output composition / contrast (1 clk)
    ---------------------------------------------------------------------------
    p_output_comp : process(clk)
        variable v_centered : signed(C_VIDEO_DATA_WIDTH downto 0);  -- 11-bit signed
        variable v_scaled   : signed(2 * C_VIDEO_DATA_WIDTH + 1 downto 0);  -- 22-bit (11 * 10)
        variable v_result   : signed(C_VIDEO_DATA_WIDTH downto 0);
        variable v_y_clamped : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    begin
        if rising_edge(clk) then
            -- Apply contrast around midpoint (512) for Y channel
            v_centered := resize(signed('0' & std_logic_vector(s_s4_y)), C_VIDEO_DATA_WIDTH + 1) -
                          to_signed(512, C_VIDEO_DATA_WIDTH + 1);
            v_scaled := v_centered * signed('0' & std_logic_vector(s_contrast));
            v_result := resize(shift_right(v_scaled, 9), C_VIDEO_DATA_WIDTH + 1) +
                        to_signed(512, C_VIDEO_DATA_WIDTH + 1);

            -- Clamp to 0-1023
            if v_result > to_signed(1023, C_VIDEO_DATA_WIDTH + 1) then
                v_y_clamped := to_unsigned(1023, C_VIDEO_DATA_WIDTH);
            elsif v_result < to_signed(0, C_VIDEO_DATA_WIDTH + 1) then
                v_y_clamped := to_unsigned(0, C_VIDEO_DATA_WIDTH);
            else
                v_y_clamped := unsigned(v_result(C_VIDEO_DATA_WIDTH - 1 downto 0));
            end if;

            -- Solarize: triangle fold — below mid doubles up, above mid folds and doubles
            -- Output spans full 0-1023 range (no dimming)
            if s_solarize = '1' then
                if v_y_clamped >= to_unsigned(512, C_VIDEO_DATA_WIDTH) then
                    -- Above midpoint: fold down and double (max 511 * 2 = 1022)
                    v_y_clamped := resize(shift_left(resize(
                        to_unsigned(1023, C_VIDEO_DATA_WIDTH) - v_y_clamped,
                        C_VIDEO_DATA_WIDTH + 1), 1), C_VIDEO_DATA_WIDTH);
                else
                    -- Below midpoint: double (max 511 * 2 = 1022)
                    v_y_clamped := resize(shift_left(resize(
                        v_y_clamped,
                        C_VIDEO_DATA_WIDTH + 1), 1), C_VIDEO_DATA_WIDTH);
                end if;
            end if;

            -- Negative: invert luma
            if s_negative = '1' then
                v_y_clamped := to_unsigned(1023, C_VIDEO_DATA_WIDTH) - v_y_clamped;
            end if;

            s_s5_y <= v_y_clamped;

            -- Mono: strip chroma from displaced output
            if s_mono = '1' then
                s_s5_u <= to_unsigned(512, C_VIDEO_DATA_WIDTH);
                s_s5_v <= to_unsigned(512, C_VIDEO_DATA_WIDTH);
            else
                s_s5_u <= s_s4_u;
                s_s5_v <= s_s4_v;
            end if;

            s_s5_avid <= s_s4_avid;
        end if;
    end process p_output_comp;

    ---------------------------------------------------------------------------
    -- Stage 6: Dry/wet mix via interpolator_u x3 (4 clk)
    ---------------------------------------------------------------------------
    mix_y : entity work.interpolator_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_FRAC_BITS => C_VIDEO_DATA_WIDTH,
                    G_OUTPUT_MIN => 0, G_OUTPUT_MAX => 1023)
        port map(clk => clk, enable => s_s5_avid,
                 a => unsigned(s_y_delayed), b => s_s5_y,
                 t => s_dry_wet, result => s_mix_y_result, valid => s_mix_y_valid);

    mix_u : entity work.interpolator_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_FRAC_BITS => C_VIDEO_DATA_WIDTH,
                    G_OUTPUT_MIN => 0, G_OUTPUT_MAX => 1023)
        port map(clk => clk, enable => s_s5_avid,
                 a => unsigned(s_u_delayed), b => s_s5_u,
                 t => s_dry_wet, result => s_mix_u_result, valid => s_mix_u_valid);

    mix_v : entity work.interpolator_u
        generic map(G_WIDTH => C_VIDEO_DATA_WIDTH, G_FRAC_BITS => C_VIDEO_DATA_WIDTH,
                    G_OUTPUT_MIN => 0, G_OUTPUT_MAX => 1023)
        port map(clk => clk, enable => s_s5_avid,
                 a => unsigned(s_v_delayed), b => s_s5_v,
                 t => s_dry_wet, result => s_mix_v_result, valid => s_mix_v_valid);

    ---------------------------------------------------------------------------
    -- Bypass delay line (must match C_PROCESSING_DELAY_CLKS exactly)
    ---------------------------------------------------------------------------
    p_bypass_delay : process(clk)
        type t_sync_delay is array (0 to C_PROCESSING_DELAY_CLKS - 1) of std_logic;
        type t_data_delay is array (0 to C_PROCESSING_DELAY_CLKS - 1) of std_logic_vector(C_VIDEO_DATA_WIDTH - 1 downto 0);
        variable v_avid_delay  : t_sync_delay := (others => '0');
        variable v_hsync_delay : t_sync_delay := (others => '1');
        variable v_vsync_delay : t_sync_delay := (others => '1');
        variable v_field_delay : t_sync_delay := (others => '1');
        variable v_y_delay     : t_data_delay := (others => (others => '0'));
        variable v_u_delay     : t_data_delay := (others => (others => '0'));
        variable v_v_delay     : t_data_delay := (others => (others => '0'));
    begin
        if rising_edge(clk) then
            v_avid_delay  := data_in.avid    & v_avid_delay(0 to C_PROCESSING_DELAY_CLKS - 2);
            v_hsync_delay := data_in.hsync_n & v_hsync_delay(0 to C_PROCESSING_DELAY_CLKS - 2);
            v_vsync_delay := data_in.vsync_n & v_vsync_delay(0 to C_PROCESSING_DELAY_CLKS - 2);
            v_field_delay := data_in.field_n & v_field_delay(0 to C_PROCESSING_DELAY_CLKS - 2);
            v_y_delay     := data_in.y       & v_y_delay(0 to C_PROCESSING_DELAY_CLKS - 2);
            v_u_delay     := data_in.u       & v_u_delay(0 to C_PROCESSING_DELAY_CLKS - 2);
            v_v_delay     := data_in.v       & v_v_delay(0 to C_PROCESSING_DELAY_CLKS - 2);

            s_avid_delayed    <= v_avid_delay(C_PROCESSING_DELAY_CLKS - 1);
            s_hsync_n_delayed <= v_hsync_delay(C_PROCESSING_DELAY_CLKS - 1);
            s_vsync_n_delayed <= v_vsync_delay(C_PROCESSING_DELAY_CLKS - 1);
            s_field_n_delayed <= v_field_delay(C_PROCESSING_DELAY_CLKS - 1);
            s_y_delayed       <= v_y_delay(C_PROCESSING_DELAY_CLKS - 1);
            s_u_delayed       <= v_u_delay(C_PROCESSING_DELAY_CLKS - 1);
            s_v_delayed       <= v_v_delay(C_PROCESSING_DELAY_CLKS - 1);
        end if;
    end process p_bypass_delay;

    ---------------------------------------------------------------------------
    -- Output
    ---------------------------------------------------------------------------
    data_out.y <= std_logic_vector(s_mix_y_result) when s_bypass_enable = '0' else s_y_delayed;
    data_out.u <= std_logic_vector(s_mix_u_result) when s_bypass_enable = '0' else s_u_delayed;
    data_out.v <= std_logic_vector(s_mix_v_result) when s_bypass_enable = '0' else s_v_delayed;
    data_out.avid    <= s_avid_delayed;
    data_out.hsync_n <= s_hsync_n_delayed;
    data_out.vsync_n <= s_vsync_n_delayed;
    data_out.field_n <= s_field_n_delayed;

end time_displace;
