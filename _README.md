### Arb Summary
- unlock poolManager:
	- original swap creates an arb opportunity

	- solve for the estimated ideal input for the first arb swap in our pool
		- so that both pools prices meet equilibrium
		- using known values: price and last known illiq from each pool

	- using the estimate input, quote pool A
	- use this quote's output amount, as input to quote pool B (opposite swap direction)
	- assuming concentrated liquidity, after quote pool prices will not be equal as hoped...

	- we then use these swap quotes to update illiq for each pool
		- quotes represent much more accurate illiq across relavant tick range

	- solve for the ideal arb input again using new illiq values
	- quotes pools
	- after quote pool prices will start to converge = nearing optimal arb swap
	- update illiq

	- solve for arb input 3rd time using new illiq
	- quote pools
	- prices converge again
	- check profit accounting for gas (ignoring fees)

	- execute arb swaps
- settle and lock poolManager


- solving for token input for pool price equilibrium written as:
	new price pool a = new price pool b
	
	where:
		new price = price * (1 +/- price impact)
		price impact = illiq * amount

	
	substitute both sides of this equation in known terms, and solve for the input token of the first arb swap in our own pool (dependant on direction):
		
		if arbZeroForOne == true:
			where x is input token0
			ax^2 + bx + c = 0
			a = price_a^2 * price_b * illiq_a * illiq_b
			b = -(price_a * price_b * illiq_b + price_a^2 * illiq_a)
			c = price_a - price_b

			x = (-b + sqrt(b^2 - 4*a*c)) / (2*a)

		if arbZeroForOne == false;
			where y is input token1
			ay^2 + by + c = 0
			a = price_a^2 * illiq_a^2
			b = 2 * price_a^2 * illiq_a + price_b^2 * illiq_b - price_a * price_b * illiq_a
			c = price_a^2 - price_a * price_b

			y = (-b + sqrt(b^2 - 4*a*c)) / (2*a)
