// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @dev Burns 1% on every transfer.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("FoT", "FOT") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @dev Minimal ERC-1271 smart account: one EOA owner, batched execution (ERC-4337/7579 stand-in).
contract MockSmartAccount is IERC1271 {
    address public owner;
    struct Call { address target; uint256 value; bytes data; }
    constructor(address o) { owner = o; }
    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
        return (err == ECDSA.RecoverError.NoError && rec == owner) ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
    function executeBatch(Call[] calldata calls) external payable {
        require(msg.sender == owner, "not owner");
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory r) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!ok) assembly { revert(add(r, 32), mload(r)) }
        }
    }
    receive() external payable {}
}

interface IWithdraw { function withdraw(address) external returns (uint256); }

/// @dev Provider that tries to reenter withdraw on ETH receipt.
contract ReentrantReceiver {
    IWithdraw public escrow;
    bool public attack = true;
    function setEscrow(address e) external { escrow = IWithdraw(e); }
    function doWithdraw() external { escrow.withdraw(address(0)); }
    receive() external payable { if (attack) { attack = false; escrow.withdraw(address(0)); } }
}
