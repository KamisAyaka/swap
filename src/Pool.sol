// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "./libraries/SqrtPriceMath.sol";
import "./libraries/TickMath.sol";
import "./libraries/LiquidityMath.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/SwapMath.sol";
import "./libraries/FixedPoint128.sol";
import "./libraries/TickBitmap.sol";

import "./interfaces/IPool.sol";
import "./interfaces/IFactory.sol";

contract Pool is IPool {
    using SafeCast for uint256;
    using LowGasSafeMath for int256;
    using LowGasSafeMath for uint256;

    /**
     * @notice 获取池子的工厂合约地址
     * @dev 该地址在合约部署时确定且不可更改
     * @return 部署当前流动性池的工厂合约地址
     */
    /// @inheritdoc IPool
    address public immutable override factory;

    /**
     * @notice 获取池中第一种代币的地址
     * @dev 代币顺序由地址排序决定，地址值较小的为token0
     * @return 流动性池中第一种代币的合约地址
     */
    /// @inheritdoc IPool
    address public immutable override token0;

    /**
     * @notice 获取池中第二种代币的地址
     * @dev 代币顺序由地址排序决定，地址值较大的为token1
     * @return 流动性池中第二种代币的合约地址
     */
    /// @inheritdoc IPool
    address public immutable override token1;

    /**
     * @notice 获取流动性池的交易费率
     * @dev 费率以万分比表示（如0.3%费率对应3000）
     * @return 当前流动性池的交易费率（单位：万分点）
     */
    /// @inheritdoc IPool
    uint24 public constant override fee = 3000;

    /**
     * @notice 获取当前价格的平方根表示
     * @dev 价格格式为 (sqrt(price) * 2^96)，用于高精度计算
     * @return 当前价格平方根的Q96.96定点数表示
     */
    /// @inheritdoc IPool
    uint160 public override sqrtPriceX96;

    /**
     * @notice 获取当前价格对应的tick值
     * @dev tick是价格离散化单位，每个tick对应特定价格区间
     * @return 代表当前价格点的tick索引值
     */
    /// @inheritdoc IPool
    int24 public override tick;

    // 连续 tick 模式
    int24 public constant tickSpacing = 1;

    /**
     * @notice 获取池中当前流动性总量
     * @dev 流动性值使用128位无符号整数存储
     * @return 当前池中流动性总量（L值）
     */
    /// @inheritdoc IPool
    uint128 public override liquidity;

    /**
     * @notice 获取代币0的全局手续费累计值
     * @dev 手续费以每单位流动性积累量表示（格式: fee * 2^128）
     * @return 代币0的累计手续费（单位：Q128.128）
     */
    /// @inheritdoc IPool
    uint256 public override feeGrowthGlobal0X128;

    /**
     * @notice 获取代币1的全局手续费累计值
     * @dev 手续费以每单位流动性积累量表示（格式: fee * 2^128）
     * @return 代币1的累计手续费（单位：Q128.128）
     */
    /// @inheritdoc IPool
    uint256 public override feeGrowthGlobal1X128;

    struct Position {
        // 该 Position 拥有的流动性
        uint128 liquidity;
        // 价格区间下界
        int24 tickLower;
        // 价格区间上界
        int24 tickUpper;
        // 可提取的 token0 数量
        uint128 tokensOwed0;
        // 可提取的 token1 数量
        uint128 tokensOwed1;
        // 上次提取手续费时的 feeGrowthGlobal0X128
        uint256 feeGrowthInside0LastX128;
        // 上次提取手续费是的 feeGrowthGlobal1X128
        uint256 feeGrowthInside1LastX128;
    }

    struct ModifyPositionParams {
        // the address that owns the position
        address owner;
        // any change in liquidity
        int128 liquidityDelta;
        int24 tickLower;
        int24 tickUpper;
    }

    // 交易中需要临时存储的变量
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // 该交易中用户转入的 token0 的数量
        uint256 amountIn;
        // 该交易中用户转出的 token1 的数量
        uint256 amountOut;
        // 该交易中的手续费，如果 zeroForOne 是 ture，则是用户转入 token0，单位是 token0 的数量，反正是 token1 的数量
        uint256 feeAmount;
    }

    struct TickInfo {
        uint128 liquidityGross; // 该 tick 上的总流动性
        int128 liquidityNet; // 当价格穿过该 tick 时的流动性净变化
        uint256 feeGrowthOutside0X128; // 该 tick 外部的 token0 手续费
        uint256 feeGrowthOutside1X128; // 该 tick 外部的 token1 手续费
    }

    // tick 位图（每 256 个 tick 一个 word）
    mapping(int16 => uint256) public tickBitmap;

    // tick 详细信息存储
    mapping(int24 => TickInfo) public ticks;

    // 用一个 mapping 来存放所有 Position 的信息
    mapping(bytes32 => Position) public positions;

    constructor() {
        // constructor 中初始化 immutable 的常量
        // Factory 创建 Pool 时会通 new Pool{salt: salt}() 的方式创建 Pool 合约，通过 salt 指定 Pool 的地址，这样其他地方也可以推算出 Pool 的地址
        // 参数通过读取 Factory 合约的 parameters 获取
        // 不通过构造函数传入，因为 CREATE2 会根据 initcode 计算出新地址（new_address = hash(0xFF, sender, salt, bytecode)），带上参数就不能计算出稳定的地址了
        (factory, token0, token1) = IFactory(msg.sender).parameters();
        // 初始化 tick 边界
        TickBitmap.flipTick(tickBitmap, TickMath.MIN_TICK, tickSpacing);
        TickBitmap.flipTick(tickBitmap, TickMath.MAX_TICK, tickSpacing);
    }

    function initialize(uint160 sqrtPriceX96_) external override {
        // 初始化 Pool 的 sqrtPriceX96
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function mint(
        address recipient,
        uint128 amount,
        int24 tickLower,
        int24 tickUpper,
        bytes calldata data
    ) external override returns (uint256 amount0, uint256 amount1) {
        require(amount > 0, "Mint amount must be greater than 0");
        require(tickLower < tickUpper, "INVALID_TICK_RANGE");
        // 基于 amount 计算出当前需要多少 amount0 和 amount1
        (int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: recipient,
                liquidityDelta: int128(amount),
                tickLower: tickLower,
                tickUpper: tickUpper
            })
        );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        uint256 balance0Before;
        uint256 balance1Before;

        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();

        // 回调 mintCallback
        IMintCallback(msg.sender).mintCallback(amount0, amount1, data);
        // 检查钱到位了没有，如果到位了对应修改相关信息
        if (amount0 > 0)
            require(balance0Before.add(amount0) <= balance0(), "M0");
        if (amount1 > 0)
            require(balance1Before.add(amount1) <= balance1(), "M1");

        emit Mint(msg.sender, recipient, amount, amount0, amount1);
    }

    function burn(
        uint128 amount,
        int24 tickLower,
        int24 tickUpper
    ) external override returns (uint256 amount0, uint256 amount1) {
        require(amount > 0, "Burn amount must be greater than 0");
        require(tickLower < tickUpper, "INVALID_TICK_RANGE");
        bytes32 pid = positionId(msg.sender, tickLower, tickUpper);
        require(
            amount <= positions[pid].liquidity,
            "Burn amount exceeds liquidity"
        );
        // 修改 positions 中的信息
        (int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: msg.sender,
                liquidityDelta: -int128(amount),
                tickLower: tickLower,
                tickUpper: tickUpper
            })
        );
        // 获取燃烧后的 amount0 和 amount1
        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            positions[pid].tokensOwed0 += uint128(amount0);
            positions[pid].tokensOwed1 += uint128(amount1);
        }

        emit Burn(msg.sender, amount, amount0, amount1);
    }

    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override returns (uint128 amount0, uint128 amount1) {
        require(tickLower < tickUpper, "INVALID_TICK_RANGE");
        // 获取当前用户的 position
        bytes32 pid = positionId(msg.sender, tickLower, tickUpper);
        Position storage position = positions[pid];
        // 把钱退给用户 recipient
        // 修改 position 中的信息
        amount0 = amount0Requested > position.tokensOwed0
            ? position.tokensOwed0
            : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1
            ? position.tokensOwed1
            : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit Collect(msg.sender, recipient, amount0, amount1);
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, "AS");
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < sqrtPriceX96 &&
                    sqrtPriceLimitX96 > TickMath.MIN_SQRT_PRICE
                : sqrtPriceLimitX96 > sqrtPriceX96 &&
                    sqrtPriceLimitX96 < TickMath.MAX_SQRT_PRICE,
            "SPL"
        );

        // amountSpecified 大于 0 代表用户指定了 token0 的数量，小于 0 代表用户指定了 token1 的数量
        bool exactInput = amountSpecified > 0;

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: sqrtPriceX96,
            feeGrowthGlobalX128: zeroForOne
                ? feeGrowthGlobal0X128
                : feeGrowthGlobal1X128,
            amountIn: 0,
            amountOut: 0,
            feeAmount: 0
        });

        // 主循环：处理每个价格区间
        while (
            state.amountSpecifiedRemaining != 0 &&
            (
                zeroForOne
                    ? state.sqrtPriceX96 > sqrtPriceLimitX96
                    : state.sqrtPriceX96 < sqrtPriceLimitX96
            )
        ) {
            // 使用位图查找下一个有流动性的 tick
            (int24 nextTick, ) = TickBitmap.nextInitializedTickWithinOneWord(
                tickBitmap,
                tick, // 当前全局 tick
                tickSpacing,
                zeroForOne // lte 方向
            );
            // 边界保护：确保 nextTick 在有效范围内
            if (nextTick < TickMath.MIN_TICK) nextTick = TickMath.MIN_TICK;
            if (nextTick > TickMath.MAX_TICK) nextTick = TickMath.MAX_TICK;
            uint160 nextSqrtPriceX96 = TickMath.getSqrtPriceAtTick(nextTick);

            // 计算目标价格（不超过限制）
            uint160 targetSqrtPriceX96 = zeroForOne
                ? (
                    nextSqrtPriceX96 < sqrtPriceLimitX96
                        ? nextSqrtPriceX96
                        : sqrtPriceLimitX96
                )
                : (
                    nextSqrtPriceX96 > sqrtPriceLimitX96
                        ? nextSqrtPriceX96
                        : sqrtPriceLimitX96
                );

            // 计算交易步骤
            (
                uint160 newSqrtPriceX96,
                uint256 stepAmountIn,
                uint256 stepAmountOut,
                uint256 stepFeeAmount
            ) = SwapMath.computeSwapStep(
                    state.sqrtPriceX96,
                    targetSqrtPriceX96,
                    liquidity,
                    state.amountSpecifiedRemaining,
                    fee
                );

            // 更新状态
            state.sqrtPriceX96 = newSqrtPriceX96;
            state.amountIn += stepAmountIn;
            state.amountOut += stepAmountOut;
            state.feeAmount += stepFeeAmount;

            // 计算交易后用户手里的 token0 和 token1 的数量
            if (exactInput) {
                state.amountSpecifiedRemaining -= (state.amountIn +
                    state.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated.sub(
                    state.amountOut.toInt256()
                );
            } else {
                state.amountSpecifiedRemaining += state.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated.add(
                    (state.amountIn + state.feeAmount).toInt256()
                );
            }

            // 更新手续费
            state.feeGrowthGlobalX128 += FullMath.mulDiv(
                stepFeeAmount,
                FixedPoint128.Q128,
                liquidity
            );

            // 如果到达 tick 边界，更新流动性
            if (state.sqrtPriceX96 == nextSqrtPriceX96) {
                TickInfo storage nextTickInfo = ticks[nextTick];
                liquidity = LiquidityMath.addDelta(
                    liquidity,
                    zeroForOne
                        ? nextTickInfo.liquidityNet
                        : -nextTickInfo.liquidityNet
                );
            }
        }

        // 更新新的价格
        sqrtPriceX96 = state.sqrtPriceX96;
        tick = TickMath.getTickAtSqrtPrice(state.sqrtPriceX96);

        // 计算手续费
        state.feeGrowthGlobalX128 += FullMath.mulDiv(
            state.feeAmount,
            FixedPoint128.Q128,
            liquidity
        );

        // 更新手续费相关信息
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        }

        (amount0, amount1) = zeroForOne == exactInput
            ? (
                amountSpecified - state.amountSpecifiedRemaining,
                state.amountCalculated
            )
            : (
                state.amountCalculated,
                amountSpecified - state.amountSpecifiedRemaining
            );

        if (zeroForOne) {
            // callback 中需要给 Pool 转入 token
            uint256 balance0Before = balance0();
            ISwapCallback(msg.sender).swapCallback(amount0, amount1, data);
            require(balance0Before.add(uint256(amount0)) <= balance0(), "IIA");

            // 转 Token 给用户
            if (amount1 < 0)
                TransferHelper.safeTransfer(
                    token1,
                    recipient,
                    uint256(-amount1)
                );
        } else {
            // callback 中需要给 Pool 转入 token
            uint256 balance1Before = balance1();
            ISwapCallback(msg.sender).swapCallback(amount0, amount1, data);
            require(balance1Before.add(uint256(amount1)) <= balance1(), "IIA");

            // 转 Token 给用户
            if (amount0 < 0)
                TransferHelper.safeTransfer(
                    token0,
                    recipient,
                    uint256(-amount0)
                );
        }

        emit Swap(
            msg.sender,
            recipient,
            amount0,
            amount1,
            sqrtPriceX96,
            liquidity,
            tick
        );
    }

    /// @dev Get the pool's balance of token0
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance0() private view returns (uint256) {
        (bool success, bytes memory data) = token0.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @dev Get the pool's balance of token1
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) = token1.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    function _modifyPosition(
        ModifyPositionParams memory params
    ) private returns (int256 amount0, int256 amount1) {
        // 通过新增的流动性计算 amount0 和 amount1
        // 参考 UniswapV3 的代码
        bytes32 pid = positionId(
            params.owner,
            params.tickLower,
            params.tickUpper
        );
        Position storage position = positions[pid];

        if (position.liquidity == 0) {
            position.tickLower = params.tickLower;
            position.tickUpper = params.tickUpper;

            // 更新 tick 信息
            _updateTick(params.tickLower, params.liquidityDelta, false);
            _updateTick(params.tickUpper, params.liquidityDelta, true);
        } else {
            // 已有位置必须使用相同的价格区间
            require(
                position.tickLower == params.tickLower &&
                    position.tickUpper == params.tickUpper,
                "POSITION_TICK_RANGE_MISMATCH"
            );
        }
        amount0 = SqrtPriceMath.getAmount0Delta(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            params.liquidityDelta
        );

        amount1 = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(params.tickLower),
            sqrtPriceX96,
            params.liquidityDelta
        );

        // 提取手续费，计算从上一次提取到当前的手续费
        uint128 tokensOwed0 = uint128(
            FullMath.mulDiv(
                feeGrowthGlobal0X128 - position.feeGrowthInside0LastX128,
                position.liquidity,
                FixedPoint128.Q128
            )
        );
        uint128 tokensOwed1 = uint128(
            FullMath.mulDiv(
                feeGrowthGlobal1X128 - position.feeGrowthInside1LastX128,
                position.liquidity,
                FixedPoint128.Q128
            )
        );

        // 更新提取手续费的记录，同步到当前最新的 feeGrowthGlobal0X128，代表都提取完了
        position.feeGrowthInside0LastX128 = feeGrowthGlobal0X128;
        position.feeGrowthInside1LastX128 = feeGrowthGlobal1X128;
        // 把可以提取的手续费记录到 tokensOwed0 和 tokensOwed1 中
        // LP 可以通过 collect 来最终提取到用户自己账户上
        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            position.tokensOwed0 += tokensOwed0;
            position.tokensOwed1 += tokensOwed1;
        }

        // 更新全局流动性
        liquidity = LiquidityMath.addDelta(liquidity, params.liquidityDelta);
        position.liquidity = LiquidityMath.addDelta(
            position.liquidity,
            params.liquidityDelta
        );

        // 如果完全移除流动性，清理位置
        if (position.liquidity == 0) {
            _updateTick(position.tickLower, -int128(position.liquidity), false);
            _updateTick(position.tickUpper, -int128(position.liquidity), true);
            delete positions[pid];
        }
    }

    function _updateTick(
        int24 _tick,
        int128 liquidityDelta,
        bool isUpper
    ) private {
        TickInfo storage info = ticks[_tick];
        uint128 liquidityGrossBefore = info.liquidityGross;
        uint128 liquidityGrossAfter = LiquidityMath.addDelta(
            liquidityGrossBefore,
            liquidityDelta
        );

        // 翻转位图状态
        if (liquidityGrossBefore == 0) {
            // 初始化 tick
            TickBitmap.flipTick(tickBitmap, _tick, tickSpacing);
        }

        info.liquidityGross = liquidityGrossAfter;
        info.liquidityNet = isUpper
            ? info.liquidityNet - liquidityDelta
            : info.liquidityNet + liquidityDelta;

        // 清理空 tick
        if (liquidityGrossAfter == 0) {
            TickBitmap.flipTick(tickBitmap, _tick, tickSpacing);
        }
    }

    function positionId(
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) public pure returns (bytes32) {
        require(tickLower < tickUpper, "INVALID_TICK_RANGE");
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper));
    }

    function getPosition(
        address owner,
        int24 tickLower,
        int24 tickUpper
    )
        external
        view
        override
        returns (
            uint128 _liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        bytes32 pid = positionId(owner, tickLower, tickUpper);
        Position storage position = positions[pid];
        return (
            position.liquidity,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.tokensOwed0,
            position.tokensOwed1
        );
    }
}
