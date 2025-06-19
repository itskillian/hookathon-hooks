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