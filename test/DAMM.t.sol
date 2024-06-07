// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import "@forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

import {IERC20} from  "@openzeppelin/contracts/token/ERC20/ERC20.sol";


import {DAMM} from "@main/DAMM.sol";
import {LPTokenV2} from "@main/LPTokenV2.sol";

contract DAMMTest is Test, Deployers {

    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    LPTokenV2 lpToken;
    DAMM hook;

    function setUp() public {
        deployFreshManagerAndRouters();

        (currency0, currency1) = deployMintAndApprove2Currencies();

        vm.label(Currency.unwrap(key.currency0), "ERC20-C0");
        vm.label(Currency.unwrap(key.currency1), "ERC20-C1");

        address hookAddress = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );


        IERC20[] memory _pooledTokens = new IERC20[](2);

        _pooledTokens[0] =  IERC20(Currency.unwrap(currency0));
        _pooledTokens[1] =  IERC20(Currency.unwrap(currency1));

        // const INITIAL_A = 400
        // const SWAP_FEE = 4e6 // 4bps 
        // const ADMIN_FEE = 0
        // lpToken = new LPTokenV2("USDC/USDT Token","saddlepool" );

        uint8[] memory _decimals = new uint8[](2);
        _decimals[0] = uint8(18);
        _decimals[1]  = uint8(18);


        deployCodeTo(
            // "DAMM.sol:DAMM",
            "DAMM.sol:DAMM",
            abi.encode(manager, _pooledTokens, _decimals, "USDC/USDT Token","saddlepool", 200, 4e6, 0 ),
            // 0,
            hookAddress
        );

        hook = DAMM(hookAddress);

        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        // Add some initial liquidity
        IERC20Minimal(Currency.unwrap(key.currency0)).approve(
            hookAddress,
            1000 ether
        );
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(
            hookAddress,
            1000 ether
        );

        uint256[] memory path = new uint256[](2);
        path[0] = 10e18;
        path[1] = 10e18;

        hook.addLiquidity(path, 0 , 100000 );
    }


    function test_claimTokenBalances() public {
        // We add 1000 * (10^18) of liquidity of each token to the CSMM pool
        // The actual tokens will move into the PM
        // But the hook should get equivalent amount of claim tokens for each token
        uint token0ClaimID = CurrencyLibrary.toId(currency0);
        uint token1ClaimID = CurrencyLibrary.toId(currency1);

        uint token0ClaimsBalance = manager.balanceOf(
            address(hook),
            token0ClaimID
        );
        uint token1ClaimsBalance = manager.balanceOf(
            address(hook),
            token1ClaimID
        );

        assertEq(token0ClaimsBalance, 1000e18);
        assertEq(token1ClaimsBalance, 1000e18);
    }

}
