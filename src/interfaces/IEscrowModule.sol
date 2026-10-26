// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEscrowModule
/// @notice Thin, account-agnostic surface of the escrow that a modular smart account
///         (ERC-7579 executor / ERC-4337 account) can call. Every function authorizes
///         purely on `msg.sender`, so a smart account calling directly (or via an executor
///         module using `executeFromExecutor`) is treated identically to an EOA.
interface IEscrowModule {
    function createEscrow(
        address provider,
        address arbiter,
        address token,
        uint256[] calldata amounts,
        uint64 reviewPeriod,
        uint64 deadline
    ) external returns (uint256 escrowId);

    function fund(uint256 escrowId) external payable;
    function submitMilestone(uint256 escrowId, uint256 index) external;
    function approveMilestone(uint256 escrowId, uint256 index) external;
    function claimAfterReview(uint256 escrowId, uint256 index) external;
    function raiseDispute(uint256 escrowId) external;
    function withdraw(address token) external returns (uint256 amount);
    function withdrawable(address account, address token) external view returns (uint256);
}
