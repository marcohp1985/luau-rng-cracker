--[[
  uint64_t seed = uintptr_t(L);
  seed ^= time(NULL);
  seed ^= clock();

  pcg32_seed(&L->global->rngstate, seed);

  The only unknown variable we have is the (curtime - startup time) offset in the seeding.
  But it has a relatively small range, so we can brute-force it.
--]]

local expected = math.random(2 ^ 28) -- Just enough to not appear twice in our range
local curtime = os.time()

local ASLR_ANCHOR = tostring(assert)
local ANCHOR_TO_L_OFFSET = 0x11900 -- (luaB_assert_ptr - L_ptr), may be different per version/build

local state_hi, state_lo = 0, 0

local function u32(x)
	return bit32.band(x, 0xFFFFFFFF)
end

local function add64(ahi, alo, bhi, blo)
	local lo = u32(alo + blo)
	local carry = (alo + blo) >= 2 ^ 32 and 1 or 0
	local hi = u32(ahi + bhi + carry)
	return hi, lo
end

local function bxor64(ahi, alo, bhi, blo)
	return bit32.bxor(ahi, bhi), bit32.bxor(alo, blo)
end

-- Heavily optimized, further modifications will probably slow it down.
local function pcg32_next_u32()
	-- uint64_t oldstate = *state;
	-- *state = oldstate * 6364136223846793005ULL + (PCG32_INC | 1);
	-- uint32_t xorshifted = uint32_t(((oldstate >> 18u) ^ oldstate) >> 27u);
	-- uint32_t rot = uint32_t(oldstate >> 59u);
	-- return (xorshifted >> rot) | (xorshifted << ((-int32_t(rot)) & 31));

	local old_hi, old_lo = state_hi, state_lo

	-- state = old * 0x5851F42D4C957F2D + 105  (mod 2^64), base-2^16 limbs
	local o0 = bit32.band(old_lo, 0xFFFF)
	local o1 = old_lo // 2 ^ 16
	local o2 = bit32.band(old_hi, 0xFFFF)

	local s0 = o0 * 32557 + 105 -- 105 = PCG32_INC | 1
	local s1 = o0 * 19605 + o1 * 32557 + s0 // 2 ^ 16
	local s2 = o0 * 62509 + o1 * 19605 + o2 * 32557 + s1 // 2 ^ 16

	state_hi, state_lo =
		bit32.band(s2, 0xFFFF) + bit32.band(
			o0 * 22609 + o1 * 62509 + o2 * 19605 + old_hi // 2 ^ 16 * 32557 + s2 // 2 ^ 16,
			0xFFFF
		) * 2 ^ 16,
		bit32.band(s0, 0xFFFF) + bit32.band(s1, 0xFFFF) * 2 ^ 16

	-- output transform from old state (XSH-RR)
	-- uint32_t xorshifted = uint32_t(((oldstate >> 18u) ^ oldstate) >> 27u);
	-- uint32_t rot = uint32_t(oldstate >> 59u);
	-- return (xorshifted >> rot) | (xorshifted << ((-int32_t(rot)) & 31));
	return bit32.rrotate(
		bit32.bor(
			bit32.bxor(bit32.bor(old_lo / 2 ^ 18, old_hi * 2 ^ 14), old_lo) / 2 ^ 27,
			bit32.bxor(old_hi / 2 ^ 18, old_hi) * 32
		),
		bit32.band((old_hi / 2 ^ 27), 31)
	)
end

local function random(upperLim)
	-- Let's target only math.random(upperLim) at the moment.
	--   case 1:
	-- { // only upper limit
	--     int u = luaL_checkinteger(L, 1);
	--     luaL_argcheck(L, 1 <= u, 1, "interval is empty");

	--     uint64_t x = uint64_t(u) * pcg32_output(&g->rngstate);
	--     int r = int(1 + (x >> 32));
	--     lua_pushinteger(L, r); // int between 1 and `u'
	--     break;
	-- }
	-- Inline: x_hi = hi32( (uint32(upperLim) * rand) )
	local rand = pcg32_next_u32()
	local a = bit32.band(upperLim, 0xFFFFFFFF)
	if a == 0 then
		return 1
	end

	local a0 = bit32.band(a, 0xFFFF)
	local b0 = bit32.band(rand, 0xFFFF)
	local a1 = a // 2 ^ 16
	local b1 = rand // 2 ^ 16
	local mid = a0 * b1 + a1 * b0

	return 1 + (a1 * b1 + mid // 2 ^ 16) + a0 * b0 + bit32.band(mid, 0xFFFF) * 2 ^ 16 // 2 ^ 32 % 2 ^ 32
end

local function seed_from_number(hi, low)
	state_hi, state_lo = add64(0, 105, hi, low)
	pcg32_next_u32()
end

local function ptr_str_to_u64(str)
	local hex = str:match("0x(%x+)$")

	if #hex > 8 then
		local hi_hex = hex:sub(1, #hex - 8)
		local lo_hex = hex:sub(#hex - 7)
		return u32(tonumber(hi_hex, 16) or 0), u32(tonumber(lo_hex, 16) or 0)
	end

	return 0, u32(tonumber(hex, 16) or 0)
end

print("----------------------------")

-- uint64_t seed = uintptr_t(L);
-- seed ^= time(NULL);
-- seed ^= clock(); (we don't have access to clock() value, but we can brute-force it)

state_hi, state_lo = ptr_str_to_u64(ASLR_ANCHOR)
state_hi, state_lo = add64(state_hi, state_lo, 0, -ANCHOR_TO_L_OFFSET)
print(string.format("aslr: 0x%08X%08X", state_hi, state_lo))

local time_hi = curtime // 2 ^ 32
local time_lo = curtime % 2 ^ 32
state_hi, state_lo = bxor64(state_hi, state_lo, time_hi, time_lo)
print(string.format("time: 0x%08X%08X", time_hi, time_lo))

local saved_state_hi, saved_state_lo = state_hi, state_lo
print(string.format("seed: 0x%08X%08X", state_hi, state_lo))

print("----------------------------")

local found = false
for clockTime = 1000, 4000 do
	-- seed ^= clock();
	seed_from_number(bxor64(saved_state_hi, saved_state_lo, 0, u32(clockTime)))

	if random(2 ^ 28) == expected then
		print(`Found matching seed with offset: {clockTime}`)
		found = true
		break
	end
end

if not found then
	error("Could not find matching seed!!")
end

for i = 1, 5 do
	print("----------------------------")
	print(`Predicted: {random(2 ^ 28)}`)
	print(`Actual:    {math.random(2 ^ 28)}`)
end
