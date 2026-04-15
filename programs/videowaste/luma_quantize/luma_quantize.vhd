-- Copyright (C) 2026 VIDEOWASTE
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of Videomancer Community Programs.
-- See LICENSE file in the repository root for full license text.
--
-- Program Name:
--   Luma Quantize
--
-- Author:
--   VIDEOWASTE
--
-- Overview:
--   Maps continuous video to retro fixed color palettes (1-bit, CGA, EGA-style)
--   with optional ordered dithering. Unlike posterize which reduces bit depth,
--   this program quantizes luma into discrete palette entries with specific
--   Y/U/V color values for each level.
--
-- Architecture:
--   Stage 1: Input registration + coordinate counters (1 clk)
--   Stage 2: Brightness / contrast adjustment (1 clk)
--   Stage 3: Dither add + quantize to palette index (1 clk)
--   Stage 4: Palette lookup with color shift (1 clk)
--   Stage 5: Saturation adjustment (1 clk)
--   Stage 6: Dry/wet mix (4 clk)
--
-- Register Map:
--   Register 0: Palette select (0-127=1-bit B&W, 128-255=2-color warm,
--                256-383=4-level gray, 384-511=8-level gray,
--                512-639=CGA 4-color, 640-767=EGA warm,
--                768-895=thermal, 896-1023=neon)
--   Register 1: Brightness / gamma (overall brightness before quantization)
--   Register 2: Saturation (0=desaturated, 512=normal, 1023=boosted)
--   Register 3: Dither amount (0=none, 1023=maximum ordered dither)
--   Register 4: Color shift (rotate through palette assignments)
--   Register 5: Contrast (expand/compress luma range before quantization)
--   Register 6: Flags [dither_en, animate_palette, hard_edges, unused, bypass]
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

