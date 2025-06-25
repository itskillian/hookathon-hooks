// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "lib/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {SafeCurrencyMetadata} from "lib/v4-periphery/src/libraries/SafeCurrencyMetadata.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {IV4Quoter} from "lib/v4-periphery/src/interfaces/IV4Quoter.sol";

contract PINHook is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error MustUseDynamicFee();
    error NotOwner();

    uint24 public constant MIN_FEE = 100;
    IV4Quoter public immutable quoter;
    address public owner;
    
    // Flag to prevent recursive afterSwap calls
    bool private _executingArb;

    struct PoolData {
        uint256 totalVolume; // tracked by afterSwap in token0 terms
        int256 netVolume; // tracked by afterSwap in token0 terms
        uint32 lastTimeUpdate; // tracked by afterSwap
        uint32 timeDecaySeconds; // config
        uint256 decayPerSecond; // 1e6 / timeDecaySeconds
        uint8 tradeIntensityFactor; // config
        uint160 beforeSwapPriceX96; // tracked by beforeSwap
    }

    struct Quote {
        uint256 amountOut;
        uint256 gasEstimate;
    }
    
    // store pool data
    mapping(PoolId => PoolData) public poolData;
    // store pool keys for arb
    mapping(PoolId => PoolKey[]) public arbPoolKeys;

    constructor(IPoolManager _poolManager, IV4Quoter _quoter) BaseHook(_poolManager) {
        quoter = _quoter;
        owner = msg.sender;
    }

    /*
    ------ MODIFIERS ------ 
    */

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /*
    ------ CORE HOOK FUNCTIONS ------ 
    */

    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal pure override returns (bytes4) {
        // Check if the pool supports dynamic fees
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        PoolData storage data = poolData[poolId];

        // Initialize pool data with default values
        data.timeDecaySeconds = 604800; // 7 days
        data.decayPerSecond = 1e18 / data.timeDecaySeconds; // scaled by 1e18
        data.tradeIntensityFactor = 3;
        data.totalVolume = 0;
        data.netVolume = 0;
        data.lastTimeUpdate = uint32(block.timestamp);

        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        PoolData storage data = poolData[poolId];

        // Apply time decay to volumes
        applyTimeDecay(data);

        // Calculate OIR
        int256 pin = calculatePIN(data, params, key);

        // tbd if fee shall be different depending on direction of OIR

        // Calculate fee based on OIR (you can adjust this formula)
        uint24 fee = uint24(uint256(abs(pin)) * 100); // Scale OIR to basis points

        // Ensure fee is within bounds
        if (fee < MIN_FEE) fee = MIN_FEE;
        if (fee >= LPFeeLibrary.MAX_LP_FEE) fee = LPFeeLibrary.MAX_LP_FEE - 1; // Max 1%

        (data.beforeSwapPriceX96, , , ) = poolManager.getSlot0(poolId);

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        require(arbPoolKeys[poolId].length > 0, "No arb pools");
        
        PoolData storage data = poolData[poolId];

        // update total volume and net volume after swap
        data.totalVolume += uint256(abs(delta.amount0()));
        data.netVolume += int256(abs(delta.amount0()));

        // ------ ARB LOGIC ------

        if (!_executingArb) {
            _executingArb = true;
            
            (uint160 afterSwapPriceX96, , , ) = poolManager.getSlot0(poolId);

            uint256 arbAmount = calcArbAmount(key, afterSwapPriceX96, data.beforeSwapPriceX96);
            
            uint256 arbProfit = detectAndExecuteArb(
                key,
                arbPoolKeys[poolId], 
                arbAmount,
                swapParams.zeroForOne
            );
            
            _executingArb = false; // Reset flag after arbitrage
        }
        

        //-------------------------------------------------------------------

        return (BaseHook.afterSwap.selector, 0);
    }

    /*
    ------ HELPER FUNCTIONS ------ 
    */

    function applyTimeDecay(PoolData storage data) internal {
        // Calculate time decay
        uint32 currentTime = uint32(block.timestamp);
        uint32 secondsPassed = currentTime - data.lastTimeUpdate;
        // Fallback if no swap in 7 days
        uint256 timeDecay = secondsPassed > data.timeDecaySeconds
            ? 1e18
            : secondsPassed * data.decayPerSecond;

        // reduce volume pre swap by time decay
        data.totalVolume = (data.totalVolume * (1e18 - timeDecay)) / 1e18;
        data.netVolume = (data.netVolume * (1e18 - int256(timeDecay))) / 1e18;
        data.lastTimeUpdate = currentTime;
    }

    function calculatePIN(
        PoolData storage data,
        SwapParams calldata params,
        PoolKey memory key
    ) internal view returns (int256) {
        // Check if amountSpecified is in token0 terms, otherwise convert
        bool isToken0 = params.zeroForOne == (params.amountSpecified < 0);
        uint256 nextTradeVolToken0 = isToken0
            ? abs(params.amountSpecified)
            : convertToToken0(abs(params.amountSpecified), key);
        // now we have the amount in token0 terms & can add the amount to the total volume
        // if selling token0, remove from net volume, if buying token0, add to net volume
        // only update for calcualtion in beforeSwap in case swap fails. Only update state in afterSwap
        uint256 totalVolumeInterim = data.totalVolume + nextTradeVolToken0;
        int256 netVolumeInterim = data.netVolume +
            (
                params.zeroForOne
                    ? -int256(nextTradeVolToken0)
                    : int256(nextTradeVolToken0)
            );

        return netVolumeInterim / int256(totalVolumeInterim);
    }

    function convertToToken0(
        uint256 amount,
        PoolKey memory key
    ) internal view returns (uint256) {
        // Get current price for conversion -- MAKE SURE VALID PRICE
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());

        // Get decimals for both tokens & calculate delta decimals
        uint8 token0Decimals = SafeCurrencyMetadata.currencyDecimals(
            Currency.unwrap(key.currency0)
        );
        uint8 token1Decimals = SafeCurrencyMetadata.currencyDecimals(
            Currency.unwrap(key.currency1)
        );
        uint8 deltaDecimals = token0Decimals - token1Decimals;
        uint256 scaledAmount = amount * (10 ** deltaDecimals);
        uint256 intermediate = (scaledAmount << 96) / sqrtPriceX96;
        uint256 token0Amount = (intermediate << 96) / sqrtPriceX96;

        return token0Amount;
    }

    // helper function to get abs value
    function abs(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    // Calculate expected output amount using the given price
    function calculateExpectedOutput(
        uint256 amountIn,
        uint160 sqrtPriceX96,
        bool zeroForOne
    ) internal pure returns (uint256 amountOut) {
        if (zeroForOne) {
            // Selling token0 for token1
            // amountOut = amountIn * price
            // price = (sqrtPriceX96 / 2^96)^2
            uint256 priceX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            amountOut = FullMath.mulDiv(amountIn, priceX192, FixedPoint96.Q96 * FixedPoint96.Q96);
        } else {
            // Selling token1 for token0
            // amountOut = amountIn / price
            // price = (sqrtPriceX96 / 2^96)^2
            uint256 priceX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            amountOut = FullMath.mulDiv(amountIn, FixedPoint96.Q96 * FixedPoint96.Q96, priceX192);
        }
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // true
            afterInitialize: true, // true
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // true
            afterSwap: true, // true
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function addArbPool(PoolKey calldata key, PoolId poolId, PoolKey calldata arbPoolKey) external onlyOwner {
        require(key.currency0 == arbPoolKey.currency0 && key.currency1 == arbPoolKey.currency1, "Arb pool must have same currency pair as the main pool");
        require(arbPoolKeys[poolId].length < 3, "Max 3 arb pools");
        
        arbPoolKeys[poolId].push(arbPoolKey);
    }

    function removeArbPool(PoolId poolId, uint8 index) external onlyOwner {
        require(arbPoolKeys[poolId].length > 1, "Min 1 arb pool");
        require(index < arbPoolKeys[poolId].length, "Index out of bounds");
        
        PoolKey[] storage poolKeys = arbPoolKeys[poolId];
        poolKeys[index] = poolKeys[poolKeys.length - 1];
        poolKeys.pop();
    }

    function detectAndExecuteArb(
        PoolKey memory key,
        PoolKey[] memory arbPoolKeysArray,
        uint256 amount,
        bool zeroForOne
    ) internal returns (uint256) {
        Quote memory hookPoolQuote;
        Quote memory arbPoolQuote;

        // quote hook pool (Pool A)
        IV4Quoter.QuoteExactSingleParams memory hookParams = IV4Quoter.QuoteExactSingleParams({
            poolKey: key,
            zeroForOne: !zeroForOne,
            exactAmount: uint128(amount),
            hookData: ""
        });
        (uint256 amountOut, uint256 gasEstimate) = quoter.quoteExactInputSingle(hookParams);
        
        hookPoolQuote = Quote({
            amountOut: amountOut,
            gasEstimate: gasEstimate
        });

        // find best quote from arb pools (Pools B, C, D...)
        uint8 bestQuoteIndex = 0;
        for (uint8 i = 0; i < arbPoolKeysArray.length; i++) {
            IV4Quoter.QuoteExactSingleParams memory arbParams = IV4Quoter.QuoteExactSingleParams({
                poolKey: arbPoolKeysArray[i],
                zeroForOne: zeroForOne,
                exactAmount: uint128(hookPoolQuote.amountOut),
                hookData: ""
            });
            (uint256 arbAmountOut, uint256 arbGasEstimate) = quoter.quoteExactInputSingle(arbParams);

            if (arbAmountOut > arbPoolQuote.amountOut) {
                bestQuoteIndex = i;
                arbPoolQuote = Quote({
                    amountOut: arbAmountOut,
                    gasEstimate: arbGasEstimate
                });
            }
        }

        // profit is calculated in token1 terms for zeroForOne = true
        // profit is calculated in token0 terms for zeroForOne = false
        // quote A input - quote B output = arb profit
        uint256 grossArbProfit = arbPoolQuote.amountOut - amount;
        uint256 gasCostWei = (arbPoolQuote.gasEstimate + hookPoolQuote.gasEstimate) * tx.gasprice;
        uint256 gasCostInProfitToken = getGasCostInProfitToken(gasCostWei);

        uint256 netArbProfit = grossArbProfit - gasCostInProfitToken;
        if (netArbProfit > 0) {
            // TODO complete arb swap logic

            // set swap params A
            SwapParams memory swapAParams = SwapParams({
                zeroForOne: !zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: 0 // TODO
            });
            
            // swap A
            BalanceDelta swapDeltaA = poolManager.swap(key, swapAParams, "");

            // swap params B
            SwapParams memory swapBParams = SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(zeroForOne ? swapDeltaA.amount0() : swapDeltaA.amount1()),
                sqrtPriceLimitX96: 0 // TODO
            });


            // swap B
            BalanceDelta swapDeltaB = poolManager.swap(arbPoolKeysArray[bestQuoteIndex], swapBParams, "");

            uint256 finalProfit = zeroForOne ?
                uint256(int256(swapDeltaB.amount1()) + int256(amount)) :
                uint256(int256(swapDeltaB.amount0()) + int256(amount));

            return finalProfit;
        }
        return 0;
    }

    function calcArbAmount(
        PoolKey memory key,
        uint160 currentPriceX96,
        uint160 targetPriceX96
    ) internal view returns (uint256) {
        // Use the actual AMM math to find exact amount needed
        uint128 liquidity = poolManager.getLiquidity(key.toId());

        // Calculate amount needed to reach target price based on trade direction
        uint256 exactAmount;
        if (currentPriceX96 > targetPriceX96) {
            exactAmount = SqrtPriceMath.getAmount1Delta(
                currentPriceX96,
                targetPriceX96,
                liquidity,
                true
            );
        } else {
            exactAmount = SqrtPriceMath.getAmount0Delta(
                currentPriceX96,
                targetPriceX96,
                liquidity,
                true
            );
        }
        return (exactAmount * 90) / 100;
    }

    function getGasCostInProfitToken(uint256) public pure returns (uint256) {
        return 0; // TODO
    }
}
