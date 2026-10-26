// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";
import {MockERC20, FeeOnTransferToken, MockSmartAccount, ReentrantReceiver} from "./mocks/Mocks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Base is Test {
    MilestoneEscrow esc;
    MockERC20 tok;
    address owner = makeAddr("owner");
    address feeTo = makeAddr("feeTo");
    uint256 clientPk = 0xC11E;
    address client;
    address provider = makeAddr("provider");
    address arbiter = makeAddr("arbiter");
    address ETH = address(0);
    uint64 constant REVIEW = 3 days;

    function setUp() public virtual {
        client = vm.addr(clientPk);
        esc = new MilestoneEscrow(owner, feeTo, 100); // 1%
        tok = new MockERC20();
        vm.deal(client, 1000 ether);
        tok.mint(client, 1000 ether);
        vm.prank(client);
        tok.approve(address(esc), type(uint256).max);
    }

    function _amts() internal pure returns (uint256[] memory a) {
        a = new uint256[](3);
        a[0] = 1 ether; a[1] = 2 ether; a[2] = 3 ether;
    }

    function _create(address token) internal returns (uint256 id) {
        vm.prank(client);
        id = esc.createEscrow(provider, arbiter, token, _amts(), REVIEW, uint64(block.timestamp + 30 days));
    }

    function _funded(address token) internal returns (uint256 id) {
        id = _create(token);
        vm.prank(client);
        if (token == ETH) esc.fund{value: 6 ether}(id); else esc.fund(id);
    }

    function _status(uint256 id) internal view returns (MilestoneEscrow.Status) { return esc.getEscrow(id).status; }
    function _mstatus(uint256 id, uint256 i) internal view returns (MilestoneEscrow.MilestoneStatus) { return esc.getMilestones(id)[i].status; }

    function _sign(uint256 pk, uint256 id, uint256 i, uint256 amt, uint256 dl) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, esc.approvalDigest(id, i, amt, dl));
        return abi.encodePacked(r, s, v);
    }
}