architecture luma_quantize of program_top is
    constant C_PROCESSING_DELAY_CLKS : integer := 9;

    -- Palette entry type: Y, U, V each 10-bit
    type t_palette_entry is record
        y : unsigned(9 downto 0);
        u : unsigned(9 downto 0);
        v : unsigned(9 downto 0);
    end record;

    -- Max 8 entries per palette
    type t_palette is array (0 to 7) of t_palette_entry;

    -- Bayer 4x4 ordered dither matrix (values 0..15, scaled later)
    type t_bayer_4x4 is array (0 to 3, 0 to 3) of integer range 0 to 15;
    constant C_BAYER : t_bayer_4x4 := (
        ( 0,  8,  2, 10),
        (12,  4, 14,  6),
        ( 3, 11,  1,  9),
        (15,  7, 13,  5)
    );

    -- Palette definitions
    -- 1-bit B&W (2 entries)
    constant C_PAL_BW : t_palette := (
        (y => to_unsigned(   0, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        (y => to_unsigned(1023, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        others => (y => to_unsigned(0, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10))
    );

    -- 2-color warm (2 entries)
    constant C_PAL_WARM2 : t_palette := (
        (y => to_unsigned(128, 10), u => to_unsigned(480, 10), v => to_unsigned(560, 10)),
        (y => to_unsigned(900, 10), u => to_unsigned(490, 10), v => to_unsigned(540, 10)),
        others => (y => to_unsigned(0, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10))
    );

    -- 4-level gray (4 entries)
    constant C_PAL_GRAY4 : t_palette := (
        (y => to_unsigned(  0, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        (y => to_unsigned(341, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        (y => to_unsigned(682, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        (y => to_unsigned(1023, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        others => (y => to_unsigned(0, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10))
    );

    -- 8-level gray (8 entries)
    constant C_PAL_GRAY8 : t_palette := (
        (y => to_unsigned(  0, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        (y => to_unsigned(146, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        (y => to_unsigned(292, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        (y => to_unsigned(438, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        (y => to_unsigned(585, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        (y => to_unsigned(731, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        (y => to_unsigned(877, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        (y => to_unsigned(1023, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10))
    );

    -- CGA 4-color (4 entries)
    constant C_PAL_CGA : t_palette := (
        (y => to_unsigned(  0, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        (y => to_unsigned(400, 10), u => to_unsigned(300, 10), v => to_unsigned(512, 10)),
        (y => to_unsigned(400, 10), u => to_unsigned(700, 10), v => to_unsigned(700, 10)),
        (y => to_unsigned(1023, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        others => (y => to_unsigned(0, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10))
    );

    -- EGA warm (4 entries)
    constant C_PAL_EGA : t_palette := (
        (y => to_unsigned(  0, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        (y => to_unsigned(300, 10), u => to_unsigned(512, 10), v => to_unsigned(700, 10)),
        (y => to_unsigned(800, 10), u => to_unsigned(400, 10), v => to_unsigned(600, 10)),
        (y => to_unsigned(1023, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        others => (y => to_unsigned(0, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10))
    );

    -- Thermal (4 entries)
    constant C_PAL_THERMAL : t_palette := (
        (y => to_unsigned(  0, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        (y => to_unsigned(200, 10), u => to_unsigned(800, 10), v => to_unsigned(300, 10)),
        (y => to_unsigned(500, 10), u => to_unsigned(400, 10), v => to_unsigned(800, 10)),
        (y => to_unsigned(950, 10), u => to_unsigned(400, 10), v => to_unsigned(550, 10)),
        others => (y => to_unsigned(0, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10))
    );

    -- Neon (4 entries)
    constant C_PAL_NEON : t_palette := (
        (y => to_unsigned(  0, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10)),
        (y => to_unsigned(500, 10), u => to_unsigned(300, 10), v => to_unsigned(400, 10)),
        (y => to_unsigned(600, 10), u => to_unsigned(600, 10), v => to_unsigned(800, 10)),
        (y => to_unsigned(700, 10), u => to_unsigned(300, 10), v => to_unsigned(500, 10)),
        others => (y => to_unsigned(0, 10), u => to_unsigned(512, 10), v => to_unsigned(512, 10))
    );

    -- Control signals
    signal s_palette_sel    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_brightness     : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_saturation     : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_dither_amount  : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_color_shift    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_contrast       : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_dither_enable  : std_logic;
    signal s_animate        : std_logic;
    signal s_hard_edges     : std_logic;
    signal s_bypass_enable  : std_logic;
    signal s_dry_wet        : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);

    -- Coordinate counters
    signal s_h_count    : unsigned(11 downto 0) := (others => '0');
    signal s_v_count    : unsigned(11 downto 0) := (others => '0');
    signal s_prev_hsync : std_logic := '1';
    signal s_prev_vsync : std_logic := '1';

    -- Frame counter for animation
    signal s_frame_count   : unsigned(9 downto 0) := (others => '0');
    signal s_anim_shift    : unsigned(9 downto 0) := (others => '0');

    -- Stage 1: input registration
    signal s_s1_y    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s1_u    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s1_v    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s1_avid : std_logic;
    signal s_s1_hpos : unsigned(1 downto 0);
    signal s_s1_vpos : unsigned(1 downto 0);

    -- Stage 2: brightness/contrast adjusted
    signal s_s2_y    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s2_u    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s2_v    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s2_avid : std_logic;
    signal s_s2_hpos : unsigned(1 downto 0);
    signal s_s2_vpos : unsigned(1 downto 0);

    -- Stage 3: quantized index
    signal s_s3_idx  : integer range 0 to 7;
    signal s_s3_u    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s3_v    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s3_avid : std_logic;

    -- Stage 4: palette looked up
    signal s_s4_y    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s4_u    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s4_v    : unsigned(C_VIDEO_DATA_WIDTH - 1 downto 0);
    signal s_s4_avid : std_logic;

    -- Stage 5: saturation adjusted
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

begin
    -- Register mapping
    s_palette_sel    <= unsigned(registers_in(0));
    s_brightness     <= unsigned(registers_in(1));
    s_saturation     <= unsigned(registers_in(2));
    s_dither_amount  <= unsigned(registers_in(3));
    s_color_shift    <= unsigned(registers_in(4));
    s_contrast       <= unsigned(registers_in(5));
    s_dither_enable  <= registers_in(6)(0);
    s_animate        <= registers_in(6)(1);
    s_hard_edges     <= registers_in(6)(2);
    s_bypass_enable  <= registers_in(6)(4);
    s_dry_wet        <= unsigned(registers_in(7));

    -- Pixel coordinate counters
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
                -- Increment frame counter for animation
                s_frame_count <= s_frame_count + 1;
            end if;
        end if;
    end process p_counters;

    -- Animation shift: add frame counter to color_shift when animate is on
    s_anim_shift <= s_frame_count when s_animate = '1' else (others => '0');

    -- Stage 1: Input registration + capture coordinates
    p_input_stage : process(clk)
    begin
        if rising_edge(clk) then
            s_s1_y    <= unsigned(data_in.y);
            s_s1_u    <= unsigned(data_in.u);
            s_s1_v    <= unsigned(data_in.v);
            s_s1_avid <= data_in.avid;
            s_s1_hpos <= s_h_count(1 downto 0);
            s_s1_vpos <= s_v_count(1 downto 0);
        end if;
    end process p_input_stage;

    -- Stage 2: Brightness and contrast adjustment
    p_bright_contrast : process(clk)
        variable v_y_signed   : signed(11 downto 0);
        variable v_contrast_s : signed(11 downto 0);
        variable v_product    : signed(23 downto 0);
        variable v_adjusted   : signed(11 downto 0);
    begin
        if rising_edge(clk) then
            -- Apply brightness: shift luma by (brightness - 512)
            -- brightness=0 -> subtract 512, brightness=512 -> no change, brightness=1023 -> add 511
            v_y_signed := resize(signed('0' & std_logic_vector(s_s1_y)), 12) +
                          resize(signed('0' & std_logic_vector(s_brightness)), 12) -
                          to_signed(512, 12);

            -- Apply contrast: scale around midpoint 512
            -- contrast=0 -> 0x (flat gray), contrast=512 -> 1x (normal), contrast=1023 -> ~2x
            -- result = 512 + (y - 512) * contrast / 512
            v_contrast_s := v_y_signed - to_signed(512, 12);
            v_product := v_contrast_s * resize(signed('0' & std_logic_vector(s_contrast)), 12);
            v_adjusted := resize(shift_right(v_product, 9), 12) + to_signed(512, 12);

            -- Clamp to 0-1023
            if v_adjusted < to_signed(0, 12) then
                s_s2_y <= to_unsigned(0, 10);
            elsif v_adjusted > to_signed(1023, 12) then
                s_s2_y <= to_unsigned(1023, 10);
            else
                s_s2_y <= unsigned(v_adjusted(9 downto 0));
            end if;

            s_s2_u    <= s_s1_u;
            s_s2_v    <= s_s1_v;
            s_s2_avid <= s_s1_avid;
            s_s2_hpos <= s_s1_hpos;
            s_s2_vpos <= s_s1_vpos;
        end if;
    end process p_bright_contrast;

    -- Stage 3: Dither + quantize to palette index
    p_dither_quantize : process(clk)
        variable v_num_levels  : integer range 1 to 8;
        variable v_bayer_val   : integer range 0 to 15;
        variable v_dither_off  : signed(11 downto 0);
        variable v_y_dithered  : signed(11 downto 0);
        variable v_index_wide  : unsigned(19 downto 0);
        variable v_index       : integer range 0 to 7;
        variable v_palette_id  : integer range 0 to 7;
    begin
        if rising_edge(clk) then
            -- Determine palette and number of levels from palette_sel
            v_palette_id := to_integer(shift_right(s_palette_sel, 7));
            case v_palette_id is
                when 0      => v_num_levels := 2;  -- 1-bit B&W
                when 1      => v_num_levels := 2;  -- 2-color warm
                when 2      => v_num_levels := 4;  -- 4-level gray
                when 3      => v_num_levels := 8;  -- 8-level gray
                when 4      => v_num_levels := 4;  -- CGA
                when 5      => v_num_levels := 4;  -- EGA warm
                when 6      => v_num_levels := 4;  -- Thermal
                when 7      => v_num_levels := 4;  -- Neon
                when others => v_num_levels := 4;
            end case;

            -- Get Bayer dither value from 4x4 matrix
            v_bayer_val := C_BAYER(to_integer(s_s2_vpos), to_integer(s_s2_hpos));

            -- Scale dither: offset = ((bayer - 8) * dither_amount) >> 4
            -- bayer is 0..15, centered at 8 gives -8..+7
            -- dither_amount 0..1023, so max offset = +/- ~512
            if s_dither_enable = '1' then
                v_dither_off := resize(
                    shift_right(
                        (to_signed(v_bayer_val, 12) - to_signed(8, 12)) *
                        resize(signed('0' & std_logic_vector(s_dither_amount)), 12),
                    4),
                12);
            else
                v_dither_off := to_signed(0, 12);
            end if;

            -- Add dither to luma
            v_y_dithered := resize(signed('0' & std_logic_vector(s_s2_y)), 12) + v_dither_off;
            if v_y_dithered < to_signed(0, 12) then
                v_y_dithered := to_signed(0, 12);
            elsif v_y_dithered > to_signed(1023, 12) then
                v_y_dithered := to_signed(1023, 12);
            end if;

            -- Quantize: index = (y * num_levels) >> 10, clamped to num_levels-1
            v_index_wide := unsigned(v_y_dithered(9 downto 0)) * to_unsigned(v_num_levels, 10);
            v_index := to_integer(shift_right(v_index_wide, 10));
            if v_index >= v_num_levels then
                v_index := v_num_levels - 1;
            end if;

            -- Apply color shift: rotate index
            -- Effective shift = (color_shift >> 7) + anim_shift, mod num_levels
            v_index := (v_index + to_integer(shift_right(s_color_shift, 7)) +
                        to_integer(s_anim_shift)) mod v_num_levels;

            s_s3_idx  <= v_index;
            s_s3_u    <= s_s2_u;
            s_s3_v    <= s_s2_v;
            s_s3_avid <= s_s2_avid;
        end if;
    end process p_dither_quantize;

    -- Stage 4: Palette lookup
    p_palette_lookup : process(clk)
        variable v_palette_id : integer range 0 to 7;
        variable v_entry      : t_palette_entry;
    begin
        if rising_edge(clk) then
            v_palette_id := to_integer(shift_right(s_palette_sel, 7));

            case v_palette_id is
                when 0      => v_entry := C_PAL_BW(s_s3_idx);
                when 1      => v_entry := C_PAL_WARM2(s_s3_idx);
                when 2      => v_entry := C_PAL_GRAY4(s_s3_idx);
                when 3      => v_entry := C_PAL_GRAY8(s_s3_idx);
                when 4      => v_entry := C_PAL_CGA(s_s3_idx);
                when 5      => v_entry := C_PAL_EGA(s_s3_idx);
                when 6      => v_entry := C_PAL_THERMAL(s_s3_idx);
                when 7      => v_entry := C_PAL_NEON(s_s3_idx);
                when others => v_entry := C_PAL_GRAY4(s_s3_idx);
            end case;

            s_s4_y    <= v_entry.y;
            s_s4_u    <= v_entry.u;
            s_s4_v    <= v_entry.v;
            s_s4_avid <= s_s3_avid;
        end if;
    end process p_palette_lookup;

    -- Stage 5: Saturation adjustment on palette U/V
    p_saturation : process(clk)
        variable v_u_sat : signed(21 downto 0);
        variable v_v_sat : signed(21 downto 0);
        variable v_u_adj : signed(11 downto 0);
        variable v_v_adj : signed(11 downto 0);
    begin
        if rising_edge(clk) then
            -- Saturation: 0=grayscale, 512=normal (1x), 1023=boosted (~2x)
            -- u_adj = 512 + (u - 512) * saturation / 512
            v_u_sat := resize(signed('0' & std_logic_vector(s_s4_u)), 22) - to_signed(512, 22);
            v_u_sat := resize(shift_right(v_u_sat * resize(signed('0' & std_logic_vector(s_saturation)), 22), 9), 22);
            v_u_adj := resize(v_u_sat, 12) + to_signed(512, 12);

            v_v_sat := resize(signed('0' & std_logic_vector(s_s4_v)), 22) - to_signed(512, 22);
            v_v_sat := resize(shift_right(v_v_sat * resize(signed('0' & std_logic_vector(s_saturation)), 22), 9), 22);
            v_v_adj := resize(v_v_sat, 12) + to_signed(512, 12);

            -- Clamp U
            if v_u_adj < to_signed(0, 12) then
                s_s5_u <= to_unsigned(0, 10);
            elsif v_u_adj > to_signed(1023, 12) then
                s_s5_u <= to_unsigned(1023, 10);
            else
                s_s5_u <= unsigned(v_u_adj(9 downto 0));
            end if;

            -- Clamp V
            if v_v_adj < to_signed(0, 12) then
                s_s5_v <= to_unsigned(0, 10);
            elsif v_v_adj > to_signed(1023, 12) then
                s_s5_v <= to_unsigned(1023, 10);
            else
                s_s5_v <= unsigned(v_v_adj(9 downto 0));
            end if;

            s_s5_y    <= s_s4_y;
            s_s5_avid <= s_s4_avid;
        end if;
    end process p_saturation;

    -- Dry/wet mix (4 clk)
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

end luma_quantize;
