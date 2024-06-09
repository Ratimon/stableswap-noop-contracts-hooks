// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "v4-core-test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "@main/univ4/BaseHook.sol";

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import { SwapUtilsV2, LPTokenV2} from "@main/SwapUtilsV2.sol";
import {AmplificationUtilsV2} from  "@main/AmplificationUtilsV2.sol";

contract DAMM is BaseHook, ReentrancyGuard, Pausable {

    using CurrencySettler for Currency;

    using SafeERC20 for IERC20;
    // to do : remove scatch work
    using SwapUtilsV2 for SwapUtilsV2.Swap;
    using SwapUtilsV2 for SwapUtilsV2.LiquidityCallbackData;
    using SwapUtilsV2 for SwapUtilsV2.SwapCallbackData;
    using AmplificationUtilsV2 for SwapUtilsV2.Swap;

    // Struct storing data responsible for automatic market maker functionalities. In order to
    // access this data, this contract uses SwapUtils library. For more details, see SwapUtils.sol
    SwapUtilsV2.Swap public swapStorage;

    PoolKey public poolKey;

    // Maps token address to an index in the pool. Used to prevent duplicate tokens in the pool.
    // getTokenIndex function also relies on this mapping to retrieve token index.
    mapping(address => uint8) private tokenIndexes;

    error AddLiquidityThroughHookNotAllowed();

    error SwapExactOutputNotAllowed();


    /**
     * @notice Initializes this Swap contract with the given parameters.
     * The owner of LPToken will be this contract - which means
     * only this contract is allowed to mint/burn tokens.
     *
     * @param _poolManager reference to Uniswap v4 position manager
     * @param _pooledTokens an array of ERC20s this pool will accept
     * @param decimals the decimals to use for each pooled token,
     * eg 8 for WBTC. Cannot be larger than POOL_PRECISION_DECIMALS
     * @param lpTokenName the long-form name of the token to be deployed
     * @param lpTokenSymbol the short symbol for the token to be deployed
     * @param _a the amplification coefficient * n * (n - 1). See the
     * StableSwap paper for details
     * @param _fee default swap fee to be initialized with
     * @param _adminFee default adminFee to be initialized with
     */
    constructor(
        IPoolManager _poolManager,
        IERC20[] memory _pooledTokens,
        uint8[] memory decimals,
        string memory lpTokenName,
        string memory lpTokenSymbol,
        uint256 _a,
        uint256 _fee,
        uint256 _adminFee
        ) BaseHook(_poolManager) payable {
        // Check _pooledTokens and precisions parameter
        require(_pooledTokens.length == 2, "_pooledTokens.length == 2");

        // require(_pooledTokens.length > 1, "_pooledTokens.length <= 1");
        // require(_pooledTokens.length <= 32, "_pooledTokens.length > 32");
        require(
            _pooledTokens.length == decimals.length,
            "_pooledTokens decimals mismatch"
        );

        // IERC20[] memory _sortedPooledTokens = new IERC20[](decimals.length);

        // address tokenA =  address(_pooledTokens[0]);
        // address tokenB =  address(_pooledTokens[1]);

        // uint8 decimalA;
        // uint8 decimalB;

        (address token0, address token1 , uint8 decimal0, uint8 decimal1 )
            = address(_pooledTokens[0]) < address(_pooledTokens[1]) ?
                (address(_pooledTokens[0]), address(_pooledTokens[1]), decimals[0] , decimals[1] )
                : (address(_pooledTokens[1]), address(_pooledTokens[0]), decimals[1] , decimals[0]);

        _pooledTokens[0] = IERC20(token0);
        _pooledTokens[1] = IERC20(token1);

        decimals[0] = decimal0;
        decimals[1] = decimal1;

        uint256[] memory precisionMultipliers = new uint256[](decimals.length);

        for (uint8 i = 0; i < _pooledTokens.length; i++) {
            if (i > 0) {
                // Check if index is already used. Check if 0th element is a duplicate.
                require(
                    tokenIndexes[address(_pooledTokens[i])] == 0 &&
                        _pooledTokens[0] != _pooledTokens[i],
                    "Duplicate tokens"
                );
            }
            require(
                address(_pooledTokens[i]) != address(0),
                "The 0 address isn't an ERC-20"
            );
            require(
                decimals[i] <= SwapUtilsV2.POOL_PRECISION_DECIMALS,
                "Token decimals exceeds max"
            );

            precisionMultipliers[i] =
                10 **
                    (uint256(SwapUtilsV2.POOL_PRECISION_DECIMALS) -
                        uint256(decimals[i]));

            tokenIndexes[address(_pooledTokens[i])] = i;
        }

        // Check _a, _fee, _adminFee, _withdrawFee parameters
        require(_a < AmplificationUtilsV2.MAX_A, "_a exceeds maximum");
        require(_fee < SwapUtilsV2.MAX_SWAP_FEE, "_fee exceeds maximum");
        require(
            _adminFee < SwapUtilsV2.MAX_ADMIN_FEE,
            "_adminFee exceeds maximum"
        );

        // Deploy and initialize a LPToken contract
        LPTokenV2 lpToken = new LPTokenV2();

        // to do : remove scatch work
        // LPTokenV2 lpToken = LPTokenV2(Clones.clone(lpTokenTargetAddress));
        require(
            lpToken.initialize(lpTokenName, lpTokenSymbol, address(this)),
            "could not init lpToken clone"
        );

        // Initialize swapStorage struct
        swapStorage.poolManager = address(_poolManager);
        swapStorage.lpToken = lpToken;
        //to do :  sort pooledTokens
        swapStorage.pooledTokens = _pooledTokens;
        swapStorage.tokenPrecisionMultipliers = precisionMultipliers;
        swapStorage.balances = new uint256[](_pooledTokens.length);
        swapStorage.initialA = _a * AmplificationUtilsV2.A_PRECISION;
        swapStorage.futureA = _a * AmplificationUtilsV2.A_PRECISION;
        // swapStorage.initialATime = 0;
        // swapStorage.futureATime = 0;
        swapStorage.swapFee = _fee;
        swapStorage.adminFee = _adminFee;

        // to do : add PoolKey  key  
        // to do : initalize Uni Pool here or just store ?

        swapStorage.poolKey = PoolKey({
          currency0: Currency.wrap(token0),
          currency1: Currency.wrap(token1),
          fee: 3000,
          hooks: IHooks(address(this)),
          tickSpacing: 60
        });

    }

    // balanced liquidity in the pool, increase the amplifier ( the slippage is minimum) and the curve tries to mimic the Constant Price Model curve
    // but when the liquidity is imbalanced, decrease the amplifier  the slippage approaches infinity and the curve tries to mimic the Uniswap Constant Product Curve
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true, // Don't allow normally adding liquidity 
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true, // Override how swaps are done
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true, // Allow beforeSwap to return a custom delta
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Disable adding liquidity through the PM
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert AddLiquidityThroughHookNotAllowed();
    }

    // to do : check if amounts ordering is compatible with stored data
    function addLiquidity(
        uint256[] calldata amounts,
        uint256 minToMint,
        uint256 deadline
    )
        external
        payable
        virtual
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        require(block.timestamp <= deadline, "Deadline not met");

        //to do assert if key already init ?
        //to do assert if key in constructor is correct or not ?

        return swapStorage.addLiquidity( amounts, minToMint);

    }

    /**
     * @notice Burn LP tokens to remove liquidity from the pool.
     * @dev Liquidity can always be removed, even when the pool is paused.
     * @param amount the amount of LP tokens to burn
     * @param minAmounts the minimum amounts of each token in the pool
     *        acceptable for this burn. Useful as a front-running mitigation
     * @param deadline latest timestamp to accept this transaction
     * @return amounts of tokens user received
     */
    function removeLiquidity(
        uint256 amount,
        uint256[] calldata minAmounts,
        uint256 deadline
    )
        external
        payable
        virtual
        nonReentrant
        returns (uint256[] memory)
    {
        require(block.timestamp <= deadline, "Deadline not met");
        return swapStorage.removeLiquidity(amount, minAmounts);
    }


    function unlockCallback(
        bytes calldata data
    ) external override returns (bytes memory) {

        SwapUtilsV2.LiquidityCallbackData memory callbackData = abi.decode(data, (SwapUtilsV2.LiquidityCallbackData));
        require(msg.sender == callbackData.poolManager );

        if (callbackData.isAdd) {
            // Settle `callbackData.amount` of each currency from the sender
            // i.e. Create a debit of `callbackData.amount` of each currency with the Pool Manager
            callbackData.currency.settle(
                IPoolManager(callbackData.poolManager),
                callbackData.sender,
                callbackData.amount,
                false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
            );

            // Since we didn't go through the regular "modify liquidity" flow,
            // the PM just has a debit of `callbackData.amount` of each currency from us
            // We can, in exchange, get back ERC-6909 claim tokens for `callbackData.amount` of each currency
            // to create a credit of `callbackData.amount` of each currency to us
            // that balances out the debit

            // We will store those claim tokens with the hook, so when swaps take place
            // liquidity from our CSMM can be used by minting/burning claim tokens the hook owns
            callbackData.currency.take(
                IPoolManager(callbackData.poolManager),
                address(this),
                callbackData.amount,
                true // `mint` = `true` i.e. we're minting claim tokens for the hook, equivalent to money we just deposited to the PM
            );

        } else {

            callbackData.currency.settle(
                IPoolManager(callbackData.poolManager),
                address(this),
                callbackData.amount,
                true // `burn` = `true` i.e. we're  burning ERC-6909 Claim Tokens
            );

            callbackData.currency.take(
                IPoolManager(callbackData.poolManager),
                callbackData.sender, // ?
                callbackData.amount,
                false // mint` = `true` i.e. we're  claiming erc20
            );

            
        }



        return "";
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    )
        external
        override
        nonReentrant
        whenNotPaused
        returns (bytes4, BeforeSwapDelta, uint24)
        {

        SwapUtilsV2.SwapCallbackData memory callbackData = abi.decode(data, (SwapUtilsV2.SwapCallbackData));
        require(block.timestamp <= callbackData.deadline, "Deadline not met");

        // futher modifier? ie. deadlineCheck
        // ? do we really need the assertion of key ie .require( ....)

        // if (callbackData.minDy >= 0) revert SwapExactOutputNotAllowed();
        if (params.amountSpecified >= 0) revert SwapExactOutputNotAllowed();

        uint256 dxInPositive = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);


        // BalanceDelta is a packed value of (currency0Amount, currency1Amount)

        // BeforeSwapDelta varies such that it is not sorted by token0 and token1
        // Instead, it is sorted by "specifiedCurrency" and "unspecifiedCurrency"

        // Specified Currency => The currency in which the user is specifying the amount they're swapping for
        // Unspecified Currency => The other currency

        uint8 tokenIndexFrom;
        uint8 tokenIndexTo;

        if (params.zeroForOne) {

            tokenIndexFrom = 0;
            tokenIndexTo = 1;

        } else {

            tokenIndexFrom = 1;
            tokenIndexTo = 0;

        }

        int256 dy = swapStorage.swap( params, tokenIndexFrom, tokenIndexTo, dxInPositive, callbackData.minDy);

        //   int128(-dy) must be bnegative when int128(-params.amountSpecified) is positive
        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
            int128(-params.amountSpecified), // So `specifiedAmount` = +100 (exact input : amout into poolManager )  or  -100 (exact output : amout outof poolManager )
            int128(-dy) // Unspecified amount (output delta) = -100 (  amout out of poolManager )  / 100 ( amout into poolManager ) 
        );

        // to do change type of fee to uint24
        return (this.beforeSwap.selector, beforeSwapDelta, uint24(swapStorage.swapFee));
    }

    function getLpToken() public view virtual returns (LPTokenV2) {
        return swapStorage.lpToken;
    }

    /**
     * @notice Return address of the pooled token at given index. Reverts if tokenIndex is out of range.
     * @param index the index of the token
     * @return address of the token at given index
     */
    function getToken(uint8 index) public view virtual returns (IERC20) {
        require(index < swapStorage.pooledTokens.length, "Out of range");
        return swapStorage.pooledTokens[index];
    }

    /**
     * @notice Return the index of the given token address. Reverts if no matching
     * token is found.
     * @param tokenAddress address of the token
     * @return the index of the given token address
     */
    function getTokenIndex(address tokenAddress)
        public
        view
        virtual
        returns (uint8)
    {
        uint8 index = tokenIndexes[tokenAddress];
        require(
            address(getToken(index)) == tokenAddress,
            "Token does not exist"
        );
        return index;
    }


    /**
     * @notice Return current balance of the pooled token at given index
     * @param index the index of the token
     * @return current balance of the pooled token at given index with token's native precision
     */
    function getTokenBalance(uint8 index)
        external
        view
        virtual
        returns (uint256)
    {
        require(index < swapStorage.pooledTokens.length, "Index out of range");
        return swapStorage.balances[index];
    }

}