// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import "../integrations/gmx/IVault.sol";
import "../integrations/gmx/IRewardRouterV2.sol";
import "../integrations/gmx/IGlpManager.sol";
import "./BaseBuildingBlock.sol";
import "../interfaces/buildingBlocks/IGmxVault.sol";

/**
 * @title GMX DEX interface
 */
contract GmxVault is BaseBuildingBlock, IGmxVault {
    IVault public gmxVault;
    IRewardRouterV2 public mintRouter;
    IRewardRouterV2 public rewardRouter;
    IGlpManager public glpManager;
    IERC20 public glpToken;
    IERC20 public glpTrackerToken;

    function initialize(bytes memory _data) public initializer {
        (
            IGlpManager glpManagerAddress,
            IRewardRouterV2 mintRouterAddress,
            IRewardRouterV2 rewardRouterAddress,
            address relayerAddress,
            uint16 nativeId,
            IERC20 usdcToken,
            address dcNativeRouter
        ) = abi.decode(
                _data,
                (
                    IGlpManager,
                    IRewardRouterV2,
                    IRewardRouterV2,
                    address,
                    uint16,
                    IERC20,
                    address
                )
            );

        require(
            address(glpManagerAddress) != address(0),
            "GMX Vault::initialize::zero glpManager address"
        );
        require(
            address(mintRouterAddress) != address(0),
            "GMX Vault::initialize::zero mintRouter address"
        );
        require(
            address(rewardRouterAddress) != address(0),
            "GMX Vault::initialize::zero rewardRouter address"
        );
        require(
            address(relayerAddress) != address(0),
            "GMX Vault::initialize::zero relayer address"
        );
        require(nativeId > 0, "GMX Vault::initialize::zero native id");
        require(
            address(usdcToken) != address(0),
            "GMX Vault::initialize::zero usdc address"
        );
        require(
            dcNativeRouter != address(0),
            "GMX Vault::initialize::zero dcNativeRouter address"
        );
        __Ownable_init();
        _transferOwnership(_msgSender());

        nativeChainId = nativeId;
        nativeRouter = dcNativeRouter;
        currentUSDCToken = address(usdcToken);
        relayerAddress = relayerAddress;
        rewardRouter = rewardRouterAddress;
        mintRouter = mintRouterAddress;
        glpManager = glpManagerAddress;
        gmxVault = IVault(glpManager.vault());
        glpToken = IERC20(mintRouter.glp());
        glpTrackerToken = IERC20(mintRouter.stakedGlpTracker());
    }

    /**
     * @notice buy GLP, mint and stake
     * @dev token : the token to buy GLP with
     * @dev amount : the amount of token to use for the purchase
     * @dev minUsdg : the minimum acceptable USD value of the GLP purchased // do we calculate on chain or off?
     * @dev minGlp : the minimum acceptable GLP amount
     * @dev Rewards router and GLP manager spent must be approved before
     * @dev glpTrackerToken is 1:1 ratio with glp token
     * @dev access restricted to only self base building block call
     **/
    function buyGLP(
        IERC20 token,
        uint256 amount,
        uint256 minUsdg,
        uint256 minGlp
    ) public override onlyRelayer returns (uint256 glpBoughtAmount) {
        require(amount > 0, "GMX Vault::buyGLP::zero amount");
        if (address(token) == address(0x0)) {
            require(
                address(this).balance >= amount,
                "GMX Vault::buyGLP::bridge or deposit native currency"
            );
            glpBoughtAmount = mintRouter.mintAndStakeGlpETH{value: amount}(
                minUsdg,
                minGlp
            );
        } else {
            // check for balance to buy with
            require(
                token.balanceOf(address(this)) >= amount,
                "GMX Vault::buyGLP::bridge or deposit assets"
            );

            // approve to void contracts is necessary
            token.approve(address(mintRouter), amount);
            token.approve(address(glpManager), amount);

            // get GLP balance after buying
            uint256 glpBalanceBefore = glpTrackerToken.balanceOf(address(this));
            // // buy Glp
            glpBoughtAmount = mintRouter.mintAndStakeGlp(
                address(token), // the token to buy GLP with
                amount, // the amount of token to use for the purchase
                minUsdg, // the minimum acceptable USD value of the GLP purchased
                minGlp // minimum acceptable GLP amount
            );
            // check glp balance after buying
            uint256 glpBalanceAfter = glpTrackerToken.balanceOf(address(this));

            require(
                glpBalanceBefore + glpBoughtAmount <= glpBalanceAfter,
                "GMX Vault::buyGLP::glp buying failed"
            );
        }
        emit BuyingEvent(token, amount, glpBoughtAmount);
    }

    /**
     *   @notice Sell / unstake and redeem GLP
     *   @dev tokenOut : the token to sell GLP for
     *   @dev glpAmount : the amount of GLP to sell
     *   @dev minOut : the minimum acceptable amount of tokenOut to be received
     *   @return amountPayed payed for the sell
     *   @dev access restricted to only self base building block call
     * */
    function sellGLP(
        IERC20 tokenOut,
        uint256 glpAmount,
        uint256 minOut
    ) public override onlyRelayer returns (uint256 amountPayed) {
        if (address(tokenOut) == address(0x0)) {
            amountPayed = mintRouter.unstakeAndRedeemGlpETH(
                glpAmount,
                minOut,
                payable(address(this))
            );
        } else {
            // unstake And Redeem Glp
            uint256 tokenOutBalanceBefore = tokenOut.balanceOf(address(this));
            amountPayed = mintRouter.unstakeAndRedeemGlp(
                address(tokenOut),
                glpAmount,
                minOut,
                address(this)
            );
            // get contract balance after selling
            uint256 tokenOutBalanceAfter = tokenOut.balanceOf(address(this));

            // get balance change
            uint256 balanceChange = tokenOutBalanceAfter -
                tokenOutBalanceBefore;

            // check if vault balance reflects the sale
            require(
                balanceChange >= amountPayed,
                "GMX Vault::sellGLP::glp selling failed"
            );
        }

        emit SellingEvent(tokenOut, glpAmount, amountPayed);
        return amountPayed;
    }

    /**
     *  @notice Trigger rewards compounding and claims them
     *  @dev _shouldClaimGmx boolean yes/no
     *  @dev _shouldStakeGmx boolean yes/no
     *  @dev _shouldClaimEsGmx boolean yes/no
     *  @dev _shouldStakeEsGmx boolean yes/no
     *  @dev _shouldStakeMultiplierPoints boolean yes/no
     *  @dev _shouldClaimWeth boolean yes/no
     *  @dev _shouldConvertWethToEth boolean yes/no
     *  @dev 15 average min cool down time
     *   @dev access restricted to only self base building block call
     */
    function claimRewards(
        bool shouldClaimGmx,
        bool shouldStakeGmx,
        bool shouldClaimEsGmx,
        bool shouldStakeEsGmx,
        bool shouldStakeMultiplierPoints,
        bool shouldClaimWeth,
        bool shouldConvertWethToEth
    ) public override onlyRelayer returns (bool) {
        rewardRouter.handleRewards(
            shouldClaimGmx,
            shouldStakeGmx,
            shouldClaimEsGmx,
            shouldStakeEsGmx,
            shouldStakeMultiplierPoints,
            shouldClaimWeth,
            shouldConvertWethToEth
        );
        return true;
    }

    function getTvl() external view override returns (uint256) {
        uint256 glpPrice = (glpManager.getAumInUsdg(true) * 1e18) /
            glpToken.totalSupply();
        uint256 fsGlpAmount = glpTrackerToken.balanceOf(address(this));
        return (fsGlpAmount * glpPrice) / 1e18;
    }

    /**
     * @notice Calculate asset pool weight of glp index on USD
     * @param _assets list of glp index tokens
     * @return list of token pool weights in usd
     */
    function getWeights(address[] calldata _assets)
        external
        view
        override
        returns (uint256[] memory)
    {
        uint256[] memory aums = new uint256[](_assets.length);
        uint256 sum = glpManager.getAum(true);

        for (uint256 i; i < _assets.length; i++) {
            require(
                _assets[i] != address(0),
                "GMX Vault::getWeights::zero asset"
            );
            uint256 price = gmxVault.getMaxPrice(_assets[i]);
            uint256 poolAmount = gmxVault.poolAmounts(_assets[i]);
            uint256 decimals = gmxVault.tokenDecimals(_assets[i]);

            if (gmxVault.stableTokens(_assets[i])) {
                aums[i] = (poolAmount * price) / (10**decimals);
            } else {
                aums[i] = gmxVault.guaranteedUsd(_assets[i]);
                uint256 reservedAmount = gmxVault.reservedAmounts(_assets[i]);
                aums[i] +=
                    ((poolAmount - reservedAmount) * price) /
                    (10**decimals);

                uint256 size = gmxVault.globalShortSizes(_assets[i]);
                if (size > 0) {
                    (uint256 delta, bool hasProfit) = glpManager
                        .getGlobalShortDelta(_assets[i], price, size);
                    if (!hasProfit) {
                        aums[i] += delta;
                    } else {
                        aums[i] -= delta;
                    }
                }
            }
            aums[i] = (aums[i] * 1e18) / sum;
        }
        return aums;
    }
}