contract MilestoneEscrowTest is Base {
    // ---------------- constructor / admin
    function test_constructor_feeTooHigh() public {
        vm.expectRevert(MilestoneEscrow.FeeTooHigh.selector);
        new MilestoneEscrow(owner, feeTo, 501);
    }
    function test_constructor_zeroRecipient() public {
        vm.expectRevert(MilestoneEscrow.ZeroAddress.selector);
        new MilestoneEscrow(owner, address(0), 0);
    }
    function test_setFee() public {
        vm.prank(owner); esc.setFee(500, address(7));
        assertEq(esc.feeBps(), 500); assertEq(esc.feeRecipient(), address(7));
    }
    function test_setFee_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        esc.setFee(1, address(7));
    }
    function test_feeSnapshot() public {
        uint256 id = _funded(ETH);
        vm.prank(owner); esc.setFee(500, feeTo);
        vm.prank(client); esc.approveMilestone(id, 0);
        assertEq(esc.withdrawable(feeTo, ETH), 0.01 ether); // old 1%
    }

    // ---------------- create
    function test_create_ok() public {
        uint256 id = _create(ETH);
        MilestoneEscrow.Escrow memory e = esc.getEscrow(id);
        assertEq(e.client, client); assertEq(e.total, 6 ether); assertEq(uint8(e.status), uint8(MilestoneEscrow.Status.Created));
        assertEq(esc.getMilestones(id).length, 3); assertEq(esc.nextEscrowId(), 2);
    }
    function test_create_reverts() public {
        uint256[] memory a = _amts();
        uint64 dl = uint64(block.timestamp + 1 days);
        vm.startPrank(client);
        vm.expectRevert(MilestoneEscrow.ZeroAddress.selector); esc.createEscrow(address(0), arbiter, ETH, a, REVIEW, dl);
        vm.expectRevert(MilestoneEscrow.ZeroAddress.selector); esc.createEscrow(provider, address(0), ETH, a, REVIEW, dl);
        vm.expectRevert(MilestoneEscrow.InvalidParties.selector); esc.createEscrow(client, arbiter, ETH, a, REVIEW, dl);
        vm.expectRevert(MilestoneEscrow.InvalidParties.selector); esc.createEscrow(provider, client, ETH, a, REVIEW, dl);
        vm.expectRevert(MilestoneEscrow.InvalidParties.selector); esc.createEscrow(provider, provider, ETH, a, REVIEW, dl);
        vm.expectRevert(MilestoneEscrow.InvalidMilestones.selector); esc.createEscrow(provider, arbiter, ETH, new uint256[](0), REVIEW, dl);
        vm.expectRevert(MilestoneEscrow.InvalidMilestones.selector); esc.createEscrow(provider, arbiter, ETH, new uint256[](51), REVIEW, dl);
        uint256[] memory z = new uint256[](1);
        vm.expectRevert(MilestoneEscrow.InvalidMilestones.selector); esc.createEscrow(provider, arbiter, ETH, z, REVIEW, dl);
        z[0] = uint256(type(uint128).max) + 1;
        vm.expectRevert(MilestoneEscrow.InvalidMilestones.selector); esc.createEscrow(provider, arbiter, ETH, z, REVIEW, dl);
        vm.expectRevert(MilestoneEscrow.InvalidReviewPeriod.selector); esc.createEscrow(provider, arbiter, ETH, a, 1 hours - 1, dl);
        vm.expectRevert(MilestoneEscrow.InvalidReviewPeriod.selector); esc.createEscrow(provider, arbiter, ETH, a, 30 days + 1, dl);
        vm.expectRevert(MilestoneEscrow.InvalidDeadline.selector); esc.createEscrow(provider, arbiter, ETH, a, REVIEW, uint64(block.timestamp));
        vm.stopPrank();
    }

    // ---------------- fund
    function test_fund_eth() public {
        uint256 id = _funded(ETH);
        assertEq(address(esc).balance, 6 ether); assertEq(esc.liabilities(ETH), 6 ether);
        assertEq(uint8(_status(id)), uint8(MilestoneEscrow.Status.Funded));
    }
    function test_fund_erc20() public {
        _funded(address(tok));
        assertEq(tok.balanceOf(address(esc)), 6 ether);
    }
    function test_fund_reverts() public {
        uint256 id = _create(ETH);
        vm.expectRevert(MilestoneEscrow.Unauthorized.selector); esc.fund(id);
        vm.startPrank(client);
        vm.expectRevert(MilestoneEscrow.IncorrectPayment.selector); esc.fund{value: 1}(id);
        esc.fund{value: 6 ether}(id);
        vm.expectRevert(MilestoneEscrow.InvalidStatus.selector); esc.fund{value: 6 ether}(id);
        vm.stopPrank();
        uint256 id2 = _create(address(tok));
        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.IncorrectPayment.selector); esc.fund{value: 1}(id2);
    }
    function test_fund_feeOnTransferRejected() public {
        FeeOnTransferToken f = new FeeOnTransferToken();
        f.mint(client, 100 ether);
        uint256 id = _create(address(f));
        vm.startPrank(client);
        f.approve(address(esc), type(uint256).max);
        vm.expectRevert(MilestoneEscrow.FeeOnTransferNotSupported.selector);
        esc.fund(id);
        vm.stopPrank();
        assertEq(esc.liabilities(address(f)), 0);
    }

    // ---------------- cancel
    function test_cancel() public {
        uint256 id = _create(ETH);
        vm.expectRevert(MilestoneEscrow.Unauthorized.selector); esc.cancel(id);
        vm.prank(client); esc.cancel(id);
        assertEq(uint8(_status(id)), uint8(MilestoneEscrow.Status.Cancelled));
        vm.prank(client); vm.expectRevert(MilestoneEscrow.InvalidStatus.selector); esc.cancel(id);
    }

    // ---------------- submit / approve / release
    function test_happyPath_eth() public {
        uint256 id = _funded(ETH);
        for (uint256 i; i < 3; ++i) {
            vm.prank(provider); esc.submitMilestone(id, i);
            assertEq(uint8(_mstatus(id, i)), uint8(MilestoneEscrow.MilestoneStatus.Submitted));
            vm.prank(client); esc.approveMilestone(id, i);
        }
        assertEq(uint8(_status(id)), uint8(MilestoneEscrow.Status.Completed));
        assertEq(esc.withdrawable(provider, ETH), 5.94 ether);
        assertEq(esc.withdrawable(feeTo, ETH), 0.06 ether);
        vm.prank(provider); esc.withdraw(ETH);
        vm.prank(feeTo); esc.withdraw(ETH);
        assertEq(provider.balance, 5.94 ether); assertEq(address(esc).balance, 0); assertEq(esc.liabilities(ETH), 0);
    }
    function test_happyPath_erc20_zeroFee() public {
        vm.prank(owner); esc.setFee(0, feeTo);
        uint256 id = _funded(address(tok));
        vm.startPrank(client);
        esc.approveMilestone(id, 0); esc.approveMilestone(id, 1); esc.approveMilestone(id, 2);
        vm.stopPrank();
        assertEq(esc.withdrawable(feeTo, address(tok)), 0);
        vm.prank(provider); assertEq(esc.withdraw(address(tok)), 6 ether);
        assertEq(tok.balanceOf(provider), 6 ether);
    }
    function test_submit_reverts() public {
        uint256 id = _create(ETH);
        vm.prank(client); vm.expectRevert(MilestoneEscrow.Unauthorized.selector); esc.submitMilestone(id, 0);
        vm.prank(provider); vm.expectRevert(MilestoneEscrow.InvalidStatus.selector); esc.submitMilestone(id, 0);
        vm.prank(client); esc.fund{value: 6 ether}(id);
        vm.prank(provider); vm.expectRevert(MilestoneEscrow.IndexOutOfBounds.selector); esc.submitMilestone(id, 3);
        vm.startPrank(provider); esc.submitMilestone(id, 0);
        vm.expectRevert(MilestoneEscrow.InvalidMilestoneStatus.selector); esc.submitMilestone(id, 0);
        vm.stopPrank();
    }
    function test_approve_reverts() public {
        uint256 id = _create(ETH);
        vm.prank(provider); vm.expectRevert(MilestoneEscrow.Unauthorized.selector); esc.approveMilestone(id, 0);
        vm.prank(client); vm.expectRevert(MilestoneEscrow.InvalidStatus.selector); esc.approveMilestone(id, 0);
        vm.prank(client); esc.fund{value: 6 ether}(id);
        vm.startPrank(client);
        esc.approveMilestone(id, 0);
        vm.expectRevert(MilestoneEscrow.InvalidMilestoneStatus.selector); esc.approveMilestone(id, 0); // no double release
        vm.stopPrank();
    }

    // ---------------- signatures
    function test_approveWithSig_eoa() public {
        uint256 id = _funded(ETH);
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _sign(clientPk, id, 1, 2 ether, dl);
        esc.approveMilestoneWithSig(id, 1, dl, sig); // relayed by anyone
        assertEq(uint8(_mstatus(id, 1)), uint8(MilestoneEscrow.MilestoneStatus.Released));
        vm.expectRevert(MilestoneEscrow.InvalidMilestoneStatus.selector);
        esc.approveMilestoneWithSig(id, 1, dl, sig); // replay
    }
    function test_approveWithSig_reverts() public {
        uint256 id = _funded(ETH);
        uint256 dl = block.timestamp + 1 hours;
        bytes memory bad = _sign(0xBAD, id, 0, 1 ether, dl);
        vm.expectRevert(MilestoneEscrow.InvalidSignature.selector); esc.approveMilestoneWithSig(id, 0, dl, bad);
        bytes memory wrongAmt = _sign(clientPk, id, 0, 2 ether, dl);
        vm.expectRevert(MilestoneEscrow.InvalidSignature.selector); esc.approveMilestoneWithSig(id, 0, dl, wrongAmt);
        bytes memory good = _sign(clientPk, id, 0, 1 ether, dl);
        vm.warp(dl + 1);
        vm.expectRevert(MilestoneEscrow.SignatureExpired.selector); esc.approveMilestoneWithSig(id, 0, dl, good);
        vm.expectRevert(MilestoneEscrow.InvalidStatus.selector); esc.approveMilestoneWithSig(999, 0, dl + 10, good);
        vm.expectRevert(MilestoneEscrow.IndexOutOfBounds.selector); esc.approveMilestoneWithSig(id, 9, dl + 10, good);
    }
    function test_domainSeparator() public view {
        assertTrue(esc.domainSeparator() != bytes32(0));
    }

    // ---------------- review timeout
    function test_claimAfterReview() public {
        uint256 id = _funded(ETH);
        vm.prank(provider); esc.submitMilestone(id, 0);
        vm.prank(provider); vm.expectRevert(MilestoneEscrow.ReviewPeriodActive.selector); esc.claimAfterReview(id, 0);
        vm.warp(block.timestamp + REVIEW);
        vm.prank(client); vm.expectRevert(MilestoneEscrow.Unauthorized.selector); esc.claimAfterReview(id, 0);
        vm.prank(provider); vm.expectRevert(MilestoneEscrow.InvalidMilestoneStatus.selector); esc.claimAfterReview(id, 1);
        vm.prank(provider); esc.claimAfterReview(id, 0);
        assertEq(esc.withdrawable(provider, ETH), 0.99 ether);
    }
    function test_claimAfterReview_completes() public {
        uint256[] memory a = new uint256[](1); a[0] = 1 ether;
        vm.prank(client); uint256 id = esc.createEscrow(provider, arbiter, ETH, a, REVIEW, uint64(block.timestamp + 1 days));
        vm.prank(client); esc.fund{value: 1 ether}(id);
        vm.prank(provider); esc.submitMilestone(id, 0);
        vm.warp(block.timestamp + REVIEW);
        vm.prank(provider); esc.claimAfterReview(id, 0);
        assertEq(uint8(_status(id)), uint8(MilestoneEscrow.Status.Completed));
        vm.prank(provider); vm.expectRevert(MilestoneEscrow.InvalidStatus.selector); esc.claimAfterReview(id, 0);
    }

    // ---------------- refunds
    function test_refundExpired() public {
        uint256 id = _funded(ETH);
        vm.prank(provider); esc.submitMilestone(id, 0);
        vm.prank(client); esc.approveMilestone(id, 1);
        vm.prank(client); vm.expectRevert(MilestoneEscrow.DeadlineNotPassed.selector); esc.refundExpired(id);
        vm.warp(block.timestamp + 31 days);
        vm.prank(provider); vm.expectRevert(MilestoneEscrow.Unauthorized.selector); esc.refundExpired(id);
        vm.prank(client); esc.refundExpired(id);
        assertEq(esc.withdrawable(client, ETH), 3 ether);
        assertEq(uint8(_status(id)), uint8(MilestoneEscrow.Status.Funded)); // milestone 0 still submitted
        vm.prank(client); vm.expectRevert(MilestoneEscrow.InvalidMilestoneStatus.selector); esc.refundExpired(id);
        vm.prank(provider); esc.claimAfterReview(id, 0);
        assertEq(uint8(_status(id)), uint8(MilestoneEscrow.Status.Completed));
    }
    function test_refundExpired_full() public {
        uint256 id = _funded(address(tok));
        vm.warp(block.timestamp + 31 days);
        vm.prank(client); esc.refundExpired(id);
        assertEq(uint8(_status(id)), uint8(MilestoneEscrow.Status.Refunded));
        vm.prank(client); vm.expectRevert(MilestoneEscrow.InvalidStatus.selector); esc.refundExpired(id);
        vm.prank(client); esc.withdraw(address(tok));
        assertEq(tok.balanceOf(client), 1000 ether);
    }
    function test_providerRefund() public {
        uint256 id = _funded(ETH);
        vm.prank(provider); esc.submitMilestone(id, 2);
        vm.prank(client); esc.approveMilestone(id, 0);
        vm.prank(client); vm.expectRevert(MilestoneEscrow.Unauthorized.selector); esc.providerRefund(id);
        vm.prank(provider); esc.providerRefund(id);
        assertEq(esc.withdrawable(client, ETH), 5 ether);
        assertEq(uint8(_status(id)), uint8(MilestoneEscrow.Status.Completed));
        vm.prank(provider); vm.expectRevert(MilestoneEscrow.InvalidStatus.selector); esc.providerRefund(id);
    }

    // ---------------- disputes
    function test_dispute_resolve() public {
        uint256 id = _funded(ETH);
        vm.prank(client); esc.approveMilestone(id, 0);
        vm.prank(arbiter); vm.expectRevert(MilestoneEscrow.Unauthorized.selector); esc.raiseDispute(id);
        vm.prank(provider); esc.raiseDispute(id);
        vm.prank(client); vm.expectRevert(MilestoneEscrow.InvalidStatus.selector); esc.raiseDispute(id);
        vm.prank(provider); vm.expectRevert(MilestoneEscrow.InvalidStatus.selector); esc.submitMilestone(id, 1);
        vm.prank(client); vm.expectRevert(MilestoneEscrow.Unauthorized.selector); esc.resolveDispute(id, 5000);
        vm.prank(arbiter); vm.expectRevert(MilestoneEscrow.InvalidShare.selector); esc.resolveDispute(id, 10_001);
        vm.prank(arbiter); esc.resolveDispute(id, 5000);
        assertEq(esc.withdrawable(client, ETH), 2.5 ether);
        assertEq(esc.withdrawable(provider, ETH), 0.99 ether + 2.475 ether);
        assertEq(esc.withdrawable(arbiter, ETH), 0);
        assertEq(uint8(_status(id)), uint8(MilestoneEscrow.Status.Resolved));
        vm.prank(arbiter); vm.expectRevert(MilestoneEscrow.InvalidStatus.selector); esc.resolveDispute(id, 0);
    }
    function test_dispute_resolve_allClient_noFee() public {
        uint256 id = _funded(ETH);
        vm.prank(client); esc.raiseDispute(id);
        vm.prank(arbiter); esc.resolveDispute(id, 0);
        assertEq(esc.withdrawable(client, ETH), 6 ether);
        assertEq(esc.withdrawable(feeTo, ETH), 0);
    }
    function test_arbiterTimeout() public {
        uint256 id = _funded(ETH);
        vm.prank(provider); esc.submitMilestone(id, 1);
        vm.prank(client); esc.approveMilestone(id, 0);
        vm.prank(client); vm.expectRevert(MilestoneEscrow.InvalidStatus.selector); esc.resolveAfterArbiterTimeout(id);
        vm.prank(client); esc.raiseDispute(id);
        vm.prank(client); vm.expectRevert(MilestoneEscrow.ArbiterTimeoutNotReached.selector); esc.resolveAfterArbiterTimeout(id);
        vm.warp(block.timestamp + 30 days);
        vm.prank(arbiter); vm.expectRevert(MilestoneEscrow.Unauthorized.selector); esc.resolveAfterArbiterTimeout(id);
        vm.prank(provider); esc.resolveAfterArbiterTimeout(id);
        assertEq(esc.withdrawable(client, ETH), 3 ether);
        assertEq(esc.withdrawable(provider, ETH), 0.99 ether + 1.98 ether);
        assertEq(uint8(_mstatus(id, 2)), uint8(MilestoneEscrow.MilestoneStatus.Resolved));
    }

    // ---------------- withdraw
    function test_withdraw_nothing() public {
        vm.expectRevert(MilestoneEscrow.NothingToWithdraw.selector); esc.withdraw(ETH);
    }
    function test_withdraw_reentrancyBlocked() public {
        ReentrantReceiver r = new ReentrantReceiver();
        r.setEscrow(address(esc));
        vm.prank(client); uint256 id = esc.createEscrow(address(r), arbiter, ETH, _amts(), REVIEW, uint64(block.timestamp + 1 days));
        vm.prank(client); esc.fund{value: 6 ether}(id);
        vm.prank(client); esc.approveMilestone(id, 0);
        vm.expectRevert(MilestoneEscrow.EthTransferFailed.selector);
        r.doWithdraw();
        assertEq(esc.withdrawable(address(r), ETH), 0.99 ether); // state rolled back, nothing lost
        assertEq(address(esc).balance, 6 ether);
    }

    // ---------------- smart account (ERC-1271 + batching)
    function test_smartAccountClient_1271_and_batch() public {
        uint256 ownerPk = 0xA11CE;
        MockSmartAccount acct = new MockSmartAccount(vm.addr(ownerPk));
        vm.deal(address(acct), 10 ether);
        // batch: create + fund in one account execution
        MockSmartAccount.Call[] memory calls = new MockSmartAccount.Call[](2);
        calls[0] = MockSmartAccount.Call(address(esc), 0, abi.encodeCall(esc.createEscrow, (provider, arbiter, ETH, _amts(), REVIEW, uint64(block.timestamp + 1 days))));
        calls[1] = MockSmartAccount.Call(address(esc), 6 ether, abi.encodeCall(esc.fund, (1)));
        vm.prank(vm.addr(ownerPk)); acct.executeBatch(calls);
        assertEq(esc.getEscrow(1).client, address(acct));
        assertEq(uint8(_status(1)), uint8(MilestoneEscrow.Status.Funded));
        // owner signs EIP-712 approval; account validates via ERC-1271
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, 1, 0, 1 ether, dl);
        esc.approveMilestoneWithSig(1, 0, dl, sig);
        assertEq(uint8(_mstatus(1, 0)), uint8(MilestoneEscrow.MilestoneStatus.Released));
        // wrong owner key rejected by 1271
        bytes memory bad = _sign(clientPk, 1, 1, 2 ether, dl);
        vm.expectRevert(MilestoneEscrow.InvalidSignature.selector); esc.approveMilestoneWithSig(1, 1, dl, bad);
        // smart account refunded & withdraws
        vm.warp(block.timestamp + 2 days);
        calls = new MockSmartAccount.Call[](2);
        calls[0] = MockSmartAccount.Call(address(esc), 0, abi.encodeCall(esc.refundExpired, (1)));
        calls[1] = MockSmartAccount.Call(address(esc), 0, abi.encodeCall(esc.withdraw, (ETH)));
        vm.prank(vm.addr(ownerPk)); acct.executeBatch(calls);
        assertEq(address(acct).balance, 9 ether);
    }

    function test_multicall() public {
        uint256 id = _funded(ETH);
        bytes[] memory d = new bytes[](2);
        d[0] = abi.encodeCall(esc.approveMilestone, (id, 0));
        d[1] = abi.encodeCall(esc.approveMilestone, (id, 1));
        vm.prank(client); esc.multicall(d);
        assertEq(uint8(_mstatus(id, 1)), uint8(MilestoneEscrow.MilestoneStatus.Released));
    }

    // ---------------- fuzz
    function testFuzz_fullFlow(uint96 a0, uint96 a1, uint16 fee, uint16 share) public {
        a0 = uint96(bound(a0, 1, 1e30)); a1 = uint96(bound(a1, 1, 1e30));
        fee = uint16(bound(fee, 0, 500)); share = uint16(bound(share, 0, 10_000));
        vm.prank(owner); esc.setFee(fee, feeTo);
        uint256[] memory a = new uint256[](2); a[0] = a0; a[1] = a1;
        uint256 total = uint256(a0) + a1;
        vm.deal(client, total);
        vm.prank(client); uint256 id = esc.createEscrow(provider, arbiter, ETH, a, REVIEW, uint64(block.timestamp + 1 days));
        vm.prank(client); esc.fund{value: total}(id);
        vm.prank(client); esc.approveMilestone(id, 0);
        vm.prank(provider); esc.raiseDispute(id);
        vm.prank(arbiter); esc.resolveDispute(id, share);
        uint256 sum = esc.withdrawable(client, ETH) + esc.withdrawable(provider, ETH) + esc.withdrawable(feeTo, ETH);
        assertEq(sum, total);
        assertEq(esc.liabilities(ETH), total);
        assertLe(esc.withdrawable(feeTo, ETH), total * 500 / 10_000);
    }

    function testFuzz_cannotApproveWithForeignSig(uint256 pk) public {
        pk = bound(pk, 1, 0xffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140);
        vm.assume(pk != clientPk);
        uint256 id = _funded(ETH);
        uint256 dl = block.timestamp + 1;
        bytes memory sig = _sign(pk, id, 0, 1 ether, dl);
        vm.expectRevert(MilestoneEscrow.InvalidSignature.selector);
        esc.approveMilestoneWithSig(id, 0, dl, sig);
    }

    function testFuzz_reviewTimeout(uint64 review, uint64 wait) public {
        review = uint64(bound(review, 1 hours, 30 days));
        wait = uint64(bound(wait, 0, 60 days));
        vm.prank(client); uint256 id = esc.createEscrow(provider, arbiter, ETH, _amts(), review, uint64(block.timestamp + 90 days));
        vm.prank(client); esc.fund{value: 6 ether}(id);
        vm.prank(provider); esc.submitMilestone(id, 0);
        vm.warp(block.timestamp + wait);
        vm.prank(provider);
        if (wait < review) vm.expectRevert(MilestoneEscrow.ReviewPeriodActive.selector);
        esc.claimAfterReview(id, 0);
    }
}
