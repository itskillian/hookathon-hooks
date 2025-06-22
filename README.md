### Build

```shell
$ forge build
```

### Test

```shell
$ forge test --
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

##### Arb Logic flow
###### Sell (zeroForOne = true)
- User sells 1 eth for 2500 usdc, Pool A
    - Pool A price is now 2450

- Arb sells 1 eth for 2500 usdc, Pool B
    - Pool B price is now 2480

- Arb buys 1 eth for 2450, Pool A
    - Pool A price is now 2500

- Profit = 50


###### Buy (zerForOne = false)
- User buys 1 eth for 2500 usdc, Pool A
    - Pool A price is now 2550

- Arb buys 1 eth for 2500 usdc, Pool B
    - Pool B price is now 2520

- Arb sells 1 eth for 2550, Pool A
    - Pool A price is now 2500 again

Swap logic flow
    // usdc/eth pool, current price and target price are in usdc terms
    // e.g. 1 eth costs 2000 usdc, current price is 2000

    // scenario 1: original swap is zeroForOne = true, buy eth with usdc
    // this pushes price up so: current > target
    // first arb trade in Pool A: sell eth for usdc to bring price down to target
    // call getAmount1Delta to get amount of eth needed to bring price down to target

    TODO:

    - specify quote token for price impact, inventory share, and IL

### Notes to review
1. updateILLIQ(): check if 10^6 is sufficient precision, highly liquid pools will have ILLIQ scores below 1, so we may need to scale by 10^7
<!-- 2. current implementation is not direction sensitive, but we could add direction sensitivity wished. For example apply inventory exposure protection only if price moves against us --> 
3. is it alright to return calculatePin = 0 when volume is 0, I think this should never happen
4. is it alright to return calculateInventoryExposure = 0

### Arb Proof
make formula to solve for amount0 (assume all metrics are in quote asset - token1)
	scenario A, BUY order in pool, arb1 pool a == SELL, arb2 pool b == BUY

	illiq = price impact / vol(amount)
	price impact = illiq * amount
	new price = price * (1 +/- price impact)

	price impact = 1 +/- (after price / before price) useless?

	input token0 (x)
	output token1 (y)

	SELL vol token0 in pool A:
	zeroForOne == true
	SELL pushes price DOWN:
	new_price_a = price_a * (1 - PI_a)
	x_in_token1 = x * price_a
		e.g. x_in_token1 = 1eth * 2000usdc = 2000usdc
	pi_a = illiq_a * x_in_token1
	pi_a = illiq_a * x * price_a
	
	new_price_a = price_a * (1 - illiq_a * x * price_a)
	
	y = x * new_price_a
	y = x * price_a * (1 - illiq_a * x * price_a) CHECKED

	BUY order pool B:
	zeroForOne == false
	BUY pushes price UP
	new_price_b = price_b * (1 + PI_b)
	pi_b = illiq_b * y
	pi_b = illiq_b * x * price_a * (1 - illiq_a * x * price_a)
	new_price_b = price_b * (1 + illiq_b * x * price_a * (1 - illiq_a * x * price_a))

	new_price_a = new_price_b
	price_a * (1 - illiq_a * x * price_a) = price_b * (1 + illiq_b * x * price_a * (1 - illiq_a * x * price_a))
	(price_b * illiq_a * illiq_b * price_a^2)x^2 - (price_a^2*illiq_a + price_b * illiq_b * price_a) * x + (price_a - price_b) = 0

	PI_a = illiq_a * (amount1)
	amount1 = amount0 * price_a
	PI_a = illiq_a * amount0 * price_a

	new_price_a = price_a * (1 - illiq_a * amount0 * price_a)

	scenario B, SELL order in pool, arb1 pool a == BUY, arb2 pool b == SELL

	illiq = price impact / vol(amount)
	price impact = illiq * amount
	new price = price * (1 +/- price impact)

	input token0 (x)
	output token1 (y)

	BUY order in pool A:
	zeroForOne == false
	BUY pushes price up ->
	new_price_a = price_a * (1 + pi_a)
	pi_a = illiq_a * y
	new_price_a = price_a * (1 + illiq_a * y)
	x = y / new_price_a
	x = y / (price_a * (1 + illiq_a * y))

	SELL order in Pool B:
	zerForOne == true
	SELL pushes price down ->
	new_price_b = price_b * (1 - pi_b)
	pi_b = illiq_b * x * price_b
	pi_b = illiq_b * price_b * (y / (price_a * (1 + illiq_a * y)))
	new_price_b = price_b * (1 - (illiq_b * price_b * (y / (price_a * (1 + illiq_a * y)))))
	new_price_b = price_b - price_b^2 * illiq_b * y / (price_a * (1 + illiq_a * y))

	price_a * (1 + illiq_a * y) = price_b - price_b^2 * illiq_b * y / (price_a * (1 + illiq_a * y))
	price_a + price_a * illiq_a * y = price_b - price_b^2 * illiq_b * y / (price_a * (1 + illiq_a * y))
	price_a + price_a * illiq_a * y = price_b - price_b^2 * illiq_b * y / (price_a + price_a * illiq_a * y)
	(price_a + price_a * illiq_a * y)^2 = price_b * (price_a + price_a * illiq_a * y) - price_b^2 * illiq_b * y
	price_a^2 + 2 * price_a^2 * illiq_a * y + price_a^2 * illiq_a^2 * y^2 = price_a * price_b + price_a * price_b * illiq_a * y - price_b^2 * illiq_b * y
	price_a^2 * illiq_a^2 * y^2 + (2 * price_a^2 * illiq_a - price_a * price_b * illiq_a + price_b^2 * illiq_b) * y + (price_a^2 - price_a * price_b) = 0
	
	This is a quadratic equation in terms of y:
	A * y^2 + B * y + C = 0
	where:
	A = price_a^2 * illiq_a^2
	B = 2 * price_a^2 * illiq_a - price_a * price_b * illiq_a + price_b^2 * illiq_b
	C = price_a^2 - price_a * price_b
	
	Using quadratic formula: y = (-B ± sqrt(B^2 - 4*A*C)) / (2*A)
	We take the positive root since y represents a positive amount

	FINAL FORMULAS
		zerForOne == true
		(P_B * ILLIQ_A * ILLIQ_B * P_A²)x² - (P_A² * ILLIQ_A + P_B * ILLIQ_B * P_A) * x + (P_A - P_B) = 0
		(price_b * illiq_a * illiq_b * price_a^2)x^2 - (price_a^2 * illiq_a + price_b * illiq_b * price_a)x + (price_a - price_b) = 0

### Office hours questions

- pool inventory tracking: does add liquidity always add 0 or more tokens, is there a scenario where a user can add token0 and sub token1 (edge of range or redistribute range) or would it just be >= 0. Or call the afterAdd with token0 then afterRemove token1