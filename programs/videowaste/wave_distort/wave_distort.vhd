-- Copyright (C) 2026 VIDEOWASTE
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of Videomancer Community Programs.
-- See LICENSE file in the repository root for full license text.
--
-- Program Name:
--   Wave Distort
--
-- Author:
--   VIDEOWASTE
--
-- Overview:
--   Sine-wave spatial displacement of video. Each scanline's pixels are
--   shifted horizontally by a sine-wave function of the vertical position,
--   creating ripple, wave, and water-like distortion effects. Uses shift
--   registers for horizontal pixel delay with variable tap readout.
--
-- Architecture:
--   Stage 1: Input registration + counters (1 clk)
--   Stage 2: Phase calculation (1 clk)
--   Stage 3: Waveform generation (1 clk)
--   Stage 4: Displacement + shift register read (1 clk)
--   Stage 5: Compose output (1 clk)
--   Stage 6-9: Dry/wet mix (4 clk)
--
-- Register Map:
--   Register 0: Wave frequency (0-1023)
--   Register 1: Wave amplitude (0-1023, max ~32 pixel displacement)
--   Register 2: Wave speed (0-1023, animation speed)
--   Register 3: Phase offset (0-1023, manual phase control)
--   Register 4: Waveform (0-255=sine, 256-511=triangle, 512-767=square, 768-1023=sawtooth)
--   Register 5: Direction blend (0=H only, 512=both, 1023=V only)
--   Register 6: Flags [animate, luma_mod, mirror, unused, bypass]
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

architecture wave_distort of program_top is
    constant C_PROCESSING_DELAY_CLKS : integer := 9;
    constant C_SHIFT_DEPTH           : integer := 32;

    -- Control signals
    signal s_frequency     : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_amplitude     : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_speed         : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_phase_offset  : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_waveform      : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_direction     : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_animate       : std_logic;
    signal s_luma_mod      : std_logic;
    signal s_mirror        : std_logic;
    signal s_bypass_enable : std_logic;
    signal s_dry_wet       : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);

    -- Position counters
    signal s_h_count     : unsigned(11 downto 0) := (others => '0');
    signal s_v_count     : unsigned(10 downto 0) := (others => '0');
    signal s_prev_hsync  : std_logic := '1';
    signal s_prev_vsync  : std_logic := '1';
    signal s_frame_count : unsigned(15 downto 0) := (others => '0');

    -- Shift registers for horizontal displacement
    type t_shift_reg is array (0 to C_SHIFT_DEPTH - 1) of unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_y_shift : t_shift_reg := (others => (others => '0'));
    signal s_u_shift : t_shift_reg := (others => (others => '0'));
    signal s_v_shift : t_shift_reg := (others => (others => '0'));

    -- Stage 1
    signal s_s1_y    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s1_u    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s1_v    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s1_avid : std_logic;

    -- Stage 2: phase
    signal s_phase_h : unsigned(9 downto 0);  -- horizontal-displacement phase (from v_count)
    signal s_phase_v : unsigned(9 downto 0);  -- vertical-displacement phase (from h_count)
    signal s_s2_y    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s2_avid : std_logic;

    -- Sine LUT signals (combinational)
    signal s_sin_angle_h : std_logic_vector(9 downto 0);
    signal s_sin_out_h   : signed(9 downto 0);
    signal s_sin_out_v   : signed(9 downto 0);

    -- Stage 3: wave value (signed displacement)
    signal s_wave_val : signed(10 downto 0);
    signal s_s3_y     : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s3_avid  : std_logic;

    -- Stage 4: shifted output
    signal s_s4_y    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s4_u    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s4_v    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s4_avid : std_logic;

    -- Stage 5: compose
    signal s_s5_y    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s5_u    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s5_v    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s5_avid : std_logic;

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

    -- Helper: clamp tap index
    function clamp_idx(val : integer; max_val : integer) return integer is
    begin
        if val < 0 then return 0;
        elsif val > max_val then return max_val;
        else return val;
        end if;
    end function;

