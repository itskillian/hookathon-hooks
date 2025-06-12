// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PINHook} from "../src/PINHook.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

contract TestUtils is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolId;
    using PoolIdLibrary for PoolKey;

    // Structure to hold swap event values
    struct SwapValues {
        int128 amount0;
        int128 amount1;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        int24 tick;
        uint24 fee;
    }

    // Structure to hold liquidity event values
    struct LiquidityValues {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        uint160 sqrtPriceLower;
        uint160 sqrtPriceUpper;
        uint256 priceLower;
        uint256 priceUpper;
        uint256 amount0;
        uint256 amount1;
    }

    PINHook public hook;
    PoolId public poolId;
    LiquidityValues public liquidityInfo;

    // Helper method to get the liquidity info
    function getLiquidityInfo() public view returns (LiquidityValues memory) {
        return liquidityInfo;
    }

    // Deploy tokens and set up the test environment
    function deployCoreAndHook() public {
        // deploy uniswap v4 core
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        // calculate & deploy hook (short-cut only works on testing)
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.AFTER_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG |
                    Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                    Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            )
        );
        deployCodeTo("PINHook.sol", abi.encode(manager), hookAddress);
        // update reference to hook
        hook = PINHook(hookAddress);
    }

    function deployPool(
        int24 initialTick,
        int24 tickSpacing
    ) public returns (uint160 initialSqrtPriceX96) {
        // Create the pool key
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: hook
        });
        poolId = key.toId();

        vm.recordLogs();
        // init a new pool with dynamic fee flag, custom tick spacing & price within our liquidity range
        manager.initialize(key, TickMath.getSqrtPriceAtTick(initialTick));
        // Get the recorded logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Compute Initialize event signature
        bytes32 initEventSignature = keccak256(
            "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)"
        );

        // Parse Initialize event
        for (uint i = 0; i < logs.length; i++) {
            if (
                logs[i].topics[0] == initEventSignature &&
                logs[i].emitter == address(manager)
            ) {
                // Initialize has 3 indexed parameters (id, currency0, currency1)
                // The remaining parameters are in the data field
                (
                    uint24 eventFee,
                    int24 eventTickSpacing,
                    address eventHooks,
                    uint160 eventSqrtPriceX96,
                    int24 eventTick
                ) = abi.decode(
                        logs[i].data,
                        (uint24, int24, address, uint160, int24)
                    );

                console.log("\nInitialize Event Decoded:");
                console.log("Fee:", eventFee);
                console.log("TickSpacing:", eventTickSpacing);
                console.log("Hooks:", eventHooks);
                initialSqrtPriceX96 = eventSqrtPriceX96;
                console.log("InitialSqrtPriceX96:", eventSqrtPriceX96);
                console.log(
                    "Initial Price:",
                    convertSqrtPriceX96ToPrice(eventSqrtPriceX96)
                );
                console.log("Initial Tick:", eventTick);
                break;
            }
        }
        return initialSqrtPriceX96;
    }

    function addLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0In,
        uint160 initialSqrtPriceX96
    ) public returns (LiquidityValues memory liquidityValues) {
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity0 = LiquidityAmounts.getLiquidityForAmount0(
            sqrtPriceLower,
            sqrtPriceUpper,
            amount0In
        );
        (uint256 amount0, uint256 amount1) = LiquidityAmounts
            .getAmountsForLiquidity(
                initialSqrtPriceX96,
                sqrtPriceLower,
                sqrtPriceUpper,
                liquidity0
            );

        // Start recording logs
        vm.recordLogs();
        // add liquidity
        ModifyLiquidityParams memory liquidityParams = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(int128(liquidity0)),
            salt: bytes32(0) // not needed because hook is only on initialize and swap
        });
        modifyLiquidityRouter.modifyLiquidity(key, liquidityParams, ZERO_BYTES);
        // Get the recorded logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Compute ModifyLiquidity event signature
        bytes32 modifyLiquidityEventSignature = keccak256(
            "ModifyLiquidity(bytes32,address,int24,int24,int256,bytes32)"
        );

        // Parse ModifyLiquidity event
        for (uint i = 0; i < logs.length; i++) {
            if (
                logs[i].topics[0] == modifyLiquidityEventSignature &&
                logs[i].emitter == address(manager)
            ) {
                // ModifyLiquidity has 2 indexed parameters (id, sender)
                // The remaining parameters are in the data field
                (
                    int24 eventTickLower,
                    int24 eventTickUpper,
                    int256 eventLiquidityDelta
                ) = abi.decode(logs[i].data, (int24, int24, int256));

                console.log("\nModifyLiquidity Event Decoded:");
                console.log("TickLower:", eventTickLower);
                console.log("TickUpper:", eventTickUpper);
                console.log("LiquidityDelta:", eventLiquidityDelta);

                // Populate liquidityValues struct
                liquidityValues.tickLower = eventTickLower;
                liquidityValues.tickUpper = eventTickUpper;
                liquidityValues.liquidityDelta = eventLiquidityDelta;
                break;
            }
        }

        // Fill in the rest of the liquidityValues struct
        liquidityValues.sqrtPriceLower = sqrtPriceLower;
        liquidityValues.sqrtPriceUpper = sqrtPriceUpper;
        liquidityValues.priceLower = convertSqrtPriceX96ToPrice(sqrtPriceLower);
        liquidityValues.priceUpper = convertSqrtPriceX96ToPrice(sqrtPriceUpper);
        liquidityValues.amount0 = amount0;
        liquidityValues.amount1 = amount1;

        console.log("SqrtPriceLower:", sqrtPriceLower);
        console.log("PriceLower:", liquidityValues.priceLower);
        console.log("SqrtPriceUpper:", sqrtPriceUpper);
        console.log("PriceUpper:", liquidityValues.priceUpper);
        console.log("amount0:", amount0 / 1e18);
        console.log("amount1:", amount1 / 1e18);

        // Combine with existing liquidity info if it exists
        if (liquidityInfo.amount0 > 0 || liquidityInfo.amount1 > 0) {
            // Update the combined liquidity info
            liquidityInfo.amount0 += amount0;
            liquidityInfo.amount1 += amount1;
            liquidityInfo.liquidityDelta += liquidityValues.liquidityDelta;

            // Update the range to encompass both positions
            if (tickLower < liquidityInfo.tickLower) {
                liquidityInfo.tickLower = tickLower;
                liquidityInfo.sqrtPriceLower = sqrtPriceLower;
                liquidityInfo.priceLower = liquidityValues.priceLower;
            }
            if (tickUpper > liquidityInfo.tickUpper) {
                liquidityInfo.tickUpper = tickUpper;
                liquidityInfo.sqrtPriceUpper = sqrtPriceUpper;
                liquidityInfo.priceUpper = liquidityValues.priceUpper;
            }
        } else {
            // First position, just store as is
            liquidityInfo = liquidityValues;
        }

        return liquidityValues;
    }

    function swap(
        bool zeroForOne,
        int256 amountSpecified
    ) public returns (SwapValues memory swapValues) {
        // configure how settlement is handled in uni v4
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // configure test swap params - swapping ETH for USDC (when token0 is ETH, token1 is USDC)
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1 // Set limit based on swap direction
        });

        // Execute the swap
        BalanceDelta delta = swapRouter.swap(
            key,
            swapParams,
            testSettings,
            ZERO_BYTES
        );

        // Get post-swap state
        (uint160 sqrtPriceX96, int24 tick, , ) = StateLibrary.getSlot0(
            manager,
            poolId
        );

        // Fill basic swap values
        swapValues.amount0 = delta.amount0();
        swapValues.amount1 = delta.amount1();
        swapValues.sqrtPriceX96 = sqrtPriceX96;
        swapValues.tick = tick;

        console.log("\nSwap completed:");
        console.log("amount0:", swapValues.amount0 / 1e18);
        console.log("amount1:", swapValues.amount1 / 1e18);
        console.log("tick:", swapValues.tick);

        return swapValues;
    }

    function convertSqrtPriceX96ToPrice(
        uint160 sqrtPriceX96
    ) public pure returns (uint256) {
        // Formula: price = (sqrtPriceX96 / 2^96)^2
        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 192);
    }
}
