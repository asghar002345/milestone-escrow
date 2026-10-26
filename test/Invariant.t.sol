// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";
import {MockERC20} from "./mocks/Mocks.sol";

contract Handler is Test {
    MilestoneEscrow public esc;
    MockERC20 public tok;
    address[3] public clients = [address(0x1001), address(0x1002), address(0x1003)];
    address public provider = address(0x2001);
    address public arbiter = address(0x3001);
    uint256[] public ids;
    mapping(uint256 => mapping(uint256 => uint256)) public releaseCount;
    uint256 public doubleReleases;
    address[] public actors;

    constructor(MilestoneEscrow e, MockERC20 t) {
        esc = e; tok = t;
        actors.push(provider); actors.push(e.feeRecipient());
        for (uint256 i; i < 3; ++i) {
            actors.push(clients[i]);
            vm.deal(clients[i], 1e40); t.mint(clients[i], 1e40);
            vm.prank(clients[i]); t.approve(address(e), type(uint256).max);
        }
    }

    function _token(uint256 s) internal view returns (address) { return s % 2 == 0 ? address(0) : address(tok); }
    function _id(uint256 s) internal view returns (uint256) { return ids.length == 0 ? 0 : ids[s % ids.length]; }

    function create(uint256 cs, uint256 ts, uint256 a0, uint256 a1) external {
        uint256[] memory a = new uint256[](2);
        a[0] = bound(a0, 1, 1e24); a[1] = bound(a1, 1, 1e24);
        vm.prank(clients[cs % 3]);
        ids.push(esc.createEscrow(provider, arbiter, _token(ts), a, 1 hours, uint64(block.timestamp + 10 days)));
    }
    function fund(uint256 s) external {
        uint256 id = _id(s); if (id == 0) return;
        MilestoneEscrow.Escrow memory e = esc.getEscrow(id);
        if (e.status != MilestoneEscrow.Status.Created) return;
        vm.prank(e.client);
        if (e.token == address(0)) esc.fund{value: e.total}(id); else esc.fund(id);
    }
    function submit(uint256 s, uint256 i) external {
        uint256 id = _id(s); if (id == 0) return;
        vm.prank(provider); try esc.submitMilestone(id, i % 2) {} catch {}
    }
    function _track(uint256 id, uint256 i, MilestoneEscrow.MilestoneStatus before) internal {
        if (before != MilestoneEscrow.MilestoneStatus.Released && esc.getMilestones(id)[i].status == MilestoneEscrow.MilestoneStatus.Released) {
            if (++releaseCount[id][i] > 1) doubleReleases++;
        }
    }
    function approve(uint256 s, uint256 i) external {
        uint256 id = _id(s); if (id == 0) return; i %= 2;
        MilestoneEscrow.MilestoneStatus b = esc.getMilestones(id)[i].status;
        vm.prank(esc.getEscrow(id).client); try esc.approveMilestone(id, i) {} catch {}
        _track(id, i, b);
    }
    function claim(uint256 s, uint256 i, uint256 w) external {
        uint256 id = _id(s); if (id == 0) return; i %= 2;
        vm.warp(block.timestamp + bound(w, 0, 2 hours));
        MilestoneEscrow.MilestoneStatus b = esc.getMilestones(id)[i].status;
        vm.prank(provider); try esc.claimAfterReview(id, i) {} catch {}
        _track(id, i, b);
    }
    function dispute(uint256 s) external {
        uint256 id = _id(s); if (id == 0) return;
        vm.prank(provider); try esc.raiseDispute(id) {} catch {}
    }
    function resolve(uint256 s, uint16 share) external {
        uint256 id = _id(s); if (id == 0) return;
        vm.prank(arbiter); try esc.resolveDispute(id, uint16(bound(share, 0, 10_000))) {} catch {}
    }
    function timeoutResolve(uint256 s) external {
        uint256 id = _id(s); if (id == 0) return;
        vm.warp(block.timestamp + 31 days);
        vm.prank(provider); try esc.resolveAfterArbiterTimeout(id) {} catch {}
    }
    function refund(uint256 s) external {
        uint256 id = _id(s); if (id == 0) return;
        vm.warp(block.timestamp + 11 days);
        vm.prank(esc.getEscrow(id).client); try esc.refundExpired(id) {} catch {}
    }
    function providerRefund(uint256 s) external {
        uint256 id = _id(s); if (id == 0) return;
        vm.prank(provider); try esc.providerRefund(id) {} catch {}
    }
    function withdraw(uint256 a, uint256 ts) external {
        vm.prank(actors[a % actors.length]); try esc.withdraw(_token(ts)) {} catch {}
    }
    function idsLength() external view returns (uint256) { return ids.length; }
}

contract InvariantTest is Test {
    MilestoneEscrow esc;
    MockERC20 tok;
    Handler h;

    function setUp() public {
        esc = new MilestoneEscrow(address(this), address(0xFEE), 250);
        tok = new MockERC20();
        h = new Handler(esc, tok);
        targetContract(address(h));
    }

    /// escrow balance always covers everything it owes (locked + credited)
    function invariant_solvent() public view {
        assertGe(address(esc).balance, esc.liabilities(address(0)));
        assertGe(tok.balanceOf(address(esc)), esc.liabilities(address(tok)));
    }

    /// no milestone is ever released twice
    function invariant_noDoubleRelease() public view {
        assertEq(h.doubleReleases(), 0);
    }

    /// per escrow: settled never exceeds total; liabilities equal locked + credits
    function invariant_accounting() public view {
        uint256 lockedEth; uint256 lockedTok;
        for (uint256 k; k < h.idsLength(); ++k) {
            MilestoneEscrow.Escrow memory e = esc.getEscrow(h.ids(k));
            assertLe(e.settled, e.total);
            if (e.status == MilestoneEscrow.Status.Funded || e.status == MilestoneEscrow.Status.Disputed) {
                if (e.token == address(0)) lockedEth += e.total - e.settled; else lockedTok += e.total - e.settled;
            }
        }
        uint256 credEth; uint256 credTok;
        for (uint256 a; a < 5; ++a) {
            credEth += esc.withdrawable(h.actors(a), address(0));
            credTok += esc.withdrawable(h.actors(a), address(tok));
        }
        assertEq(esc.liabilities(address(0)), lockedEth + credEth);
        assertEq(esc.liabilities(address(tok)), lockedTok + credTok);
    }
}
