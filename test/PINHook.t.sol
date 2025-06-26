// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestUtils} from "./TestUtils.sol";
import {console} from "forge-std/console.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

contract PINHookTest is TestUtils {
    function setUp() public {
        // deploy v4 core and hook
        deployCoreAndHook();
        // deploy pool with custom tick spacing
        uint160 initialSqrtPriceX96 = deployPool(80000, 1); // initial tick, tick spacing
        // add liquidity
        addLiquidity(79500, 80520, 100 ether, initialSqrtPriceX96); // tick lower, tick upper, amount0In, initialSqrtPriceX96
        addLiquidity(79000, 81000, 100 ether, initialSqrtPriceX96); // tick lower, tick upper, amount0In, initialSqrtPriceX96
    }

    function testSimpleSwap() public {
        console.log("\n--- Simple swap test ---");

        // Perform a simple swap
        SwapValues memory swapVals = swap(true, -1 ether);

        // Basic assertions to verify the swap worked
        assertEq(swapVals.amount0, -1 ether);
        assertTrue(swapVals.amount1 > 0);
        assertTrue(swapVals.tick < 80000);
        assertTrue(swapVals.fee > 0);

        console.log("Swap successful!");
        console.log("Amount0:", swapVals.amount0 / 1e18);
        console.log("Amount1:", swapVals.amount1 / 1e18);
        console.log("Final tick:", swapVals.tick);
        console.log("Fee charged:", swapVals.fee);
    }
}
