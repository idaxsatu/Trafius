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
    event DirectorAccepted(address indexed previous, address indexed newDirector);
    event InboundWei(address indexed from, uint256 amount);
    event Pulse_0(uint256 indexed serial, uint256 meta, uint64 at);
    event Pulse_1(uint256 indexed serial, uint256 meta, uint64 at);
    event Pulse_2(uint256 indexed serial, uint256 meta, uint64 at);
    event Pulse_3(uint256 indexed serial, uint256 meta, uint64 at);
    event Pulse_4(uint256 indexed serial, uint256 meta, uint64 at);

    uint256 public constant TRF_BPS = 10000;
    uint256 public constant TRF_MAX_CARRY_BPS = 949;
    uint256 public constant TRF_MAX_MARGIN_BPS = 2520;
    uint256 public constant TRF_MAX_COUPON_BPS = 752;
    uint256 public constant TRF_MIN_COLLATERAL = 0.06 ether;
    uint256 public constant TRF_LIQ_BAND_BPS = 1345;
    bytes32 public constant TRF_DOMAIN_SALT = 0x7f12a99de5c2b66e18859fcaff32b4b8d3493cb8eaaad8c9a8702030347e4acf;

    address public director;
    address public immutable ADDRESS_A;
    address public immutable ADDRESS_B;
    address public immutable ADDRESS_C;
    uint64 public immutable bornAt;
    address public pendingDirector;
    bool public deskFrozen;
    uint256 private _gate;
    uint256 public deskSerial;
    uint256 public lineSerial;
    uint256 public noteSerial;
    uint256 public laneSerial;
    uint256 public pulseSerial;
    uint256 public activeEpoch;

    struct YieldDesk {
        uint256 epochId;
        uint256 carryBps;
        uint256 capWei;
        uint256 totalStaked;
        uint256 totalShares;
        uint64 openedAt;
        bool live;
    }

    struct MarginLine {
        uint256 lineId;
        address borrower;
        uint256 collateralWei;
        uint256 borrowedWei;
        uint256 limitWei;
        uint256 rateBps;
        uint64 openedAt;
        uint64 lastAccrual;
        bool halted;
    }

    struct TrancheNote {
        uint256 noteId;
        address holder;
        uint256 faceWei;
        uint256 couponBps;
        uint64 issuedAt;
        uint64 maturesAt;
        bool redeemed;
    }

    struct SettlementLane {
        uint256 laneId;
        address partyA;
        address partyB;
        uint256 capWei;
        uint256 movedWei;
        bool paused;
    }

    mapping(uint256 => YieldDesk) public desks;
    mapping(uint256 => mapping(address => uint256)) public deskShares;
    mapping(uint256 => MarginLine) public lines;
    mapping(uint256 => TrancheNote) public notes;
    mapping(uint256 => SettlementLane) public lanes;
    mapping(uint256 => uint256) public rateSlotBps;
    mapping(address => uint256[]) private _stakerEpochs;
    mapping(address => uint256[]) private _borrowerLines;
