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

    function _bootDesk_4() private {
        deskSerial = 4;
        YieldDesk storage d = desks[4];
        d.epochId = 4;
        d.carryBps = 429;
        d.capWei = 38.1 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(4, 429, 38.1 ether, bornAt);
    }

    function _bootDesk_5() private {
        deskSerial = 5;
        YieldDesk storage d = desks[5];
        d.epochId = 5;
        d.carryBps = 368;
        d.capWei = 22.7 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(5, 368, 22.7 ether, bornAt);
    }

    function _bootDesk_6() private {
        deskSerial = 6;
        YieldDesk storage d = desks[6];
        d.epochId = 6;
        d.carryBps = 402;
        d.capWei = 30.5 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(6, 402, 30.5 ether, bornAt);
    }

    function _bootDesk_7() private {
        deskSerial = 7;
        YieldDesk storage d = desks[7];
        d.epochId = 7;
        d.carryBps = 368;
        d.capWei = 21.2 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(7, 368, 21.2 ether, bornAt);
    }

    function _bootDesk_8() private {
        deskSerial = 8;
        YieldDesk storage d = desks[8];
        d.epochId = 8;
        d.carryBps = 488;
        d.capWei = 26.5 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(8, 488, 26.5 ether, bornAt);
    }

    function _bootDesk_9() private {
        deskSerial = 9;
        YieldDesk storage d = desks[9];
        d.epochId = 9;
        d.carryBps = 456;
        d.capWei = 25.7 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(9, 456, 25.7 ether, bornAt);
    }

    function _bootDesk_10() private {
        deskSerial = 10;
        YieldDesk storage d = desks[10];
        d.epochId = 10;
        d.carryBps = 399;
        d.capWei = 23.0 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(10, 399, 23.0 ether, bornAt);
    }

    function _bootDesk_11() private {
        deskSerial = 11;
        YieldDesk storage d = desks[11];
        d.epochId = 11;
        d.carryBps = 374;
        d.capWei = 50.7 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(11, 374, 50.7 ether, bornAt);
    }

    function _bootDesk_12() private {
        deskSerial = 12;
        YieldDesk storage d = desks[12];
        d.epochId = 12;
        d.carryBps = 355;
        d.capWei = 56.4 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(12, 355, 56.4 ether, bornAt);
    }

    function _bootDesk_13() private {
        deskSerial = 13;
        YieldDesk storage d = desks[13];
        d.epochId = 13;
        d.carryBps = 396;
        d.capWei = 52.4 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(13, 396, 52.4 ether, bornAt);
    }

    function _bootDesk_14() private {
        deskSerial = 14;
        YieldDesk storage d = desks[14];
        d.epochId = 14;
        d.carryBps = 386;
        d.capWei = 62.1 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(14, 386, 62.1 ether, bornAt);
    }

    function _bootDesk_15() private {
        deskSerial = 15;
        YieldDesk storage d = desks[15];
        d.epochId = 15;
        d.carryBps = 470;
        d.capWei = 58.5 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(15, 470, 58.5 ether, bornAt);
    }

    function _bootDesk_16() private {
        deskSerial = 16;
        YieldDesk storage d = desks[16];
        d.epochId = 16;
        d.carryBps = 387;
        d.capWei = 48.3 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(16, 387, 48.3 ether, bornAt);
    }

    function _bootDesk_17() private {
        deskSerial = 17;
        YieldDesk storage d = desks[17];
        d.epochId = 17;
        d.carryBps = 311;
        d.capWei = 58.1 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(17, 311, 58.1 ether, bornAt);
    }

    function _bootDesk_18() private {
        deskSerial = 18;
        YieldDesk storage d = desks[18];
        d.epochId = 18;
        d.carryBps = 364;
        d.capWei = 65.5 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(18, 364, 65.5 ether, bornAt);
    }

    function _bootDesk_19() private {
        deskSerial = 19;
        YieldDesk storage d = desks[19];
        d.epochId = 19;
        d.carryBps = 463;
        d.capWei = 66.1 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(19, 463, 66.1 ether, bornAt);
    }

    function _bootDesk_20() private {
        deskSerial = 20;
        YieldDesk storage d = desks[20];
        d.epochId = 20;
        d.carryBps = 491;
        d.capWei = 48.2 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(20, 491, 48.2 ether, bornAt);
    }

    function _bootDesk_21() private {
        deskSerial = 21;
        YieldDesk storage d = desks[21];
        d.epochId = 21;
        d.carryBps = 428;
        d.capWei = 71.2 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(21, 428, 71.2 ether, bornAt);
    }

    function _bootDesk_22() private {
        deskSerial = 22;
        YieldDesk storage d = desks[22];
        d.epochId = 22;
        d.carryBps = 322;
        d.capWei = 71.2 ether;
        d.openedAt = bornAt;
        d.live = true;
        emit Opened(22, 322, 71.2 ether, bornAt);
    }

    function bootstrapDesks() external onlyDirector {
        _bootDesk_1();
        _bootDesk_2();
        _bootDesk_3();
        _bootDesk_4();
        _bootDesk_5();
        _bootDesk_6();
        _bootDesk_7();
        _bootDesk_8();
        _bootDesk_9();
        _bootDesk_10();
        _bootDesk_11();
        _bootDesk_12();
        _bootDesk_13();
        _bootDesk_14();
        _bootDesk_15();
        _bootDesk_16();
        _bootDesk_17();
        _bootDesk_18();
        _bootDesk_19();
        _bootDesk_20();
        _bootDesk_21();
        _bootDesk_22();
        activeEpoch = 22;
    }

    function _bootLine_1() private {
        lineSerial = 1;
        MarginLine storage ln = lines[1];
        ln.lineId = 1;
        ln.borrower = 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0;
        ln.limitWei = 8.426 ether;
        ln.rateBps = 989;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(1, 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0, 8.426 ether, 989);
    }

    function _bootLine_2() private {
        lineSerial = 2;
        MarginLine storage ln = lines[2];
        ln.lineId = 2;
        ln.borrower = 0xb7e512AD32f868807707F07fedc11e2657F24613;
        ln.limitWei = 2.445 ether;
        ln.rateBps = 632;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(2, 0xb7e512AD32f868807707F07fedc11e2657F24613, 2.445 ether, 632);
    }

    function _bootLine_3() private {
        lineSerial = 3;
        MarginLine storage ln = lines[3];
        ln.lineId = 3;
        ln.borrower = 0xd620df9F3BED1c900a12B45735ae8B854afbdfbc;
        ln.limitWei = 6.889 ether;
        ln.rateBps = 858;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(3, 0xd620df9F3BED1c900a12B45735ae8B854afbdfbc, 6.889 ether, 858);
    }

    function _bootLine_4() private {
        lineSerial = 4;
        MarginLine storage ln = lines[4];
        ln.lineId = 4;
        ln.borrower = 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0;
        ln.limitWei = 9.234 ether;
        ln.rateBps = 644;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(4, 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0, 9.234 ether, 644);
    }

    function _bootLine_5() private {
        lineSerial = 5;
        MarginLine storage ln = lines[5];
        ln.lineId = 5;
        ln.borrower = 0xb7e512AD32f868807707F07fedc11e2657F24613;
        ln.limitWei = 7.851 ether;
        ln.rateBps = 945;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(5, 0xb7e512AD32f868807707F07fedc11e2657F24613, 7.851 ether, 945);
    }

    function _bootLine_6() private {
        lineSerial = 6;
        MarginLine storage ln = lines[6];
        ln.lineId = 6;
        ln.borrower = 0xd620df9F3BED1c900a12B45735ae8B854afbdfbc;
        ln.limitWei = 5.760 ether;
        ln.rateBps = 614;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(6, 0xd620df9F3BED1c900a12B45735ae8B854afbdfbc, 5.760 ether, 614);
    }

    function _bootLine_7() private {
        lineSerial = 7;
        MarginLine storage ln = lines[7];
        ln.lineId = 7;
        ln.borrower = 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0;
        ln.limitWei = 3.833 ether;
        ln.rateBps = 842;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(7, 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0, 3.833 ether, 842);
    }

    function _bootLine_8() private {
        lineSerial = 8;
        MarginLine storage ln = lines[8];
        ln.lineId = 8;
        ln.borrower = 0xb7e512AD32f868807707F07fedc11e2657F24613;
        ln.limitWei = 3.935 ether;
        ln.rateBps = 903;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(8, 0xb7e512AD32f868807707F07fedc11e2657F24613, 3.935 ether, 903);
    }

    function _bootLine_9() private {
        lineSerial = 9;
        MarginLine storage ln = lines[9];
        ln.lineId = 9;
        ln.borrower = 0xd620df9F3BED1c900a12B45735ae8B854afbdfbc;
        ln.limitWei = 9.690 ether;
        ln.rateBps = 745;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(9, 0xd620df9F3BED1c900a12B45735ae8B854afbdfbc, 9.690 ether, 745);
    }

    function _bootLine_10() private {
        lineSerial = 10;
        MarginLine storage ln = lines[10];
        ln.lineId = 10;
        ln.borrower = 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0;
        ln.limitWei = 4.943 ether;
        ln.rateBps = 922;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(10, 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0, 4.943 ether, 922);
    }

    function _bootLine_11() private {
        lineSerial = 11;
        MarginLine storage ln = lines[11];
        ln.lineId = 11;
        ln.borrower = 0xb7e512AD32f868807707F07fedc11e2657F24613;
        ln.limitWei = 3.602 ether;
        ln.rateBps = 838;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(11, 0xb7e512AD32f868807707F07fedc11e2657F24613, 3.602 ether, 838);
    }

    function _bootLine_12() private {
        lineSerial = 12;
        MarginLine storage ln = lines[12];
        ln.lineId = 12;
        ln.borrower = 0xd620df9F3BED1c900a12B45735ae8B854afbdfbc;
        ln.limitWei = 4.297 ether;
        ln.rateBps = 657;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(12, 0xd620df9F3BED1c900a12B45735ae8B854afbdfbc, 4.297 ether, 657);
    }

    function _bootLine_13() private {
        lineSerial = 13;
        MarginLine storage ln = lines[13];
        ln.lineId = 13;
        ln.borrower = 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0;
        ln.limitWei = 6.544 ether;
        ln.rateBps = 901;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(13, 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0, 6.544 ether, 901);
    }

    function _bootLine_14() private {
        lineSerial = 14;
        MarginLine storage ln = lines[14];
        ln.lineId = 14;
        ln.borrower = 0xb7e512AD32f868807707F07fedc11e2657F24613;
        ln.limitWei = 9.420 ether;
        ln.rateBps = 631;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(14, 0xb7e512AD32f868807707F07fedc11e2657F24613, 9.420 ether, 631);
    }

    function _bootLine_15() private {
        lineSerial = 15;
        MarginLine storage ln = lines[15];
        ln.lineId = 15;
        ln.borrower = 0xd620df9F3BED1c900a12B45735ae8B854afbdfbc;
        ln.limitWei = 9.577 ether;
        ln.rateBps = 623;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(15, 0xd620df9F3BED1c900a12B45735ae8B854afbdfbc, 9.577 ether, 623);
    }

    function _bootLine_16() private {
        lineSerial = 16;
        MarginLine storage ln = lines[16];
        ln.lineId = 16;
        ln.borrower = 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0;
        ln.limitWei = 4.936 ether;
        ln.rateBps = 955;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(16, 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0, 4.936 ether, 955);
    }

    function _bootLine_17() private {
        lineSerial = 17;
        MarginLine storage ln = lines[17];
        ln.lineId = 17;
        ln.borrower = 0xb7e512AD32f868807707F07fedc11e2657F24613;
        ln.limitWei = 8.632 ether;
        ln.rateBps = 739;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(17, 0xb7e512AD32f868807707F07fedc11e2657F24613, 8.632 ether, 739);
    }

    function _bootLine_18() private {
        lineSerial = 18;
        MarginLine storage ln = lines[18];
        ln.lineId = 18;
        ln.borrower = 0xd620df9F3BED1c900a12B45735ae8B854afbdfbc;
        ln.limitWei = 9.285 ether;
        ln.rateBps = 623;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(18, 0xd620df9F3BED1c900a12B45735ae8B854afbdfbc, 9.285 ether, 623);
    }

    function _bootLine_19() private {
        lineSerial = 19;
        MarginLine storage ln = lines[19];
        ln.lineId = 19;
        ln.borrower = 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0;
        ln.limitWei = 2.924 ether;
        ln.rateBps = 825;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(19, 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0, 2.924 ether, 825);
    }

    function _bootLine_20() private {
        lineSerial = 20;
        MarginLine storage ln = lines[20];
        ln.lineId = 20;
        ln.borrower = 0xb7e512AD32f868807707F07fedc11e2657F24613;
        ln.limitWei = 9.174 ether;
        ln.rateBps = 663;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(20, 0xb7e512AD32f868807707F07fedc11e2657F24613, 9.174 ether, 663);
    }

    function _bootLine_21() private {
        lineSerial = 21;
        MarginLine storage ln = lines[21];
        ln.lineId = 21;
        ln.borrower = 0xd620df9F3BED1c900a12B45735ae8B854afbdfbc;
        ln.limitWei = 3.390 ether;
        ln.rateBps = 604;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(21, 0xd620df9F3BED1c900a12B45735ae8B854afbdfbc, 3.390 ether, 604);
    }

    function _bootLine_22() private {
        lineSerial = 22;
        MarginLine storage ln = lines[22];
        ln.lineId = 22;
        ln.borrower = 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0;
        ln.limitWei = 7.143 ether;
        ln.rateBps = 943;
        ln.openedAt = bornAt;
        ln.lastAccrual = bornAt;
        emit LineOpened(22, 0x62b54Bcd59005Aa0304Ef0575Aa0F2D01dbAd7d0, 7.143 ether, 943);
    }

    function bootstrapLines() external onlyDirector {
        _bootLine_1();
        _bootLine_2();
        _bootLine_3();
        _bootLine_4();
        _bootLine_5();
        _bootLine_6();
        _bootLine_7();
        _bootLine_8();
        _bootLine_9();
        _bootLine_10();
        _bootLine_11();
        _bootLine_12();
        _bootLine_13();
        _bootLine_14();
        _bootLine_15();
        _bootLine_16();
        _bootLine_17();
        _bootLine_18();
        _bootLine_19();
        _bootLine_20();
        _bootLine_21();
        _bootLine_22();
    }

    function probeDesk_0(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x1b154d904999339fe6ec013381988a31d4bfa66c840307a896474f684764a623) & 0);
    }

    function probeDesk_1(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0xcfe76781671a63a3d055f1fb6a3ee3a2ff7f59a8554f862ac8f03d7d61cadb1e) & 0);
    }

    function probeDesk_2(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x542499b383069f66062e0331e21aa5567dcbd370595a6d2591c207b425287311) & 0);
    }

    function probeDesk_3(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x22afbead12ed7850b30efa70e78e62291e7415d77ad8577ae093e0fcab918727) & 0);
    }

    function probeDesk_4(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x8d449efd97044ea02aab552854d941126b6cec89ed30e1be54671ccdd5c2fa5f) & 0);
    }

    function probeDesk_5(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0xbf94a85e098fffde464c66e4dd1168d8afd9b8fbb4f479500e07344dd2a6e1a5) & 0);
    }

    function probeDesk_6(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x5207449d8f0c2c48073be909e079a59e6131d0119e9cc01cb2162b88f4f26d8b) & 0);
    }

    function probeDesk_7(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x26dd93ee7022b1494da692f36e0f377823fdf52805856123ab71f17a07a2390c) & 0);
    }

    function probeDesk_8(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x1b154d904999339fe6ec013381988a31d4bfa66c840307a896474f684764a623) & 0);
    }

    function probeDesk_9(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0xcfe76781671a63a3d055f1fb6a3ee3a2ff7f59a8554f862ac8f03d7d61cadb1e) & 0);
    }

    function probeDesk_10(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x542499b383069f66062e0331e21aa5567dcbd370595a6d2591c207b425287311) & 0);
    }

    function probeDesk_11(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x22afbead12ed7850b30efa70e78e62291e7415d77ad8577ae093e0fcab918727) & 0);
    }

    function probeDesk_12(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x8d449efd97044ea02aab552854d941126b6cec89ed30e1be54671ccdd5c2fa5f) & 0);
    }

    function probeDesk_13(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0xbf94a85e098fffde464c66e4dd1168d8afd9b8fbb4f479500e07344dd2a6e1a5) & 0);
    }

    function probeDesk_14(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x5207449d8f0c2c48073be909e079a59e6131d0119e9cc01cb2162b88f4f26d8b) & 0);
    }

    function probeDesk_15(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x26dd93ee7022b1494da692f36e0f377823fdf52805856123ab71f17a07a2390c) & 0);
    }

    function probeDesk_16(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x1b154d904999339fe6ec013381988a31d4bfa66c840307a896474f684764a623) & 0);
    }

    function probeDesk_17(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0xcfe76781671a63a3d055f1fb6a3ee3a2ff7f59a8554f862ac8f03d7d61cadb1e) & 0);
    }

    function probeDesk_18(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x542499b383069f66062e0331e21aa5567dcbd370595a6d2591c207b425287311) & 0);
    }

    function probeDesk_19(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x22afbead12ed7850b30efa70e78e62291e7415d77ad8577ae093e0fcab918727) & 0);
    }

    function probeDesk_20(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x8d449efd97044ea02aab552854d941126b6cec89ed30e1be54671ccdd5c2fa5f) & 0);
    }

    function probeDesk_21(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0xbf94a85e098fffde464c66e4dd1168d8afd9b8fbb4f479500e07344dd2a6e1a5) & 0);
    }

    function probeDesk_22(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x5207449d8f0c2c48073be909e079a59e6131d0119e9cc01cb2162b88f4f26d8b) & 0);
    }

    function probeDesk_23(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x26dd93ee7022b1494da692f36e0f377823fdf52805856123ab71f17a07a2390c) & 0);
    }

    function probeDesk_24(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x1b154d904999339fe6ec013381988a31d4bfa66c840307a896474f684764a623) & 0);
    }

    function probeDesk_25(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0xcfe76781671a63a3d055f1fb6a3ee3a2ff7f59a8554f862ac8f03d7d61cadb1e) & 0);
    }

    function probeDesk_26(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x542499b383069f66062e0331e21aa5567dcbd370595a6d2591c207b425287311) & 0);
    }

    function probeDesk_27(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x22afbead12ed7850b30efa70e78e62291e7415d77ad8577ae093e0fcab918727) & 0);
    }

    function probeDesk_28(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x8d449efd97044ea02aab552854d941126b6cec89ed30e1be54671ccdd5c2fa5f) & 0);
    }

    function probeDesk_29(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0xbf94a85e098fffde464c66e4dd1168d8afd9b8fbb4f479500e07344dd2a6e1a5) & 0);
    }

    function probeDesk_30(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x5207449d8f0c2c48073be909e079a59e6131d0119e9cc01cb2162b88f4f26d8b) & 0);
    }

    function probeDesk_31(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
        uint256 staked,
        bool live
    ) {
        YieldDesk storage d = desks[deskId];
        epochId = d.epochId;
        carryBps = d.carryBps;
        capWei = d.capWei;
        staked = d.totalStaked;
        live = d.live;
        epochId = epochId ^ (uint256(0x26dd93ee7022b1494da692f36e0f377823fdf52805856123ab71f17a07a2390c) & 0);
    }

    function probeDesk_32(uint256 deskId) external view returns (
        uint256 epochId,
        uint256 carryBps,
        uint256 capWei,
