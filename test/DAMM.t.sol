// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {console2} from  "@forge-std/console2.sol";
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
import { SwapUtilsV2, LPTokenV2} from "@main/SwapUtilsV2.sol";

contract DAMMTest is Test, Deployers {

    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    
    address public alice = address(11);
    address public bob = address(12);
    // address public carol = address(13);
    // address public dave = address(14);
    address public deployer = address(15);

    LPTokenV2 lpToken;
    DAMM hook;

    function setUp() public {
        vm.label(deployer, "Deployer");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");

        vm.startPrank(deployer);

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

        uint8[] memory _decimals = new uint8[](2);
        _decimals[0] = uint8(18);
        _decimals[1]  = uint8(18);

        deployCodeTo(
            "DAMM.sol:DAMM",
            // INITIAL_A = 400
            // SWAP_FEE = 4e6 // 4bps 
            // ADMIN_FEE = 0
            abi.encode(manager, _pooledTokens, _decimals, "USDC/USDT Token", "saddlepool", 200, 4e6, 0 ),
            hookAddress
        );

        hook = DAMM(hookAddress);
        vm.label( address(hook.getLpToken()) , "Lp Token");

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
            address(hook),
            type(uint).max
        );
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(
            address(hook),
            type(uint).max
        );

        
        deal(Currency.unwrap(key.currency0), alice, 10000e18);
        deal(Currency.unwrap(key.currency1), alice, 10000e18);

        deal(Currency.unwrap(key.currency0), bob, 10000e18);
        deal(Currency.unwrap(key.currency1), bob, 10000e18);

        vm.stopPrank();
       
    }

    function test_addLiquidity() external {
        vm.startPrank(alice);

        IERC20Minimal(Currency.unwrap(key.currency0)).approve(
            address(hook),
            type(uint).max
        );
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(
            address(hook),
            type(uint).max
        );

        uint256 token0ClaimID = CurrencyLibrary.toId(currency0);
        uint256 token1ClaimID = CurrencyLibrary.toId(currency1);

        uint256 token0ClaimsBalanceBefore = manager.balanceOf(
            address(hook),
            token0ClaimID
        );
        uint256 token1ClaimsBalanceBefore = manager.balanceOf(
            address(hook),
            token1ClaimID
        );

        assertEq(token0ClaimsBalanceBefore, 0e18);
        assertEq(token1ClaimsBalanceBefore, 0e18);

        assertEq(hook.getTokenBalance(0), 0e18);
        assertEq(hook.getTokenBalance(1), 0e18);


        // We add 100 * (10^18) of liquidity of each token to the DAMM pool
        // The actual tokens will move into the PM But the hook should get equivalent amount of claim tokens for each token
        uint256[] memory path = new uint256[](2);
        path[0] = 100e18;
        path[1] = 100e18;
        hook.addLiquidity(path, 0 , 100000 );

        uint256 token0ClaimsBalanceAfter = manager.balanceOf(
            address(hook),
            token0ClaimID
        );
        uint256 token1ClaimsBalanceAfter = manager.balanceOf(
            address(hook),
            token1ClaimID
        );

        assertEq(token0ClaimsBalanceAfter, 100e18);
        assertEq(token1ClaimsBalanceAfter, 100e18);

        assertEq(hook.getTokenBalance(0), 100e18);
        assertEq(hook.getTokenBalance(1), 100e18);

        vm.stopPrank();
    }

    function test_removeLiquidity() external {
        vm.startPrank(alice);

        IERC20Minimal(Currency.unwrap(key.currency0)).approve(
            address(hook),
            type(uint).max
        );
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(
            address(hook),
            type(uint).max
        );

        // We add 100 * (10^18) of liquidity of each token to the DAMM pool
        // The actual tokens will move into the PM
        // But the hook should get equivalent amount of claim tokens for each token
        uint256[] memory path = new uint256[](2);
        path[0] = 100e18;
        path[1] = 100e18;
        hook.addLiquidity(path, 0 , 100000 );

        uint256 token0ClaimID = CurrencyLibrary.toId(currency0);
        uint256 token1ClaimID = CurrencyLibrary.toId(currency1);

        uint256 token0ClaimsBalanceBefore = manager.balanceOf(
            address(hook),
            token0ClaimID
        );
        uint256 token1ClaimsBalanceBefore = manager.balanceOf(
            address(hook),
            token1ClaimID
        );

        assertEq(token0ClaimsBalanceBefore, 100e18);
        assertEq(token1ClaimsBalanceBefore, 100e18);

        assertEq(hook.getTokenBalance(0), 100e18);
        assertEq(hook.getTokenBalance(1), 100e18);

        uint balanceOfToken0Before = hook.getToken(0).balanceOf(alice);
        uint balanceOfToken1Before = hook.getToken(1).balanceOf(alice);
        uint balanceOfLpTokenBefore = hook.getLpToken().balanceOf(alice);

        assertEq(hook.getLpToken().totalSupply(), 200e18);
        assertEq(balanceOfLpTokenBefore, 200e18);
       
        uint256[] memory minAmounts = new uint256[](2);
        path[0] = 50e18;
        path[1] = 50e18;

        IERC20(address(hook.getLpToken())).approve(address(hook),type(uint).max);
        hook.removeLiquidity(120e18 , minAmounts , 100000 );

        uint256 token0ClaimsBalanceAfter = manager.balanceOf(
            address(hook),
            token0ClaimID
        );
        uint256 token1ClaimsBalanceAfter = manager.balanceOf(
            address(hook),
            token1ClaimID
        );

        assertEq(token0ClaimsBalanceAfter, 40e18);
        assertEq(token1ClaimsBalanceAfter, 40e18);

        uint balanceOfToken0After = hook.getToken(0).balanceOf(alice);
        uint balanceOfToken1After = hook.getToken(1).balanceOf(alice);
        uint balanceOfLpTokenAfter = hook.getLpToken().balanceOf(alice);

        assertEq( balanceOfToken0After - balanceOfToken0Before ,  60e18 );
        assertEq( balanceOfToken1After -  balanceOfToken1Before, 60e18 );
        assertEq( balanceOfLpTokenBefore -  balanceOfLpTokenAfter, 120e18 );


        vm.stopPrank();
    }


    function test_swap_exactOutput_zeroForOne() external {
        vm.startPrank(alice);

        IERC20Minimal(Currency.unwrap(key.currency0)).approve(
            address(hook),
            type(uint).max
        );
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(
            address(hook),
            type(uint).max
        );

        uint256[] memory path = new uint256[](2);
        path[0] = 1000e18;
        path[1] = 1000e18;
        hook.addLiquidity(path, 0 , 100000 );

        vm.stopPrank();
        vm.startPrank(bob);

        IERC20Minimal(Currency.unwrap(key.currency0)).approve(
            address(swapRouter),
            type(uint).max
        );
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(
            address(swapRouter),
            type(uint).max
        );


        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Swap exact input 100 Token A
        uint balanceOfToken0Before = hook.getToken(0).balanceOf(bob);
        uint balanceOfToken1Before = hook.getToken(1).balanceOf(bob);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -100e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            abi.encode(
                SwapUtilsV2.SwapCallbackData(
                    type(uint256).max,
                    90e18
                )
            )
        );

        uint balanceOfToken0After = hook.getToken(0).balanceOf(bob);
        uint balanceOfToken1After = hook.getToken(1).balanceOf(bob);

        assertApproxEqRel(balanceOfToken1After - balanceOfToken1Before , 100e18, 0.01e18 );
        assertEq(balanceOfToken0Before - balanceOfToken0After, 100e18);

        vm.stopPrank();

    }

}
