# Luau RNG Cracker

A script that recreates the engine's `math.random` stream by replicating the seeding logic and brute-forcing the internal clock offset.

> [!NOTE]
> This does not work on Roblox. It targets standalone Luau builds.

<details>
<summary>Preview</summary>

<img width="601" height="361" alt="image" src="https://github.com/user-attachments/assets/c9db8133-b305-4b9c-962d-8f234725ae43" />

</details>

## How it works

Luau's RNG seed is a mix of a memory address (randomized per process by ASLR), the current time, and a clock offset. The script exploits the predictable nature of these components to reconstruct the seed.

This project:
1.  **Derives the base address** using `tostring(assert)` as an anchor.
2.  **Combines it** with `os.time()` to reconstruct the known parts of the seed.
3.  **Brute-forces** the remaining clock value until the output matches a known `math.random` result.
4.  **Predicts** future outputs using a pure Luau implementation of PCG32.

## Configuration

- **`ANCHOR_TO_L_OFFSET`**: This offset may be specific to the Luau version/build. If the script fails, this offset is likely incorrect for your binary.
- **Brute-force range**: Currently set to `1000` - `4000`. If a seed isn't found, try widening this range.
- **Target**: This implementation specifically targets the `math.random(n)` (one argument) code path.