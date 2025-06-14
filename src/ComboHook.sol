// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";
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
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IV4Quoter} from "lib/v4-periphery/src/interfaces/IV4Quoter.sol";

contract ArbPinHook is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant PIPS_SCALE = 1e6;
    uint256 private constant FEE_DIVISOR = 1e38; // PIPS_SCALE * PRECISION^2 / 10000 for direct pips calculation

    error MustUseDynamicFee();
    error Unauthorized();
    error InvalidTimeDecay();
    error InvalidFee();

    // structs
    struct PoolData {
        uint256 totalVolume; // tracked by afterSwap in token0 terms
        int256 netVolume; // tracked by afterSwap in token0 terms
        uint32 lastTimeUpdate; // tracked by afterSwap
        uint32 timeDecaySeconds; // config
        uint256 decayPerSecond; // PRECISION / timeDecaySeconds
        uint24 minFee; // minimum fee in pips
        int8 deltaDecimals; // token0Decimals - token1Decimals
        uint160 sqrtPriceX96Before; // cached price before swap
        uint256 avgILLIQ; // running average ILLIQ ratio * 10^6
        uint256 tradeCount; // number of trades used in ILLIQ average
        uint256 inventoryToken0; // current inventory of token0
        uint256 inventoryToken1; // current inventory of token1
        uint256 tvl; // total value locked
    }
    struct Quote {
        uint256 amountOut;
        uint256 gasEstimate;
    }

    // state variables
    IV4Quoter public immutable quoter;
    address public owner;
    bool private _executingArb;
    
    // mappings
    mapping(PoolId => PoolData) public poolData; // store pool data
    mapping(PoolId => PoolKey[]) public arbPoolKeys; // store pool keys for arb

    // constructor
    constructor(IPoolManager _poolManager, IV4Quoter _quoter) BaseHook(_poolManager) {
        owner = msg.sender;
        quoter = _quoter;
    }

    /*
    ------ MODIFIERS ------ 
    */

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
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

        // Initialize pool data with non-zero default values
        data.timeDecaySeconds = 604800; // 7 days
        data.decayPerSecond = PRECISION / data.timeDecaySeconds; // scaled by PRECISION
        data.totalVolume = 1e18; // in token0 terms - start with small positive value to avoid division by zero
        data.netVolume = 1e16; // in token0 terms - start with small positive value to avoid division by zero
        data.lastTimeUpdate = uint32(block.timestamp);
        data.minFee = 500; // 0.05% in pips
        // Cache token decimals to avoid external calls on every swap
        data.deltaDecimals =
            int8(
                SafeCurrencyMetadata.currencyDecimals(
                    Currency.unwrap(key.currency0)
                )
            ) -
            int8(
                SafeCurrencyMetadata.currencyDecimals(
                    Currency.unwrap(key.currency1)
                )
            );

        console.log("---- AFTER INITIALIZE LOGIC ----");
        console.log("timeDecaySeconds", data.timeDecaySeconds);
        console.log("decayPerSecond", data.decayPerSecond);
        console.log("totalVolume", data.totalVolume);
        console.log("netVolume", data.netVolume);
        console.log("lastTimeUpdate", data.lastTimeUpdate);
        console.log("minFee", data.minFee);
        console.log("deltaDecimals", data.deltaDecimals);

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

        // get price before swap
        (data.sqrtPriceX96Before, , , ) = poolManager.getSlot0(poolId);

        console.log("---- BEFORE SWAP LOGIC ----");

        // Apply time decay to volumes
        applyTimeDecay(data);

        // Calculate next trade volume in token0 terms (only once)
        uint256 nextTradeVolToken0 = getNextTradeVolume(params, data);

        // Calculate PIN
        int256 pin = calculatePIN(data, params, nextTradeVolToken0);
        console.log("pin before swap", pin);

        // Calculate expected price impact (now includes trade volume calculation)
        uint256 expectedPriceImpact = calculateExpectedPriceImpact(
            data,
            nextTradeVolToken0
        );
        console.log("nextTradeVolToken0", nextTradeVolToken0);
        console.log("avgILLIQ", data.avgILLIQ);
        console.log("expectedPriceImpact", expectedPriceImpact);

        // Calculate inventory exposure
        uint256 relevantInventoryExposure = calculateInventoryExposure(
            data,
            params.zeroForOne
        );
        console.log("relevantInventoryExposure", relevantInventoryExposure);

        // Calculate fee based on PIN, expected price impact, and inventory exposure
        uint24 fee = calculateFee(
            abs(pin), // current implementation is not direction sensitive, but we could add direction sensitivity wished. For exampel apply inventory exposure protection only if price moves against us
            data.minFee,
            expectedPriceImpact,
            relevantInventoryExposure
        );
        console.log("fee", fee);

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

        console.log("---- AFTER SWAP LOGIC ----");

        // Calculate price impact of the last completed trade
        uint256 lastTradePriceImpact = calculatePriceImpactAfterSwap(
            data,
            poolId
        );

        // Volume of the last completed trade
        uint256 lastTradeVolume = uint256(abs(delta.amount0()));

        // Update ILLIQ ratio with data from the last completed trade
        updateILLIQ(data, lastTradePriceImpact, lastTradeVolume);

        // Update total volume and net volume after swap
        data.totalVolume += lastTradeVolume;
        // Add to net volume if swapper is buying token0, subtract if selling token0
        data.netVolume += int256(delta.amount0());

        // Update inventory based on swap deltas
        // delta.amount0() is positive when pool receives token0, negative when pool gives token0
        // delta.amount1() is positive when pool receives token1, negative when pool gives token1
        data.inventoryToken0 = uint256(
            int256(data.inventoryToken0) + delta.amount0()
        );
        data.inventoryToken1 = uint256(
            int256(data.inventoryToken1) + delta.amount1()
        );

        // ------ ARB LOGIC ------

        if (!_executingArb) {
            _executingArb = true;
            
            (uint160 afterSwapPriceX96, , , ) = poolManager.getSlot0(poolId);

            uint256 arbAmount = calcArbAmount(key, afterSwapPriceX96, data.sqrtPriceX96Before);
            
            // uint256 arbProfit = 
            detectAndExecuteArb(
                key,
                arbPoolKeys[poolId], 
                arbAmount,
                swapParams.zeroForOne
            );
            
            _executingArb = false; // Reset flag after arbitrage
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        PoolData storage data = poolData[poolId];

        // Update inventory when liquidity is added
        // delta.amount0() and delta.amount1() are positive when tokens are added to the pool
        data.inventoryToken0 += uint256(abs(delta.amount0()));
        data.inventoryToken1 += uint256(abs(delta.amount1()));

        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        PoolData storage data = poolData[poolId];

        // Update inventory when liquidity is removed
        // delta.amount0() and delta.amount1() are negative when tokens are removed from the pool
        data.inventoryToken0 = uint256(
            int256(data.inventoryToken0) + delta.amount0()
        );
        data.inventoryToken1 = uint256(
            int256(data.inventoryToken1) + delta.amount1()
        );

        return (BaseHook.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    /*
    ------ HELPER FUNCTIONS ------ 
    */

    function applyTimeDecay(PoolData storage data) internal {
        // Calculate time decay
        uint32 currentTime = uint32(block.timestamp);
        uint32 secondsPassed = currentTime - data.lastTimeUpdate;
        // Cap decay to slightly less than 100% to ensure volumes never reach zero
        uint256 timeDecay = secondsPassed > data.timeDecaySeconds
            ? PRECISION - 1 // Max 99.999...% decay, never 100%
            : secondsPassed * data.decayPerSecond;

        // reduce volume pre swap by time decay
        data.totalVolume =
            (data.totalVolume * (PRECISION - timeDecay)) /
            PRECISION;
        data.netVolume =
            (data.netVolume * int256(PRECISION - timeDecay)) /
            int256(PRECISION);
        data.lastTimeUpdate = currentTime;

        console.log("---- Results of time decay function ----");
        console.log("currentTime", currentTime);
        console.log("lastTimeUpdate", data.lastTimeUpdate);
        console.log("secondsPassed", secondsPassed);
        console.log("timeDecay", timeDecay);
        console.log("totalVolume", data.totalVolume);
        console.log("netVolume", data.netVolume);
    }

    function getNextTradeVolume(
        SwapParams calldata params,
        PoolData storage data
    ) internal view returns (uint256) {
        // Check if amountSpecified is in token0 terms, otherwise convert
        bool isToken0 = params.zeroForOne == (params.amountSpecified < 0);

        if (isToken0) {
            return abs(params.amountSpecified);
        }

        // Convert token1 amount to token0 terms using cached price
        uint256 amount = abs(params.amountSpecified);

        // Use cached price from data struct instead of fetching again
        uint256 scaledAmount = data.deltaDecimals >= 0
            ? amount * (10 ** uint8(data.deltaDecimals))
            : amount / (10 ** uint8(-data.deltaDecimals));
        uint256 intermediate = (scaledAmount << 96) / data.sqrtPriceX96Before;
        uint256 token0Amount = (intermediate << 96) / data.sqrtPriceX96Before;

        return token0Amount;
    }

    function calculatePIN(
        PoolData storage data,
        SwapParams calldata params,
        uint256 nextTradeVolToken0
    ) internal view returns (int256) {
        // calculate total volume including next trade
        uint256 totalVolumeInterim = data.totalVolume + nextTradeVolToken0;

        // if swapper is buying token0 add to net volume, if selling token0 subtract from net volume
        int256 netVolumeInterim = data.netVolume +
            (
                params.zeroForOne
                    ? -int256(nextTradeVolToken0)
                    : int256(nextTradeVolToken0)
            );

        console.log("---- Results of PIN calculation function----");
        console.log("params.zeroForOne", params.zeroForOne);
        console.log("params.amountSpecified", params.amountSpecified);
        console.log("nextTradeVolToken0", nextTradeVolToken0);
        console.log("totalVolumeInterim", totalVolumeInterim);
        console.log("netVolumeInterim", netVolumeInterim);

        return
            (netVolumeInterim * int256(PRECISION)) / int256(totalVolumeInterim);
    }

    function calculateExpectedPriceImpact(
        PoolData storage data,
        uint256 nextTradeVolToken0
    ) internal view returns (uint256) {
        // If no historical data available, return a default small value
        if (data.avgILLIQ == 0 || nextTradeVolToken0 == 0) {
            return 1000; // 0.1% default price impact in pips scale (1000 / 1e6 = 0.001)
        }

        // Expected price impact = avgILLIQ * volume / 1e6 (since ILLIQ is scaled by 1e6)
        // ILLIQ formula: (priceImpact_in_pips_scale * 1e6) / volume
        // So: priceImpact_in_pips_scale = (ILLIQ * volume) / 1e6
        return (data.avgILLIQ * nextTradeVolToken0) / (1e6 * PRECISION);
    }

    function calculateInventoryExposure(
        PoolData storage data,
        bool zeroForOne
    ) internal returns (uint256) {
        // Adjust token0 inventory for decimal differences before price conversion

        uint256 adjustedToken0Inventory = data.deltaDecimals >= 0
            ? data.inventoryToken0 / (10 ** uint8(data.deltaDecimals))
            : data.inventoryToken0 * (10 ** uint8(-data.deltaDecimals));

        // Convert adjusted token0 inventory to token1 terms: token0 * (sqrtPriceX96/2^96)^2 = token0 * sqrtPriceX96^2 / 2^192
        uint256 inventoryToken0InToken1Terms = FullMath.mulDiv(
            FullMath.mulDiv(
                adjustedToken0Inventory,
                data.sqrtPriceX96Before,
                FixedPoint96.Q96
            ),
            data.sqrtPriceX96Before,
            FixedPoint96.Q96
        );
        data.tvl = inventoryToken0InToken1Terms + data.inventoryToken1;

        uint256 inventoryExposure0 = data.tvl > 0
            ? ((data.tvl - data.inventoryToken1) * PRECISION) / data.tvl
            : 0;
        uint256 inventoryExposure1 = PRECISION - inventoryExposure0;

        console.log("---- Results of inventory exposure calculation ----");
        console.log("data.tvl", data.tvl);
        console.log("data.inventoryToken1", data.inventoryToken1);
        console.log("data.inventoryToken0", data.inventoryToken0);
        console.log("data.sqrtPriceX96Before", data.sqrtPriceX96Before);
        console.log(
            "inventoryToken0InToken1Terms",
            inventoryToken0InToken1Terms
        );
        console.log("inventoryExposure0", inventoryExposure0);
        console.log("inventoryExposure1", inventoryExposure1);
        console.log("zeroForOne", zeroForOne);

        // Select appropriate inventory exposure based on trade direction
        return zeroForOne ? inventoryExposure1 : inventoryExposure0;
    }

    function calculateFee(
        uint256 pin,
        uint24 minFee,
        uint256 expectedPriceImpact,
        uint256 inventoryExposure
    ) internal pure returns (uint24) {
        if (pin == 0) return minFee;

        // Calculate fee increase directly in pips
        // expectedPriceImpact is scaled by PIPS_SCALE (1e6, represents percentage in pips)
        // inventoryExposure is scaled by PRECISION (1e18, represents percentage, multiplied by inventoryMultiplier for amplification)
        // pin is scaled by PRECISION (1e18, represents percentage)
        // FEE_DIVISOR = PIPS_SCALE * PRECISION^2 / 10000 to convert directly to pips (1% = 10000 pips)
        uint256 feeIncreasePips = (expectedPriceImpact *
            inventoryExposure *
            pin) / FEE_DIVISOR;

        console.log("---- Results of fee calculation ----");
        console.log("feeIncreasePips", feeIncreasePips);
        console.log("minFee", minFee);
        console.log("expectedPriceImpact", expectedPriceImpact);
        console.log("inventoryExposure", inventoryExposure);
        console.log("pin", pin);

        return uint24(minFee + feeIncreasePips);
    }

    function calculatePriceImpactAfterSwap(
        PoolData storage data,
        PoolId poolId
    ) internal view returns (uint256) {
        // Get price after swap
        (uint160 sqrtPriceX96After, , , ) = poolManager.getSlot0(poolId);

        if (data.sqrtPriceX96Before == 0) return 0;

        uint256 priceChange = data.sqrtPriceX96Before > sqrtPriceX96After
            ? data.sqrtPriceX96Before - sqrtPriceX96After
            : sqrtPriceX96After - data.sqrtPriceX96Before;

        // Return price impact as a percentage scaled by PIPS_SCALE (1e6)
        return (priceChange * PIPS_SCALE) / data.sqrtPriceX96Before;
    }

    function updateILLIQ(
        PoolData storage data,
        uint256 lastTradePriceImpact,
        uint256 lastTradeVolume
    ) internal {
        // Calculate ILLIQ ratio for the last completed trade: (priceImpact / volume) * 10^6
        // TODO!!! IF 10^6 is sufficient precision, because highly liquid pools will have below 1 ILLIQ scores, so we may need to scale by 10^7
        if (lastTradeVolume > 0) {
            uint256 currentILLIQ = (lastTradePriceImpact * 1e6) /
                lastTradeVolume;

            // Update running average with equal weights
            if (data.tradeCount == 0) {
                data.avgILLIQ = currentILLIQ;
            } else {
                data.avgILLIQ =
                    (data.avgILLIQ * data.tradeCount + currentILLIQ) /
                    (data.tradeCount + 1);
            }
            data.tradeCount += 1;
        }
    }

    // INTERNAL HELPER FUNCTIONS

    function abs(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    /*
    ------ ARB HELPER FUNCTIONS ------ 
    */

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

    // HOOK CONFIGURATION
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: true,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // HOOK MANAGEMENT FUNCTIONS

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Unauthorized();
        owner = newOwner;
    }

    // Allows owner to update sensitivity of pin metric
    function updateTimeDecaySeconds(
        PoolId poolId,
        uint32 newTimeDecaySeconds
    ) external onlyOwner {
        if (newTimeDecaySeconds == 0) revert InvalidTimeDecay();

        PoolData storage data = poolData[poolId];
        data.timeDecaySeconds = newTimeDecaySeconds;
        data.decayPerSecond = PRECISION / newTimeDecaySeconds;
    }

    // Allows owner to update min fee
    function updateMinFee(PoolId poolId, uint24 newMinFee) external onlyOwner {
        PoolData storage data = poolData[poolId];
        if (newMinFee <= 0 || newMinFee >= LPFeeLibrary.MAX_LP_FEE - 1)
            revert InvalidFee();

        data.minFee = newMinFee;
    }
}