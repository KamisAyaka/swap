// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "./libraries/SqrtPriceMath.sol";
import "./libraries/TickMath.sol";
import "./libraries/LiquidityMath.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/SwapMath.sol";
import "./libraries/FixedPoint128.sol";

import "./interfaces/IPool.sol";
import "./interfaces/IFactory.sol";

contract Pool is IPool {
    using SafeCast for uint256;
    using LowGasSafeMath for int256;
    using LowGasSafeMath for uint256;

    /// @inheritdoc IPool
    address public immutable override factory;
    /// @inheritdoc IPool
    address public immutable override token0;
    /// @inheritdoc IPool
    address public immutable override token1;
    /// @inheritdoc IPool
    uint24 public immutable override fee;
    /// @inheritdoc IPool
    uint160 public override sqrtPriceX96;
    /// @inheritdoc IPool
    int24 public override tick;
    /// @inheritdoc IPool
    uint128 public override liquidity;

    /// @inheritdoc IPool
    uint256 public override feeGrowthGlobal0X128;
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
        (factory, token0, token1, fee) = IFactory(msg.sender).parameters();
        // 初始化 tick 边界
        _flipTick(TickMath.MIN_TICK);
        _flipTick(TickMath.MAX_TICK);
    }

    function initialize(uint160 sqrtPriceX96_) external override {
        // 初始化 Pool 的 sqrtPriceX96
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function positionId(
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) public pure returns (bytes32) {
        require(tickLower < tickUpper, "INVALID_TICK_RANGE");
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper));
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
                tickLower: tickLower, // 补充参数
                tickUpper: tickUpper // 补充参数
            })
        );
        // 获取燃烧后的 amount0 和 amount1
        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            positions[pid].tokensOwed0 += uint128(amount0); // 修复行
            positions[pid].tokensOwed1 += uint128(amount1); // 修复行
        }

        emit Burn(msg.sender, amount, amount0, amount1);
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
            int24 nextTick = _nextInitializedTick(zeroForOne);
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

            if (exactInput) {
                state.amountSpecifiedRemaining -= (stepAmountIn + stepFeeAmount)
                    .toInt256();
                state.amountCalculated -= stepAmountOut.toInt256();
            } else {
                state.amountSpecifiedRemaining += stepAmountOut.toInt256();
                state.amountCalculated += (stepAmountIn + stepFeeAmount)
                    .toInt256();
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

        // 计算交易后用户手里的 token0 和 token1 的数量
        if (exactInput) {
            state.amountSpecifiedRemaining -= (state.amountIn + state.feeAmount)
                .toInt256();
            state.amountCalculated = state.amountCalculated.sub(
                state.amountOut.toInt256()
            );
        } else {
            state.amountSpecifiedRemaining += state.amountOut.toInt256();
            state.amountCalculated = state.amountCalculated.add(
                (state.amountIn + state.feeAmount).toInt256()
            );
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

    function _nextInitializedTick(
        bool zeroForOne
    ) private view returns (int24 next) {
        int24 currentTick = tick;

        if (zeroForOne) {
            // 向下查找：从当前 tick 开始向左
            (int16 wordPos, uint8 bitPos) = _position(currentTick);
            uint256 mask = (1 << bitPos) - 1; // 当前位左侧的位

            // 在当前 word 中查找
            uint256 masked = tickBitmap[wordPos] & mask;
            if (masked != 0) {
                next = _nextTickInWord(masked, wordPos, true);
                return next;
            }

            // 在左侧 word 中查找
            while (wordPos-- > type(int16).min) {
                masked = tickBitmap[wordPos];
                if (masked != 0) {
                    next = _nextTickInWord(masked, wordPos, true);
                    return next;
                }
            }
        } else {
            // 向上查找：从当前 tick 开始向右
            (int16 wordPos, uint8 bitPos) = _position(currentTick);
            uint256 mask = ~((1 << bitPos) - 1); // 当前位右侧的位

            // 在当前 word 中查找
            uint256 masked = tickBitmap[wordPos] & mask;
            if (masked != 0) {
                next = _nextTickInWord(masked, wordPos, false);
                return next;
            }

            // 在右侧 word 中查找
            while (wordPos++ < type(int16).max) {
                masked = tickBitmap[wordPos];
                if (masked != 0) {
                    next = _nextTickInWord(masked, wordPos, false);
                    return next;
                }
            }
        }

        // 未找到，返回边界值
        return zeroForOne ? TickMath.MIN_TICK : TickMath.MAX_TICK;
    }

    // ===== 辅助函数 =====
    function _position(
        int24 _tick
    ) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(_tick >> 8);
        // 修复: 先转为 uint24 再取低 8 位
        bitPos = uint8(uint24(_tick) & 0xFF);
    }

    function _nextTickInWord(
        uint256 word,
        int16 wordPos,
        bool lte
    ) private pure returns (int24 next) {
        if (lte) {
            // 最右侧的 1 位（向下查找）
            uint8 bitPos = _mostSignificantBit(word);
            // 修复：添加 uint24 中间转换
            next = (int24(wordPos) << 8) | int24(uint24(bitPos));
        } else {
            // 最左侧的 1 位（向上查找）
            uint8 bitPos = _leastSignificantBit(word);
            // 修复：添加 uint24 中间转换
            next = (int24(wordPos) << 8) | int24(uint24(bitPos));
        }
    }

    // 查找最右侧的 1 位（MSB）
    function _mostSignificantBit(uint256 x) private pure returns (uint8 r) {
        require(x > 0);
        if (x >= 0x100000000000000000000000000000000) {
            x >>= 128;
            r += 128;
        }
        // ... 类似 Uniswap 的位操作实现 ...
    }

    // 查找最左侧的 1 位（LSB）
    function _leastSignificantBit(uint256 x) private pure returns (uint8 r) {
        require(x > 0);
        if (x & 0xffffffffffffffffffffffffffffffff == 0) {
            x >>= 128;
            r += 128;
        }
        // ... 类似 Uniswap 的位操作实现 ...
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
            _flipTick(_tick);
        }

        info.liquidityGross = liquidityGrossAfter;
        info.liquidityNet = isUpper
            ? info.liquidityNet - liquidityDelta
            : info.liquidityNet + liquidityDelta;

        // 清理空 tick
        if (liquidityGrossAfter == 0) {
            _flipTick(_tick);
        }
    }

    function _flipTick(int24 _tick) private {
        int16 wordPos = int16(_tick >> 8);
        // 修复: 先转为 uint24 再取低 8 位
        uint8 bitPos = uint8(uint24(_tick) & 0xFF);
        uint256 mask = 1 << bitPos;
        tickBitmap[wordPos] ^= mask;
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