begin
    -- Register mapping
    s_frequency     <= unsigned(registers_in(0));
    s_amplitude     <= unsigned(registers_in(1));
    s_speed         <= unsigned(registers_in(2));
    s_phase_offset  <= unsigned(registers_in(3));
    s_waveform      <= unsigned(registers_in(4));
    s_direction     <= unsigned(registers_in(5));
    s_animate       <= registers_in(6)(0);
    s_luma_mod      <= registers_in(6)(1);
    s_mirror        <= registers_in(6)(2);
    s_bypass_enable <= registers_in(6)(4);
    s_dry_wet       <= unsigned(registers_in(7));

    -- Sine LUT for horizontal-displacement phase
    s_sin_angle_h <= std_logic_vector(s_phase_h);
    sin_lut_h : entity work.sin_cos_full_lut_10x10
        port map(
            angle_in => s_sin_angle_h,
            sin_out  => s_sin_out_h,
            cos_out  => open
        );

    -- Vertical phase uses triangle approximation to save FPGA resources
    -- (second sin_cos LUT exceeds iCE40 HX4K logic budget)
    process(s_phase_v)
        variable v_pv : unsigned(9 downto 0);
    begin
        v_pv := unsigned(s_phase_v);
        if v_pv < to_unsigned(512, 10) then
            s_sin_out_v <= resize(signed('0' & std_logic_vector(v_pv)), 10) - to_signed(256, 10);
        else
            s_sin_out_v <= to_signed(256, 10) - resize(signed('0' & std_logic_vector(v_pv - to_unsigned(512, 10))), 10);
        end if;
    end process;

    -- Position counters
    p_counters : process(clk)
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
                s_frame_count <= s_frame_count + 1;
            end if;
        end if;
    end process p_counters;

    -- Stage 1: Input registration + shift register push
    p_input_stage : process(clk)
    begin
        if rising_edge(clk) then
            s_s1_y    <= unsigned(data_in.y);
            s_s1_u    <= unsigned(data_in.u);
            s_s1_v    <= unsigned(data_in.v);
            s_s1_avid <= data_in.avid;

            if data_in.avid = '1' then
                s_y_shift <= unsigned(data_in.y) & s_y_shift(0 to C_SHIFT_DEPTH - 2);
                s_u_shift <= unsigned(data_in.u) & s_u_shift(0 to C_SHIFT_DEPTH - 2);
                s_v_shift <= unsigned(data_in.v) & s_v_shift(0 to C_SHIFT_DEPTH - 2);
            end if;
        end if;
    end process p_input_stage;

    -- Stage 2: Phase calculation
    -- Compute two phases: one driven by v_count (for horizontal displacement)
    -- and one driven by h_count (for vertical displacement)
    p_phase_calc : process(clk)
        variable v_phase_h   : unsigned(21 downto 0);
        variable v_phase_v   : unsigned(21 downto 0);
        variable v_anim      : unsigned(15 downto 0);
    begin
        if rising_edge(clk) then
            if s_animate = '1' then
                v_anim := resize(s_frame_count * resize(s_speed, 16), 16);
            else
                v_anim := (others => '0');
            end if;

            -- Horizontal displacement phase (wave along scanlines, driven by v_count)
            v_phase_h := resize(s_v_count * resize(s_frequency, 11), 22);
            v_phase_h := v_phase_h + resize(s_phase_offset, 22) + resize(v_anim, 22);
            s_phase_h <= v_phase_h(9 downto 0);

            -- Vertical displacement phase (wave along columns, driven by h_count)
            v_phase_v := resize(s_h_count * resize(s_frequency, 12), 22);
            v_phase_v := v_phase_v + resize(s_phase_offset, 22) + resize(v_anim, 22);
            s_phase_v <= v_phase_v(9 downto 0);

            s_s2_y    <= s_s1_y;
            s_s2_avid <= s_s1_avid;
        end if;
    end process p_phase_calc;

    -- Stage 3: Waveform generation
    -- Generates wave values for both H and V displacement phases, then
    -- blends them based on the direction register.
    p_waveform : process(clk)
        variable v_wave_h   : signed(10 downto 0);
        variable v_wave_v   : signed(10 downto 0);
        variable v_ph       : unsigned(9 downto 0);
        variable v_pv       : unsigned(9 downto 0);
        variable v_blend    : signed(21 downto 0);  -- 11 * 11 = 22 bits
        variable v_blended  : signed(10 downto 0);
        variable v_dir_inv  : unsigned(9 downto 0);

        -- Helper: generate non-sine waveform from phase
        function gen_wave(phase : unsigned(9 downto 0); wf : unsigned(9 downto 0)) return signed is
            variable result : signed(10 downto 0);
        begin
            if wf < to_unsigned(512, 10) then
                -- Triangle
                if phase < to_unsigned(512, 10) then
                    result := resize(signed('0' & std_logic_vector(phase)), 11) - to_signed(256, 11);
                else
                    result := to_signed(256, 11) - resize(signed('0' & std_logic_vector(phase - to_unsigned(512, 10))), 11);
                end if;
            elsif wf < to_unsigned(768, 10) then
                -- Square
                if phase < to_unsigned(512, 10) then
                    result := to_signed(256, 11);
                else
                    result := to_signed(-256, 11);
                end if;
            else
                -- Sawtooth
                result := resize(signed('0' & std_logic_vector(phase)), 11) - to_signed(512, 11);
            end if;
            return result;
        end function;
    begin
        if rising_edge(clk) then
            v_ph := s_phase_h;
            v_pv := s_phase_v;

            if s_waveform < to_unsigned(256, 10) then
                -- True sine from LUT: output range is -511 to +511
                v_wave_h := resize(s_sin_out_h, 11);
                v_wave_v := resize(s_sin_out_v, 11);
            else
                v_wave_h := gen_wave(v_ph, s_waveform);
                v_wave_v := gen_wave(v_pv, s_waveform);
            end if;

            -- Blend H and V waves based on direction register
            -- direction=0: fully H wave, direction=1023: fully V wave
            -- blended = wave_h * (1023 - direction) / 1024 + wave_v * direction / 1024
            v_dir_inv := to_unsigned(1023, 10) - s_direction;

            -- signed(11) * signed(11) = 22 bits for each term
            v_blend := v_wave_h * signed('0' & std_logic_vector(v_dir_inv))
                     + v_wave_v * signed('0' & std_logic_vector(s_direction));
            v_blended := resize(shift_right(v_blend, 10), 11);

            -- Scale by amplitude: displacement = blended * amplitude / 1024
            s_wave_val <= resize(shift_right(v_blended * signed('0' & std_logic_vector(s_amplitude)), 10), 11);

            s_s3_y    <= s_s2_y;
            s_s3_avid <= s_s2_avid;
        end if;
    end process p_waveform;

    -- Stage 4: Apply displacement via shift register
    p_displace : process(clk)
        variable v_disp     : integer;
        variable v_tap      : integer;
        variable v_mod_amp  : signed(10 downto 0);
    begin
        if rising_edge(clk) then
            -- Luma modulation
            if s_luma_mod = '1' then
                v_mod_amp := resize(shift_right(s_wave_val * resize(signed('0' & std_logic_vector(s_s3_y)), 11), 10), 11);
            else
                v_mod_amp := s_wave_val;
            end if;

            -- Convert to tap index (center = 32)
            v_disp := to_integer(shift_right(v_mod_amp, 3));
            v_tap := clamp_idx(16 + v_disp, C_SHIFT_DEPTH - 1);

            -- Mirror: reflect if displacement would go out of range
            if s_mirror = '1' and v_tap < 0 then
                v_tap := -v_tap;
            end if;

            s_s4_y <= s_y_shift(v_tap);
            s_s4_u <= s_u_shift(v_tap);
            s_s4_v <= s_v_shift(v_tap);
            s_s4_avid <= s_s3_avid;
        end if;
    end process p_displace;

    -- Stage 5: Compose
    p_compose : process(clk)
    begin
        if rising_edge(clk) then
            s_s5_y    <= s_s4_y;
            s_s5_u    <= s_s4_u;
            s_s5_v    <= s_s4_v;
            s_s5_avid <= s_s4_avid;
        end if;
    end process p_compose;

    -- Dry/wet mix
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

end wave_distort;
