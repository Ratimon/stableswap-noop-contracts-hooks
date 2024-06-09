<h1>🦄 StableSwap Curve NoOp Hook 🦄 </h1>

It is a NoOp hook with customized AMM functionality that overrides the Uniswap V4 's own logic including adding/removing liquidity and swap.

This solidity implementation utilizes **StableSwap** curve. More detail should be found at this [paper](https://www.curve.fi/stableswap-paper.pdf).

The features include:

- Ability to ramp up/down A (**Amplification**) parameter by admin to reflect the nature of highly correlated pairing assets ( e.g. stable coins or yield-bearing generating asset / underlying assets ). This allows more efficient trading with lower slippage at greater volumn and deeper market depth.

- Fungible token (ERC20) to represent the ownership of liquidity. Liquidity providers can mint/burn the lp token by adding/remove liquidity respectively.

- Ability to configure swap fee.


### Quick Installation

```bash
nvm use v20.12.2
git clone <the repo link>
cd <the directory>
pnpm i 
pnpm prepare
```

>[!NOTE]
> You may need to remove the  [`/lib`](./lib) in case you want to re-install the dependencies


### Futher Improvements

- Dynamic Parameter via afterSwap hook

This can create new customized Dynamic Automated Market Maker. For example. dynamic **Amplification** param could be configured via **afterSwap** hook, based on the data/condition regarding the pool  current imbalancing proportion of assets.

- Remove Liquidity in one token functionality.

- Remove Liquidity, weighted differently than the pool's current balances