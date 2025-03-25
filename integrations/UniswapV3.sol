// SPDX-License-Identifier: MIT

pragma solidity 0.8.15;
pragma abicoder v1;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IUniswapV3SwapCallback.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract UniswapV3Extension {
    using Address for address payable;
    using SafeERC20 for IERC20;

    error EmptyPools();
    error BadPool();
    error ReturnAmountIsNotEnough();
    error InvalidMsgValue();

    uint256 private constant _ONE_FOR_ZERO_MASK = 1 << 255;
    uint256 private constant _WETH_UNWRAP_MASK = 1 << 253;
    uint160 private constant _MIN_SQRT_RATIO = 4295128739 + 1;
    uint160 private constant _MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342 - 1;
    IWETH private immutable _WETH;  // solhint-disable-line var-name-mixedcase

    constructor(IWETH weth) {
        _WETH = weth;
    }

    /// @notice Same as `uniswapV3SwapTo` but uses `msg.sender` as recipient
    /// @param pools Pools chain used for swaps. Pools src and dst tokens should match to make swap happen
    /// @param amount Amount of source tokens to swap
    function uniswapV3Swap(
        uint256[] calldata pools,
        uint256 amount
    ) external payable returns(uint256 returnAmount) {
        return _uniswapV3Swap(pools, payable(msg.sender), amount);
    }

    /// @notice Performs swap using Uniswap V3 exchange. Wraps and unwraps ETH if required.
    /// Sending non-zero `msg.value` for anything but ETH swaps is prohibited
    /// @param pool Pool swap
    /// @param recipient Address that will receive swap funds
    /// @param amount Amount of source tokens to swap
    function uniswapV3SingleSwapTo(
        uint256 pool,
        address payable recipient,
        uint256 amount
    ) external payable returns(uint256 returnAmount) {
        uint256[] memory pools = new uint256[](1);
        pools[0] = pool;
        return _uniswapV3Swap(pools, recipient, amount);
    }

    /// @notice Performs swap using Uniswap V3 exchange. Wraps and unwraps ETH if required.
    /// Sending non-zero `msg.value` for anything but ETH swaps is prohibited
    /// @param pools Pools chain used for swaps. Pools src and dst tokens should match to make swap happen
    /// @param recipient Address that will receive swap funds
    /// @param amount Amount of source tokens to swap
    function uniswapV3SwapTo(
        uint256[] calldata pools,
        address payable recipient,
        uint256 amount
    ) external payable returns(uint256 returnAmount) {
        return _uniswapV3Swap(pools, recipient, amount);
    }

    function _uniswapV3Swap(
        uint256[] memory pools,
        address payable recipient,
        uint256 amount
    ) private returns(uint256 returnAmount) {
        unchecked {
            uint256 len = pools.length;
            if (len == 0) revert EmptyPools();
            uint256 lastIndex = len - 1;
            returnAmount = amount;
            bool wrapWeth = msg.value > 0;
            bool unwrapWeth = pools[lastIndex] & _WETH_UNWRAP_MASK > 0;
            if (wrapWeth) {
                if (msg.value != amount) revert InvalidMsgValue();
                _WETH.deposit{value: amount}();
            }
            if (len > 1) {
                returnAmount = _makeSwap(address(this), wrapWeth ? address(this) : msg.sender, pools[0], returnAmount);

                for (uint256 i = 1; i < lastIndex; i++) {
                    returnAmount = _makeSwap(address(this), address(this), pools[i], returnAmount);
                }
                returnAmount = _makeSwap(unwrapWeth ? address(this) : recipient, address(this), pools[lastIndex], returnAmount);
            } else {
                returnAmount = _makeSwap(unwrapWeth ? address(this) : recipient, wrapWeth ? address(this) : msg.sender, pools[0], returnAmount);
            }

            if (unwrapWeth) {
                _WETH.withdraw(returnAmount);
                recipient.sendValue(returnAmount);
            }
        }
    }


    function _makeSwap(address recipient, address payer, uint256 pool, uint256 amount) private returns (uint256) {
        bool zeroForOne = pool & _ONE_FOR_ZERO_MASK == 0;
        if (zeroForOne) {
            (, int256 amount1) = IUniswapV3Pool(address(uint160(pool))).swap(
                recipient,
                zeroForOne,
                SafeCast.toInt256(amount),
                _MIN_SQRT_RATIO,
                abi.encode(payer)
            );
            return SafeCast.toUint256(-amount1);
        } else {
            (int256 amount0,) = IUniswapV3Pool(address(uint160(pool))).swap(
                recipient,
                zeroForOne,
                SafeCast.toInt256(amount),
                _MAX_SQRT_RATIO,
                abi.encode(payer)
            );
            return SafeCast.toUint256(-amount0);
        }
    }
}
