// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {IEscrowModule} from "./interfaces/IEscrowModule.sol";

/// @title MilestoneEscrow
/// @notice Singleton escrow for client/provider milestone agreements with an arbiter.
///         Supports native ETH (token == address(0)) and standard ERC-20s, EIP-712 signed
///         approvals (EOA + ERC-1271 smart accounts) and pull-payment withdrawals.
contract MilestoneEscrow is IEscrowModule, EIP712, ReentrancyGuard, Ownable2Step, Multicall {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ types
    enum Status { None, Created, Funded, Disputed, Resolved, Cancelled, Refunded, Completed }
    enum MilestoneStatus { Pending, Submitted, Released, Refunded, Resolved }

    struct Milestone {
        uint128 amount;
        uint64 submittedAt;
        MilestoneStatus status;
    }

    struct Escrow {
        address client;      // slot 0
        uint16 feeBps;       //        (fee snapshotted at creation)
        uint64 reviewPeriod; //
        Status status;       //
        address provider;    // slot 1
        uint64 deadline;     //
        address arbiter;     // slot 2
        uint64 disputedAt;   //
        address token;       // slot 3
        uint256 total;       // slot 4
        uint256 settled;     // slot 5  (released + refunded + resolved)
        uint256 paidToProvider; // slot 6 (gross, before fee)
    }

    // -------------------------------------------------------------- constants
    uint16 public constant MAX_FEE_BPS = 500; // 5% hard cap
    uint16 internal constant BPS = 10_000;
    uint256 public constant MAX_MILESTONES = 50;
    uint64 public constant MIN_REVIEW_PERIOD = 1 hours;
    uint64 public constant MAX_REVIEW_PERIOD = 30 days;
    uint64 public constant ARBITER_TIMEOUT = 30 days;

    bytes32 public constant APPROVE_TYPEHASH =
        keccak256("ApproveMilestone(uint256 escrowId,uint256 index,uint256 amount,uint256 sigDeadline)");

    // ---------------------------------------------------------------- storage
    uint256 public nextEscrowId = 1;
    uint16 public feeBps;
    address public feeRecipient;
    mapping(uint256 => Escrow) internal _escrows;
    // False positive: written via storage pointer `ms.push(...)` in createEscrow; Slither does not track writes through storage refs.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 => Milestone[]) internal _milestones;
    /// @notice pull-payment credits: account => token => amount
    mapping(address => mapping(address => uint256)) internal _credits;
    /// @notice total owed by the contract per token (locked escrow funds + unclaimed credits)
    mapping(address => uint256) public liabilities;

    // ----------------------------------------------------------------- events
    event EscrowCreated(uint256 indexed escrowId, address indexed client, address indexed provider, address arbiter, address token, uint256 total, uint256 milestoneCount);
    event EscrowFunded(uint256 indexed escrowId, uint256 amount);
    event EscrowCancelled(uint256 indexed escrowId);
    event MilestoneSubmitted(uint256 indexed escrowId, uint256 indexed index);
    event MilestoneApproved(uint256 indexed escrowId, uint256 indexed index, address indexed approver);
    event MilestoneReleased(uint256 indexed escrowId, uint256 indexed index, uint256 toProvider, uint256 fee);
    event MilestoneRefunded(uint256 indexed escrowId, uint256 indexed index, uint256 amount);
    event DisputeRaised(uint256 indexed escrowId, address indexed by);
    event DisputeResolved(uint256 indexed escrowId, address indexed resolver, uint256 toProvider, uint256 toClient, uint256 fee);
    event StatusChanged(uint256 indexed escrowId, Status status);
    event Withdrawn(address indexed account, address indexed token, uint256 amount);
    event FeeUpdated(uint16 feeBps, address indexed feeRecipient);

    // ----------------------------------------------------------------- errors
    error FeeTooHigh();
    error ZeroAddress();
    error InvalidParties();
    error InvalidMilestones();
    error InvalidReviewPeriod();
    error InvalidDeadline();
    error Unauthorized();
    error InvalidStatus();
    error InvalidMilestoneStatus();
    error IndexOutOfBounds();
    error IncorrectPayment();
    error FeeOnTransferNotSupported();
    error ReviewPeriodActive();
    error DeadlineNotPassed();
    error ArbiterTimeoutNotReached();
    error SignatureExpired();
    error InvalidSignature();
    error InvalidShare();
    error NothingToWithdraw();
    error EthTransferFailed();

    constructor(address owner_, address feeRecipient_, uint16 feeBps_)
        EIP712("MilestoneEscrow", "1")
        Ownable(owner_)
    {
        _setFee(feeBps_, feeRecipient_);
    }

    // ================================================================= admin
    /// @notice Only affects escrows created afterwards (fee is snapshotted per escrow).
    function setFee(uint16 feeBps_, address feeRecipient_) external onlyOwner {
        _setFee(feeBps_, feeRecipient_);
    }

    function _setFee(uint16 feeBps_, address feeRecipient_) internal {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeBps = feeBps_;
        feeRecipient = feeRecipient_;
        emit FeeUpdated(feeBps_, feeRecipient_);
    }

    // ============================================================= lifecycle
    /// @inheritdoc IEscrowModule
    function createEscrow(
        address provider,
        address arbiter,
        address token,
        uint256[] calldata amounts,
        uint64 reviewPeriod,
        uint64 deadline
    ) external returns (uint256 escrowId) {
        if (provider == address(0) || arbiter == address(0)) revert ZeroAddress();
        if (provider == msg.sender || arbiter == msg.sender || arbiter == provider) revert InvalidParties();
        uint256 n = amounts.length;
        if (n == 0 || n > MAX_MILESTONES) revert InvalidMilestones();
        if (reviewPeriod < MIN_REVIEW_PERIOD || reviewPeriod > MAX_REVIEW_PERIOD) revert InvalidReviewPeriod();
        if (deadline <= block.timestamp) revert InvalidDeadline();

        escrowId = nextEscrowId++;
        Milestone[] storage ms = _milestones[escrowId];
        uint256 total = 0;
        for (uint256 i; i < n; ++i) {
            uint256 a = amounts[i];
            if (a == 0 || a > type(uint128).max) revert InvalidMilestones();
            total += a;
            ms.push(Milestone({amount: uint128(a), submittedAt: 0, status: MilestoneStatus.Pending}));
        }

        _escrows[escrowId] = Escrow({
            client: msg.sender,
            feeBps: feeBps,
            reviewPeriod: reviewPeriod,
            status: Status.Created,
            provider: provider,
            deadline: deadline,
            arbiter: arbiter,
            disputedAt: 0,
            token: token,
            total: total,
            settled: 0,
            paidToProvider: 0
        });
        emit EscrowCreated(escrowId, msg.sender, provider, arbiter, token, total, n);
    }

    /// @inheritdoc IEscrowModule
    function fund(uint256 escrowId) external payable nonReentrant {
        Escrow storage e = _escrows[escrowId];
        if (msg.sender != e.client) revert Unauthorized();
        if (e.status != Status.Created) revert InvalidStatus();
        uint256 total = e.total;
        address token = e.token;

        // effects first
        e.status = Status.Funded;
        liabilities[token] += total;

        if (token == address(0)) {
            if (msg.value != total) revert IncorrectPayment();
        } else {
            if (msg.value != 0) revert IncorrectPayment();
            uint256 beforeBal = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(msg.sender, address(this), total);
            if (IERC20(token).balanceOf(address(this)) - beforeBal != total) revert FeeOnTransferNotSupported();
        }
        emit EscrowFunded(escrowId, total);
        emit StatusChanged(escrowId, Status.Funded);
    }

    /// @notice Client cancels an escrow that was never funded.
    function cancel(uint256 escrowId) external {
        Escrow storage e = _escrows[escrowId];
        if (msg.sender != e.client) revert Unauthorized();
        if (e.status != Status.Created) revert InvalidStatus();
        e.status = Status.Cancelled;
        emit EscrowCancelled(escrowId);
        emit StatusChanged(escrowId, Status.Cancelled);
    }

    /// @inheritdoc IEscrowModule
    function submitMilestone(uint256 escrowId, uint256 index) external {
        Escrow storage e = _escrows[escrowId];
        if (msg.sender != e.provider) revert Unauthorized();
        if (e.status != Status.Funded) revert InvalidStatus();
        Milestone storage m = _milestone(escrowId, index);
        if (m.status != MilestoneStatus.Pending) revert InvalidMilestoneStatus();
        m.status = MilestoneStatus.Submitted;
        m.submittedAt = uint64(block.timestamp);
        emit MilestoneSubmitted(escrowId, index);
    }

    /// @inheritdoc IEscrowModule
    /// @dev Client may also approve a Pending milestone (early payment).
    function approveMilestone(uint256 escrowId, uint256 index) external {
        Escrow storage e = _escrows[escrowId];
        if (msg.sender != e.client) revert Unauthorized();
        _approve(escrowId, e, index, msg.sender);
    }

    /// @notice Relay a client's EIP-712 approval. Works for EOAs and ERC-1271 smart accounts.
    ///         Replay-safe: a milestone can only transition to Released once; the domain binds chain + contract.
    function approveMilestoneWithSig(uint256 escrowId, uint256 index, uint256 sigDeadline, bytes calldata signature)
        external
    {
        if (block.timestamp > sigDeadline) revert SignatureExpired();
        Escrow storage e = _escrows[escrowId];
        if (e.client == address(0)) revert InvalidStatus();
        Milestone storage m = _milestone(escrowId, index);
        bytes32 digest = approvalDigest(escrowId, index, m.amount, sigDeadline);
        if (!SignatureChecker.isValidSignatureNow(e.client, digest, signature)) revert InvalidSignature();
        _approve(escrowId, e, index, e.client);
    }

    function approvalDigest(uint256 escrowId, uint256 index, uint256 amount, uint256 sigDeadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(APPROVE_TYPEHASH, escrowId, index, amount, sigDeadline)));
    }

    /// @inheritdoc IEscrowModule
    /// @dev Protects the provider against an unresponsive client.
    function claimAfterReview(uint256 escrowId, uint256 index) external {
        Escrow storage e = _escrows[escrowId];
        if (msg.sender != e.provider) revert Unauthorized();
        if (e.status != Status.Funded) revert InvalidStatus();
        Milestone storage m = _milestone(escrowId, index);
        if (m.status != MilestoneStatus.Submitted) revert InvalidMilestoneStatus();
        if (block.timestamp < uint256(m.submittedAt) + e.reviewPeriod) revert ReviewPeriodActive();
        _release(escrowId, e, index, m);
        _maybeClose(escrowId, e);
    }

    /// @notice After the deadline the client reclaims milestones the provider never submitted.
    ///         Submitted milestones remain claimable by the provider (or disputable).
    function refundExpired(uint256 escrowId) external {
        Escrow storage e = _escrows[escrowId];
        if (msg.sender != e.client) revert Unauthorized();
        if (e.status != Status.Funded) revert InvalidStatus();
        if (block.timestamp <= e.deadline) revert DeadlineNotPassed();
        Milestone[] storage ms = _milestones[escrowId];
        uint256 refund = 0;
        for (uint256 i; i < ms.length; ++i) {
            if (ms[i].status == MilestoneStatus.Pending) {
                ms[i].status = MilestoneStatus.Refunded;
                refund += ms[i].amount;
                emit MilestoneRefunded(escrowId, i, ms[i].amount);
            }
        }
        if (refund == 0) revert InvalidMilestoneStatus();
        e.settled += refund;
        _credits[e.client][e.token] += refund;
        _maybeClose(escrowId, e);
    }

    /// @notice Provider voluntarily walks away, refunding every unsettled milestone to the client.
    function providerRefund(uint256 escrowId) external {
        Escrow storage e = _escrows[escrowId];
        if (msg.sender != e.provider) revert Unauthorized();
        if (e.status != Status.Funded) revert InvalidStatus();
        Milestone[] storage ms = _milestones[escrowId];
        uint256 refund = 0;
        for (uint256 i; i < ms.length; ++i) {
            MilestoneStatus s = ms[i].status;
            if (s == MilestoneStatus.Pending || s == MilestoneStatus.Submitted) {
                ms[i].status = MilestoneStatus.Refunded;
                refund += ms[i].amount;
                emit MilestoneRefunded(escrowId, i, ms[i].amount);
            }
        }
        e.settled += refund; // refund > 0 guaranteed: status Funded implies something unsettled
        _credits[e.client][e.token] += refund;
        _maybeClose(escrowId, e);
    }

    // ============================================================== disputes
    /// @inheritdoc IEscrowModule
    function raiseDispute(uint256 escrowId) external {
        Escrow storage e = _escrows[escrowId];
        if (msg.sender != e.client && msg.sender != e.provider) revert Unauthorized();
        if (e.status != Status.Funded) revert InvalidStatus();
        e.status = Status.Disputed;
        e.disputedAt = uint64(block.timestamp);
        emit DisputeRaised(escrowId, msg.sender);
        emit StatusChanged(escrowId, Status.Disputed);
    }

    /// @notice Arbiter splits all unsettled funds. The arbiter can never receive funds itself.
    function resolveDispute(uint256 escrowId, uint16 providerShareBps) external {
        Escrow storage e = _escrows[escrowId];
        if (msg.sender != e.arbiter) revert Unauthorized();
        if (e.status != Status.Disputed) revert InvalidStatus();
        if (providerShareBps > BPS) revert InvalidShare();
        uint256 remaining = e.total - e.settled;
        uint256 toProvider = (remaining * providerShareBps) / BPS;
        _settleDispute(escrowId, e, toProvider, remaining - toProvider);
    }

    /// @notice Liveness fallback if the arbiter is absent: submitted milestones go to the provider,
    ///         pending ones back to the client.
    function resolveAfterArbiterTimeout(uint256 escrowId) external {
        Escrow storage e = _escrows[escrowId];
        if (msg.sender != e.client && msg.sender != e.provider) revert Unauthorized();
        if (e.status != Status.Disputed) revert InvalidStatus();
        if (block.timestamp < uint256(e.disputedAt) + ARBITER_TIMEOUT) revert ArbiterTimeoutNotReached();
        Milestone[] storage ms = _milestones[escrowId];
        uint256 toProvider = 0;
        uint256 toClient = 0;
        for (uint256 i; i < ms.length; ++i) {
            MilestoneStatus s = ms[i].status;
            if (s == MilestoneStatus.Submitted) toProvider += ms[i].amount;
            else if (s == MilestoneStatus.Pending) toClient += ms[i].amount;
        }
        _settleDispute(escrowId, e, toProvider, toClient);
    }

    function _settleDispute(uint256 escrowId, Escrow storage e, uint256 toProvider, uint256 toClient) internal {
        Milestone[] storage ms = _milestones[escrowId];
        for (uint256 i; i < ms.length; ++i) {
            MilestoneStatus s = ms[i].status;
            if (s == MilestoneStatus.Pending || s == MilestoneStatus.Submitted) ms[i].status = MilestoneStatus.Resolved;
        }
        uint256 fee = (toProvider * e.feeBps) / BPS;
        address token = e.token;
        e.settled += toProvider + toClient;
        e.paidToProvider += toProvider;
        e.status = Status.Resolved;
        _credits[e.provider][token] += toProvider - fee;
        _credits[e.client][token] += toClient;
        if (fee != 0) _credits[feeRecipient][token] += fee;
        emit DisputeResolved(escrowId, msg.sender, toProvider - fee, toClient, fee);
        emit StatusChanged(escrowId, Status.Resolved);
    }

    // ============================================================ withdrawals
    /// @inheritdoc IEscrowModule
    function withdraw(address token) external nonReentrant returns (uint256 amount) {
        amount = _credits[msg.sender][token];
        if (amount == 0) revert NothingToWithdraw();
        _credits[msg.sender][token] = 0;
        liabilities[token] -= amount;
        emit Withdrawn(msg.sender, token, amount);
        if (token == address(0)) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
    }

    // ================================================================= views
    /// @inheritdoc IEscrowModule
    function withdrawable(address account, address token) external view returns (uint256) {
        return _credits[account][token];
    }

    function getEscrow(uint256 escrowId) external view returns (Escrow memory) {
        return _escrows[escrowId];
    }

    function getMilestones(uint256 escrowId) external view returns (Milestone[] memory) {
        return _milestones[escrowId];
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ============================================================== internals
    function _milestone(uint256 escrowId, uint256 index) internal view returns (Milestone storage) {
        Milestone[] storage ms = _milestones[escrowId];
        if (index >= ms.length) revert IndexOutOfBounds();
        return ms[index];
    }

    function _approve(uint256 escrowId, Escrow storage e, uint256 index, address approver) internal {
        if (e.status != Status.Funded) revert InvalidStatus();
        Milestone storage m = _milestone(escrowId, index);
        MilestoneStatus s = m.status;
        if (s != MilestoneStatus.Pending && s != MilestoneStatus.Submitted) revert InvalidMilestoneStatus();
        emit MilestoneApproved(escrowId, index, approver);
        _release(escrowId, e, index, m);
        _maybeClose(escrowId, e);
    }

    function _release(uint256 escrowId, Escrow storage e, uint256 index, Milestone storage m) internal {
        uint256 amount = m.amount;
        m.status = MilestoneStatus.Released;
        uint256 fee = (amount * e.feeBps) / BPS;
        e.settled += amount;
        e.paidToProvider += amount;
        address token = e.token;
        _credits[e.provider][token] += amount - fee;
        if (fee != 0) _credits[feeRecipient][token] += fee;
        emit MilestoneReleased(escrowId, index, amount - fee, fee);
    }

    function _maybeClose(uint256 escrowId, Escrow storage e) internal {
        if (e.settled == e.total) {
            Status s = e.paidToProvider == 0 ? Status.Refunded : Status.Completed;
            e.status = s;
            emit StatusChanged(escrowId, s);
        }
    }
}
