// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Trafius — cross-epoch treasury routing and margin underwriting desk.
/// @dev codename: copper tenor / relay shelf four

interface IERC20Trf {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

library TrfGauge {
    error TRF_GaugeOverflow();
    uint256 internal constant BPS = 10_000;
    function mulBps(uint256 amt, uint256 bps) internal pure returns (uint256) {
        unchecked { return (amt * bps) / BPS; }
    }
    function safeAdd(uint256 a, uint256 b, uint256 cap) internal pure returns (uint256) {
        unchecked {
            uint256 s = a + b;
            if (s < a || s > cap) revert TRF_GaugeOverflow();
            return s;
        }
    }
    function healthBps(uint256 collateral, uint256 debt, uint256 floorWei) internal pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        uint256 backing = collateral + floorWei;
        unchecked { return (backing * BPS) / debt; }
    }
}

contract Trafius {
    error TRF_NotDirector();
    error TRF_DeskFrozen();
    error TRF_ZeroAddr();
    error TRF_ZeroWei();
    error TRF_Reentered();
    error TRF_DeskMissing();
    error TRF_DeskOff();
    error TRF_CapHit();
    error TRF_StakeLow();
    error TRF_StakeGone();
    error TRF_LineMissing();
    error TRF_LineHalted();
    error TRF_NotBorrower();
    error TRF_LimitHit();
    error TRF_HealthLow();
    error TRF_NotLiquidatable();
    error TRF_TrancheMissing();
    error TRF_TrancheMature();
    error TRF_TrancheOpen();
    error TRF_LaneMissing();
    error TRF_LanePaused();
    error TRF_Counterparty();
    error TRF_RateHigh();
    error TRF_BatchWide();
    error TRF_SizeMismatch();
    error TRF_SendFail();
    error TRF_FallbackBlocked();
    error TRF_PendingUnset();
    error TRF_SelfSeat();
    error TRF_BadEpoch();
    error TRF_ArrayEmpty();

    event Opened(uint256 indexed epochId, uint256 carryBps, uint256 capWei, uint64 at);
    event Staked(uint256 indexed epochId, address indexed staker, uint256 weiIn, uint256 shares);
    event Claimed(uint256 indexed epochId, address indexed staker, uint256 shares, uint256 weiOut);
    event LineOpened(uint256 indexed lineId, address indexed borrower, uint256 limitWei, uint256 rateBps);
    event CollateralPosted(uint256 indexed lineId, address indexed borrower, uint256 weiIn);
    event Drawn(uint256 indexed lineId, address indexed borrower, uint256 weiOut);
    event Repaid(uint256 indexed lineId, address indexed payer, uint256 principal, uint256 interest);
    event Liquidated(uint256 indexed lineId, address indexed keeper, uint256 seized);
    event TrancheIssued(uint256 indexed noteId, uint256 tenorDays, uint256 couponBps, uint256 faceWei);
    event Redeemed(uint256 indexed noteId, address indexed holder, uint256 payout);
    event LaneOpened(uint256 indexed laneId, address indexed partyA, address indexed partyB, uint256 cap);
    event Settled(uint256 indexed laneId, bytes32 tag, uint256 weiMoved, address indexed poster);
    event RateSet(uint256 indexed slot, uint256 benchmarkBps, uint64 at);
    event DeskFreeze(bool frozen, uint64 at);
    event DirectorProposed(address indexed current, address indexed pending);
