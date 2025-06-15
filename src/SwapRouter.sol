// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;
pragma abicoder v2;

import "./interfaces/ISwapRouter.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IPoolManager.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SwapRouter is ISwapRouter {
    IPoolManager public poolManager;

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    // 确定输入的 token 交易
    function exactInput(
        ExactInputParams calldata params
    ) external payable override returns (uint256 amountOut) {
        uint256 amountIn = params.amountIn;
        bool zeroForOne = params.tokenIn < params.tokenOut;

        // 直接获取池子地址（不再需要索引）
        address poolAddress = poolManager.getPool(
            params.tokenIn,
            params.tokenOut
        );
        require(poolAddress != address(0), "Pool not found");

        IPool pool = IPool(poolAddress);

        // 简化回调数据
        bytes memory data = abi.encode(
            params.tokenIn,
            params.tokenOut,
            params.recipient == address(0) ? address(0) : msg.sender,
            true
        );

        (int256 amount0, int256 amount1) = pool.swap(
            params.recipient,
            zeroForOne,
            int256(amountIn),
            params.sqrtPriceLimitX96,
            data
        );

        amountOut = uint256(zeroForOne ? -amount1 : -amount0);
        require(amountOut >= params.amountOutMinimum, "Slippage exceeded");

        emit Swap(msg.sender, zeroForOne, params.amountIn, 0, amountOut);
        return amountOut;
    }

    // 确定输出的 token 交易
    function exactOutput(
        ExactOutputParams calldata params
    ) external payable override returns (uint256 amountIn) {
        uint256 amountOut = params.amountOut;
        bool zeroForOne = params.tokenIn < params.tokenOut;

        // 直接获取池子地址
        address poolAddress = poolManager.getPool(
            params.tokenIn,
            params.tokenOut
        );
        require(poolAddress != address(0), "Pool not found");

        IPool pool = IPool(poolAddress);

        // 简化回调数据
        bytes memory data = abi.encode(
            params.tokenIn,
            params.tokenOut,
            params.recipient == address(0) ? address(0) : msg.sender,
            false
        );

        (int256 amount0, int256 amount1) = pool.swap(
            params.recipient,
            zeroForOne,
            -int256(amountOut),
            params.sqrtPriceLimitX96,
            data
        );

        amountIn = uint256(zeroForOne ? amount0 : amount1);
        require(amountIn <= params.amountInMaximum, "Slippage exceeded");

        emit Swap(msg.sender, zeroForOne, params.amountOut, 0, amountIn);
        return amountIn;
    }

    // 确认输入的 token，估算可以获得多少输出的 token
    function quoteExactInput(
        QuoteExactInputParams memory params
    ) external override returns (uint256 amountOut) {
        try
            this.exactInput(
                ExactInputParams({
                    tokenIn: params.tokenIn,
                    tokenOut: params.tokenOut,
                    recipient: address(0),
                    deadline: block.timestamp + 1 hours,
                    amountIn: params.amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96
                })
            )
        {} catch (bytes memory reason) {
            return parseRevertReason(reason);
        }
    }

    // 确认输出的 token，估算需要多少输入的 token
    function quoteExactOutput(
        QuoteExactOutputParams memory params
    ) external override returns (uint256 amountIn) {
        try
            this.exactOutput(
                ExactOutputParams({
                    tokenIn: params.tokenIn,
                    tokenOut: params.tokenOut,
                    recipient: address(0),
                    deadline: block.timestamp + 1 hours,
                    amountOut: params.amountOut,
                    amountInMaximum: type(uint256).max,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96
                })
            )
        {} catch (bytes memory reason) {
            return parseRevertReason(reason);
        }
    }

    function swapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        // 每次 swap 后 pool 会调用这个方法
        // 最后一次 swap 完成后这里统一把钱打给用户
        // transfer token
        (
            address tokenIn,
            address tokenOut,
            address payer,
            bool isExactInput
        ) = abi.decode(data, (address, address, address, bool));
        address _pool = poolManager.getPool(tokenIn, tokenOut);
        require(_pool == msg.sender, "Invalid callback caller");

        (uint256 amountToPay, uint256 amountReceived) = amount0Delta > 0
            ? (uint256(amount0Delta), uint256(-amount1Delta))
            : (uint256(amount1Delta), uint256(-amount0Delta));
        // payer 是 address(0)，这是一个用于预估 token 的请求（quoteExactInput or quoteExactOutput）
        // 参考代码 https://github.com/Uniswap/v3-periphery/blob/main/contracts/lens/Quoter.sol#L38
        if (payer == address(0)) {
            if (isExactInput) {
                // 指定输入情况下，抛出可以接收多少 token
                assembly {
                    let ptr := mload(0x40)
                    mstore(ptr, amountReceived)
                    revert(ptr, 32)
                }
            } else {
                // 指定输出情况下，抛出需要转入多少 token
                assembly {
                    let ptr := mload(0x40)
                    mstore(ptr, amountToPay)
                    revert(ptr, 32)
                }
            }
        }

        // 正常交易，转账给交易池
        if (amountToPay > 0) {
            IERC20(tokenIn).transferFrom(payer, _pool, amountToPay);
        }
    }

    /// @dev Parses a revert reason that should contain the numeric quote
    function parseRevertReason(
        bytes memory reason
    ) private pure returns (uint256) {
        if (reason.length != 32) {
            if (reason.length < 68) revert("Unexpected error");
            assembly {
                reason := add(reason, 0x04)
            }
            revert(abi.decode(reason, (string)));
        }
        return abi.decode(reason, (uint256));
    }
}
