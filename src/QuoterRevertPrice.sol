// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ParseBytes} from "@uniswap/v4-core/src/libraries/ParseBytes.sol";

library QuoterRevertPrice {
    using QuoterRevertPrice for bytes;
    using ParseBytes for bytes;

    error UnexpectedRevertBytes(bytes revertData);
    error QuoteSwapWithPrice(uint256 amountOut, uint160 sqrtPriceX96);

    function revertQuoteWithPrice(uint256 amountOut, uint160 sqrtPriceX96) internal pure {
        revert QuoteSwapWithPrice(amountOut, sqrtPriceX96);
    }

    function bubbleReason(bytes memory revertData) internal pure {
        assembly ("memory-safe") {
            revert(add(revertData, 0x20), mload(revertData))
        }
    }
    
    function parseQuoteAmountAndPrice(bytes memory reason) internal pure returns (uint256 amountOut, uint160 sqrtPriceX96) {
        if (reason.parseSelector() != QuoteSwapWithPrice.selector) {
            revert UnexpectedRevertBytes(reason);
        }

        // reason -> reason+0x1f is the length of the reason string
        // reason+0x20 -> reason+0x23 is the selector of QuoteSwapWithPrice
        // reason+0x24 -> reason+0x43 is the amountOut
        // reason+0x44 -> reason+0x63 is the sqrtPriceX96
        assembly ("memory-safe") {
            amountOut := mload(add(reason, 0x24))
            sqrtPriceX96 := mload(add(reason, 0x44))
        }
    }
}
