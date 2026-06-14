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

    modifier nonReentrant() {
        if (_gate == 2) revert TRF_Reentered();
        _gate = 2;
        _;
        _gate = 1;
    }

    modifier onlyDirector() {
        if (msg.sender != director) revert TRF_NotDirector();
        _;
    }

    modifier deskOpen() {
        if (deskFrozen) revert TRF_DeskFrozen();
        _;
    }

    constructor() {
        director = msg.sender;
        ADDRESS_A = 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0;
        ADDRESS_B = 0xb7e512AD32f868807707F07fedc11e2657F24613;
        ADDRESS_C = 0xd620df9F3BED1c900a12B45735ae8B854afbdfbc;
        bornAt = uint64(block.timestamp);
        _gate = 1;
        activeEpoch = 1;
    }

    receive() external payable {
        emit InboundWei(msg.sender, msg.value);
    }

    fallback() external payable {
        revert TRF_FallbackBlocked();
    }

    function setDeskFrozen(bool frozen) external onlyDirector {
        deskFrozen = frozen;
        emit DeskFreeze(frozen, uint64(block.timestamp));
    }

    function proposeDirector(address next) external onlyDirector {
        if (next == address(0)) revert TRF_ZeroAddr();
        if (next == director) revert TRF_SelfSeat();
        pendingDirector = next;
        emit DirectorProposed(director, next);
    }

    function acceptDirector() external {
        if (msg.sender != pendingDirector) revert TRF_PendingUnset();
        address prev = director;
        director = msg.sender;
        pendingDirector = address(0);
        emit DirectorAccepted(prev, msg.sender);
    }

    function setRateSlot(uint256 slot, uint256 benchmarkBps) external onlyDirector {
        if (benchmarkBps > TRF_MAX_MARGIN_BPS) revert TRF_RateHigh();
        rateSlotBps[slot] = benchmarkBps;
        emit RateSet(slot, benchmarkBps, uint64(block.timestamp));
    }

    function openDesk(uint256 epochId, uint256 carryBps, uint256 capWei) external onlyDirector returns (uint256 deskId) {
        if (epochId == 0) revert TRF_BadEpoch();
        if (carryBps > TRF_MAX_CARRY_BPS) revert TRF_RateHigh();
        if (capWei < 4 ether) revert TRF_StakeLow();
        deskId = ++deskSerial;
        YieldDesk storage d = desks[deskId];
        d.epochId = epochId;
        d.carryBps = carryBps;
        d.capWei = capWei;
        d.openedAt = uint64(block.timestamp);
        d.live = true;
        activeEpoch = epochId;
        emit Opened(epochId, carryBps, capWei, d.openedAt);
    }

    function toggleDesk(uint256 deskId, bool live) external onlyDirector {
        YieldDesk storage d = desks[deskId];
        if (d.epochId == 0) revert TRF_DeskMissing();
        d.live = live;
    }

    function stakeDesk(uint256 deskId) external payable deskOpen nonReentrant {
        if (msg.value == 0) revert TRF_ZeroWei();
        YieldDesk storage d = desks[deskId];
        if (d.epochId == 0) revert TRF_DeskMissing();
        if (!d.live) revert TRF_DeskOff();
        uint256 next = TrfGauge.safeAdd(d.totalStaked, msg.value, d.capWei);
        d.totalStaked = next;
        uint256 minted = msg.value;
        if (d.totalShares > 0) {
            minted = (msg.value * d.totalShares) / (d.totalStaked - msg.value);
            if (minted == 0) minted = 1;
        }
        minted = (minted * (TRF_BPS - d.carryBps)) / TRF_BPS;
        if (minted == 0) minted = 1;
        d.totalShares += minted;
        deskShares[deskId][msg.sender] += minted;
        _stakerEpochs[msg.sender].push(deskId);
        emit Staked(d.epochId, msg.sender, msg.value, minted);
    }

    function claimDesk(uint256 deskId, uint256 shareAmt) external deskOpen nonReentrant {
        if (shareAmt == 0) revert TRF_ZeroWei();
        YieldDesk storage d = desks[deskId];
        if (d.epochId == 0) revert TRF_DeskMissing();
        uint256 held = deskShares[deskId][msg.sender];
        if (held < shareAmt) revert TRF_StakeGone();
        uint256 gross = (shareAmt * d.totalStaked) / d.totalShares;
        uint256 payout = gross;
        if (address(this).balance < payout) revert TRF_SendFail();
        deskShares[deskId][msg.sender] = held - shareAmt;
        d.totalShares -= shareAmt;
        d.totalStaked -= gross;
        (bool ok,) = msg.sender.call{value: payout}("");
        if (!ok) revert TRF_SendFail();
        emit Claimed(d.epochId, msg.sender, shareAmt, payout);
    }

    function openLine(address borrower, uint256 limitWei, uint256 rateBps) external onlyDirector returns (uint256 lineId) {
        if (borrower == address(0)) revert TRF_ZeroAddr();
        if (limitWei == 0) revert TRF_ZeroWei();
        if (rateBps > TRF_MAX_MARGIN_BPS) revert TRF_RateHigh();
        lineId = ++lineSerial;
        MarginLine storage ln = lines[lineId];
        ln.lineId = lineId;
        ln.borrower = borrower;
        ln.limitWei = limitWei;
        ln.rateBps = rateBps;
        ln.openedAt = uint64(block.timestamp);
        ln.lastAccrual = ln.openedAt;
        _borrowerLines[borrower].push(lineId);
        emit LineOpened(lineId, borrower, limitWei, rateBps);
    }

    function haltLine(uint256 lineId, bool halted) external onlyDirector {
        MarginLine storage ln = lines[lineId];
        if (ln.lineId == 0) revert TRF_LineMissing();
        ln.halted = halted;
    }

    function postCollateral(uint256 lineId) external payable deskOpen nonReentrant {
        if (msg.value == 0) revert TRF_ZeroWei();
        MarginLine storage ln = lines[lineId];
        if (ln.lineId == 0) revert TRF_LineMissing();
        if (ln.halted) revert TRF_LineHalted();
        if (msg.sender != ln.borrower) revert TRF_NotBorrower();
        ln.collateralWei += msg.value;
        emit CollateralPosted(lineId, msg.sender, msg.value);
    }

    function drawLine(uint256 lineId, uint256 weiOut) external deskOpen nonReentrant {
        if (weiOut == 0) revert TRF_ZeroWei();
        MarginLine storage ln = lines[lineId];
        if (ln.lineId == 0) revert TRF_LineMissing();
        if (ln.halted) revert TRF_LineHalted();
        if (msg.sender != ln.borrower) revert TRF_NotBorrower();
        _accrueLine(ln);
        if (ln.borrowedWei + weiOut > ln.limitWei) revert TRF_LimitHit();
        uint256 health = TrfGauge.healthBps(ln.collateralWei, ln.borrowedWei + weiOut, TRF_MIN_COLLATERAL);
        if (health < TRF_LIQ_BAND_BPS) revert TRF_HealthLow();
        if (address(this).balance < weiOut) revert TRF_SendFail();
        ln.borrowedWei += weiOut;
        (bool ok,) = msg.sender.call{value: weiOut}("");
        if (!ok) revert TRF_SendFail();
        emit Drawn(lineId, msg.sender, weiOut);
    }

    function repayLine(uint256 lineId) external payable deskOpen nonReentrant {
        if (msg.value == 0) revert TRF_ZeroWei();
        MarginLine storage ln = lines[lineId];
        if (ln.lineId == 0) revert TRF_LineMissing();
        _accrueLine(ln);
        uint256 interest = TrfGauge.mulBps(ln.borrowedWei, ln.rateBps);
        uint256 owed = ln.borrowedWei + interest;
        uint256 pay = msg.value > owed ? owed : msg.value;
        uint256 principal = pay > interest ? pay - interest : 0;
        if (principal > ln.borrowedWei) principal = ln.borrowedWei;
        ln.borrowedWei -= principal;
        emit Repaid(lineId, msg.sender, principal, pay - principal);
    }

    function liquidateLine(uint256 lineId) external deskOpen nonReentrant {
        MarginLine storage ln = lines[lineId];
        if (ln.lineId == 0) revert TRF_LineMissing();
        _accrueLine(ln);
        uint256 health = TrfGauge.healthBps(ln.collateralWei, ln.borrowedWei, TRF_MIN_COLLATERAL);
        if (health >= TRF_LIQ_BAND_BPS) revert TRF_NotLiquidatable();
        uint256 seized = ln.collateralWei;
        ln.collateralWei = 0;
        ln.borrowedWei = 0;
        ln.halted = true;
        if (seized > 0) {
            (bool ok,) = msg.sender.call{value: seized}("");
            if (!ok) revert TRF_SendFail();
        }
        emit Liquidated(lineId, msg.sender, seized);
    }

    function issueTranche(uint256 tenorDays, uint256 couponBps) external payable deskOpen nonReentrant returns (uint256 noteId) {
        if (msg.value == 0) revert TRF_ZeroWei();
        if (tenorDays == 0 || tenorDays > 3650) revert TRF_BadEpoch();
        if (couponBps > TRF_MAX_COUPON_BPS) revert TRF_RateHigh();
        noteId = ++noteSerial;
        TrancheNote storage n = notes[noteId];
        n.noteId = noteId;
        n.holder = msg.sender;
        n.faceWei = msg.value;
        n.couponBps = couponBps;
        n.issuedAt = uint64(block.timestamp);
        n.maturesAt = n.issuedAt + uint64(tenorDays * 1 days);
        emit TrancheIssued(noteId, tenorDays, couponBps, msg.value);
    }

    function redeemTranche(uint256 noteId) external deskOpen nonReentrant {
        TrancheNote storage n = notes[noteId];
        if (n.noteId == 0) revert TRF_TrancheMissing();
        if (n.redeemed) revert TRF_TrancheOpen();
        if (block.timestamp < n.maturesAt) revert TRF_TrancheMature();
        if (msg.sender != n.holder) revert TRF_NotBorrower();
        n.redeemed = true;
        uint256 coupon = TrfGauge.mulBps(n.faceWei, n.couponBps);
        uint256 payout = n.faceWei;
        if (address(this).balance >= n.faceWei + coupon) {
            payout += coupon;
        }
        if (address(this).balance < payout) revert TRF_SendFail();
        (bool ok,) = msg.sender.call{value: payout}("");
        if (!ok) revert TRF_SendFail();
        emit Redeemed(noteId, msg.sender, payout);
    }

    function openLane(address partyB, uint256 capWei) external onlyDirector returns (uint256 laneId) {
        if (partyB == address(0)) revert TRF_ZeroAddr();
        if (capWei == 0) revert TRF_ZeroWei();
        laneId = ++laneSerial;
        SettlementLane storage ln = lanes[laneId];
        ln.laneId = laneId;
        ln.partyA = ADDRESS_A;
        ln.partyB = partyB;
        ln.capWei = capWei;
        emit LaneOpened(laneId, ln.partyA, partyB, capWei);
    }

    function pauseLane(uint256 laneId, bool paused) external onlyDirector {
        SettlementLane storage ln = lanes[laneId];
        if (ln.laneId == 0) revert TRF_LaneMissing();
        ln.paused = paused;
    }

    function postSettlement(uint256 laneId, bytes32 tag) external payable deskOpen nonReentrant {
        if (msg.value == 0) revert TRF_ZeroWei();
        SettlementLane storage ln = lanes[laneId];
        if (ln.laneId == 0) revert TRF_LaneMissing();
        if (ln.paused) revert TRF_LanePaused();
        if (msg.sender != ln.partyA && msg.sender != ln.partyB) revert TRF_Counterparty();
        ln.movedWei = TrfGauge.safeAdd(ln.movedWei, msg.value, ln.capWei);
        emit Settled(laneId, tag, msg.value, msg.sender);
    }

    function _accrueLine(MarginLine storage ln) internal {
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs <= ln.lastAccrual) return;
        ln.lastAccrual = nowTs;
    }

    function deskDigest(uint256 deskId) external view returns (bytes32) {
        YieldDesk storage d = desks[deskId];
        bytes32 hA = keccak256(abi.encode(d.epochId, d.carryBps, d.capWei, d.totalStaked));
        bytes32 hB = keccak256(abi.encode(d.totalShares, d.openedAt, d.live, TRF_DOMAIN_SALT));
        return keccak256(abi.encodePacked(hA, hB));
    }

    function lineDigest(uint256 lineId) external view returns (bytes32) {
        MarginLine storage ln = lines[lineId];
        bytes32 hA = keccak256(abi.encode(ln.borrower, ln.collateralWei, ln.borrowedWei));
        bytes32 hB = keccak256(abi.encode(ln.limitWei, ln.rateBps, ln.halted, ln.lastAccrual));
        return keccak256(abi.encodePacked(hA, hB));
    }

    function seatFingerprint() external view returns (bytes32) {
        bytes32 hA = keccak256(abi.encode(ADDRESS_A, ADDRESS_B, bornAt));
        bytes32 hB = keccak256(abi.encode(ADDRESS_C, activeEpoch, deskSerial));
        return keccak256(abi.encodePacked(hA, hB));
    }

    function _bootDesk_1() private {
        deskSerial = 1;
        YieldDesk storage d = desks[1];
        d.epochId = 1;
        d.carryBps = 392;
        d.capWei = 21.3 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(1, 392, 21.3 ether, bornAt);
    }

    function _bootDesk_2() private {
        deskSerial = 2;
        YieldDesk storage d = desks[2];
        d.epochId = 2;
        d.carryBps = 406;
        d.capWei = 42.8 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(2, 406, 42.8 ether, bornAt);
    }

    function _bootDesk_3() private {
        deskSerial = 3;
        YieldDesk storage d = desks[3];
        d.epochId = 3;
        d.carryBps = 302;
        d.capWei = 49.6 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(3, 302, 49.6 ether, bornAt);
    }

