// SPDX-License-Identifier: MIT

pragma solidity 0.8.15;
pragma abicoder v1;

import "../dexes/curve/interfaces/ICurveRegistry.sol";
import "../dexes/curve/interfaces/ICurvePool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IERC20Simple.sol";

contract CurveExtension {

    error ExcessiveInputAmount();

    function curveSwapStableAmountIn(
        address pool,
        IERC20 assetOut,
        int128 i,
        int128 j,
        address to,
        uint256 amountIn
	) external {
        // Some pools support to inside the exchange function
        if (to == address(this)) {
            ICurvePool(pool).exchange(i, j, amountIn, 0);
        } else {
            uint256 previousBalance = assetOut.balanceOf(address(this));
            ICurvePool(pool).exchange(i, j, amountIn, 0);
            uint256 exchangedAmount = assetOut.balanceOf(address(this)) - previousBalance;
            assetOut.transfer(to, exchangedAmount);
        }
	}

    function curveSwapStableAmountOut(
        address registry,
        address pool,
        IERC20 assetIn,
        IERC20 assetOut,
        int128 i,
        int128 j,
        uint256 fee,
        uint256 amountOut,
        uint256 maxSpendAmount,
        address to
	) external {
        // Some pools support to inside the exchange function
        uint256 amountIn = getAmountInStablePoolCurve(
            registry,
            pool,
            address(assetIn),
            address(assetOut),
            i,
            j,
            fee,
            amountOut
        );
        if (amountIn > maxSpendAmount) revert ExcessiveInputAmount();

        uint256 previousBalance = assetOut.balanceOf(address(this));
        ICurvePool(pool).exchange(i, j, amountIn, amountOut);
        uint256 exchangedAmount = assetOut.balanceOf(address(this)) - previousBalance;
        assetOut.transfer(to, amountOut);

        if (exchangedAmount > amountOut) {
            //deal with leftovers
        }

        if (maxSpendAmount > amountIn) {
            //deal with leftovers
        }
	}

    function curveSwapMetaAmountIn(
        address pool,
        IERC20 assetOut,
        int128 i,
        int128 j,
        uint256 amountIn,
        uint256 amountOut,
        address to
    ) external {
        uint256 previousBalance = assetOut.balanceOf(address(this));
        ICurvePool(pool).exchange_underlying(i, j, amountIn, amountOut);
        uint256 exchangedAmount = assetOut.balanceOf(address(this)) - previousBalance;
        assetOut.transfer(to, exchangedAmount);
    }

   	function get_D(uint256[] memory xp, uint256 amp) internal pure returns (uint256) {
		uint N_COINS = xp.length;
		uint256 S = 0;
		for (uint i; i < N_COINS; ++i) S += xp[i];
		if (S == 0) return 0;

		uint256 Dprev = 0;
		uint256 D = S;
		uint256 Ann = amp * N_COINS;
		for (uint _i; _i < 255; ++_i) {
			uint256 D_P = D;
			for (uint j; j < N_COINS; ++j) {
				D_P = (D_P * D) / (xp[j] * N_COINS); // If division by 0, this will be borked: only withdrawal will work. And that is good
			}
			Dprev = D;
			D = ((Ann * S + D_P * N_COINS) * D) / ((Ann - 1) * D + (N_COINS + 1) * D_P);
			// Equality with the precision of 1
			if (D > Dprev) {
				if (D - Dprev <= 1) break;
			} else {
				if (Dprev - D <= 1) break;
			}
		}
		return D;
	}

	function get_y(int128 i, int128 j, uint256 x, uint256[] memory xp_, uint256 amp) internal pure returns (uint256) {
		// x in the input is converted to the same price/precision
		uint N_COINS = xp_.length;
		require(i != j, "same coin");
		require(j >= 0, "j below zero");
		require(uint128(j) < N_COINS, "j above N_COINS");

		require(i >= 0, "i below zero");
		require(uint128(i) < N_COINS, "i above N_COINS");

		uint256 D = get_D(xp_, amp);
		uint256 c = D;
		uint256 S_ = 0;
		uint256 Ann = amp * N_COINS;

		uint256 _x = 0;
		for (uint _i; _i < N_COINS; ++_i) {
			if (_i == uint128(i)) _x = x;
			else if (_i != uint128(j)) _x = xp_[_i];
			else continue;
			S_ += _x;
			c = (c * D) / (_x * N_COINS);
		}
		c = (c * D) / (Ann * N_COINS);
		uint256 b = S_ + D / Ann; // - D
		uint256 y_prev = 0;
		uint256 y = D;
		for (uint _i; _i < 255; ++_i) {
			y_prev = y;
			y = (y * y + c) / (2 * y + b - D);
			// Equality with the precision of 1
			if (y > y_prev) {
				if (y - y_prev <= 1) break;
			} else {
				if (y_prev - y <= 1) break;
			}
		}
		return y;
	}

	function get_xp(address factory, address pool) internal view returns (uint256[] memory xp) {
		xp = new uint256[](MAX_COINS);

		address[MAX_COINS] memory coins;
		uint256[MAX_COINS] memory balances;
        coins = ICurveRegistry(factory).get_coins(pool);
        balances = ICurveRegistry(factory).get_balances(pool);

		uint i = 0;
		for (; i < balances.length; ++i) {
			if (balances[i] == 0) break;
			xp[i] = baseUnitToCurveDecimal(coins[i], balances[i]);
		}
		assembly {
			mstore(xp, sub(mload(xp), sub(MAX_COINS, i)))
		} // remove trail zeros from array
	}

	function getAmountInStablePoolCurve(
        address registry,
        address pool,
        address assetIn,
        address assetOut,
        int128 i,
        int128 j,
        uint256 fee,
		uint256 amount
	) internal view returns (uint256) {
		uint256[] memory xp = get_xp(registry, pool);

		uint256 x;
        uint256 A = ICurveRegistry(registry).get_A(pool);
        uint8 decimalsIn = IERC20Simple(assetIn).decimals();
        uint8 decimalsOut = IERC20Simple(assetOut).decimals();

        uint256 y = xp[uint128(j)] -
            (baseUnitToCurveDecimalPure(decimalsOut, (amount + 1)) * FEE_DENOMINATOR) /
            (FEE_DENOMINATOR - fee);
        x = get_y(j, i, y, xp, A);

		uint256 dx = curveDecimalToBaseUnitPure(decimalsIn, x - xp[uint128(i)]);
        if (decimalsIn < 18 && decimalsIn != decimalsOut) ++dx;

		return dx;
	}

    function baseUnitToCurveDecimal(address assetAddress, uint amount) internal view returns (uint256 result) {
		if (assetAddress == address(0)) {
			result = amount;
		} else {
			uint8 decimals = IERC20Simple(assetAddress).decimals();
			result = baseUnitToCurveDecimalPure(decimals, amount);
		}
	}

	function curveDecimalToBaseUnit(address assetAddress, uint amount) internal view returns (uint256 result) {
		if (assetAddress == address(0)) {
			result = amount; // 18 decimals
		} else {
			uint8 decimals = IERC20Simple(assetAddress).decimals();
			result = curveDecimalToBaseUnitPure(decimals, amount);
		}
	}

    function baseUnitToCurveDecimalPure(uint8 decimals, uint amount) internal pure returns (uint256 result) {
			result = amount * 10 ** 18 / 10 ** decimals;
	}

	function curveDecimalToBaseUnitPure(uint8 decimals, uint amount) internal pure returns (uint256 result) {
			result = amount * 10 ** decimals / 10 ** 18;
	}
}
