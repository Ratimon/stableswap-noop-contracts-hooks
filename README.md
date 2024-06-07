## Dynamic Automated Market Maker

### Scaffolding

```bash
forge install https://github.com/Uniswap/v4-core
```

Remove default Counter.sol files

```bash
rm ./**/Counter*.sol
```

Now, to configure foundry.toml - add the following to its end:

```bash
# foundry.toml
solc_version = '0.8.25'
evm_version = "cancun"
optimizer_runs = 800
via_ir = false
ffi = true
```

### Dependencies

```bash
pnpm add -D @openzeppelin/contracts@5.0.2
pnpm add -D openzeppelin/contracts-upgradeable@5.0.2
```