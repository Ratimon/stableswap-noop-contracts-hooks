// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettleTake} from "v4-core/libraries/CurrencySettleTake.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "@main/univ4/BaseHook.sol";

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// import {LPTokenV2} from "@main/LPTokenV2.sol";


import { SwapUtilsV2, LPTokenV2} from "@main/SwapUtilsV2.sol";
import {AmplificationUtilsV2} from  "@main/AmplificationUtilsV2.sol";

contract DAMM is BaseHook, ReentrancyGuard, Pausable {

    using CurrencySettleTake for Currency;

    using SafeERC20 for IERC20;
    // to do : remove scatch work
    using SwapUtilsV2 for SwapUtilsV2.Swap;
    using SwapUtilsV2 for SwapUtilsV2.CallbackData
    ;
    using AmplificationUtilsV2 for SwapUtilsV2.Swap;

    // Struct storing data responsible for automatic market maker functionalities. In order to
    // access this data, this contract uses SwapUtils library. For more details, see SwapUtils.sol
    SwapUtilsV2.Swap public swapStorage;

    PoolKey  public poolKey;

    // Maps token address to an index in the pool. Used to prevent duplicate tokens in the pool.
    // getTokenIndex function also relies on this mapping to retrieve token index.
    mapping(address => uint8) private tokenIndexes;

    error AddLiquidityThroughHook();


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

        // Clone and initialize a LPToken contract
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
        swapStorage.pooledTokens = _pooledTokens;
        swapStorage.tokenPrecisionMultipliers = precisionMultipliers;
        swapStorage.balances = new uint256[](_pooledTokens.length);
        swapStorage.initialA = _a * AmplificationUtilsV2.A_PRECISION;
        swapStorage.futureA = _a * AmplificationUtilsV2.A_PRECISION;
        // swapStorage.initialATime = 0;
        // swapStorage.futureATime = 0;
        swapStorage.swapFee = _fee;
        swapStorage.adminFee = _adminFee;

        // to do  add PoolKey  key  
        // to do initalize Uni Pool here or just store ?
        address tokenA =  address(_pooledTokens[0]);
        address tokenB =  address(_pooledTokens[1]);

        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        swapStorage.poolKey =  PoolKey({
          currency0: Currency.wrap(token0),
          currency1: Currency.wrap(token1),
          fee: 3000,
          hooks: IHooks(address(this)),
          tickSpacing: 60
        });

    }

    /*** MODIFIERS ***/

    /**
     * @notice Modifier to check deadline against current timestamp
     * @param deadline latest timestamp to accept this transaction
     */
    modifier deadlineCheck(uint256 deadline) {
        require(block.timestamp <= deadline, "Deadline not met");
        _;
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
        revert AddLiquidityThroughHook();
    }

    // if (data.deposit) {
    //     data.currency.take(manager, data.user, data.amount, true); // mint 6909
    //     data.currency.settle(manager, data.user, data.amount, false); // transfer ERC20
    // } else {
    //     data.currency.settle(manager, data.user, data.amount, true); // burn 6909
    //     data.currency.take(manager, data.user, data.amount, false); // claim ERC20


    // todo modify to comply with univ4 data stucture
    // ie. remove total supply 
    // Customized add liquidity with totalSupply/ transferFrom / balanceOf
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
        deadlineCheck(deadline)
        returns (uint256)
    {
        //to do assert if key already init
        // /to do assert if key in constructor is correct or not

        return swapStorage.addLiquidity( amounts, minToMint);

    }

    function unlockCallback(
        bytes calldata data
    ) external override returns (bytes memory) {

        SwapUtilsV2.CallbackData memory callbackData = abi.decode(data, (SwapUtilsV2.CallbackData));

        // to do : refactor to poolManagerOnly
        require(msg.sender == callbackData.poolManager );


        // to do : add if else for addLiqudity or ..


        // Settle `amountEach` of each currency from the sender
        // i.e. Create a debit of `amountEach` of each currency with the Pool Manager
        callbackData.currency.settle(
            IPoolManager(callbackData.poolManager),
            callbackData.sender,
            callbackData.amount,
            false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
        );

        // Since we didn't go through the regular "modify liquidity" flow,
        // the PM just has a debit of `amountEach` of each currency from us
        // We can, in exchange, get back ERC-6909 claim tokens for `amountEach` of each currency
        // to create a credit of `amountEach` of each currency to us
        // that balances out the debit

        // We will store those claim tokens with the hook, so when swaps take place
        // liquidity from our CSMM can be used by minting/burning claim tokens the hook owns
        callbackData.currency.take(
            IPoolManager(callbackData.poolManager),
            address(this),
            callbackData.amount,
            true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
        );


        return "";
    }

    // to do : add view function ie. getTokenBalance

}